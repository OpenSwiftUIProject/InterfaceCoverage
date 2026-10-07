"use strict";

(() => {
  const catalog = JSON.parse(document.getElementById("catalog").textContent);
  const reports = catalog.reports;
  const embedded = document.body.dataset.embed === "true";
  const query = new URLSearchParams(location.search);
  const state = {
    project: query.get("project"), target: query.get("target"), scope: query.get("scope"),
    profile: query.get("profile"), baseline: query.get("baseline") || "",
    report: query.get("report"), status: query.get("status") || "missing",
    search: query.get("q") || "", kind: query.get("kind") || "", page: 0,
  };
  const $ = id => document.getElementById(id);
  const unique = values => [...new Set(values)];
  const number = value => value.toLocaleString("en-US");
  const percent = count => count.reference ? `${(100 * count.matched / count.reference).toFixed(2)}%` : "n/a";
  const cache = new Map();
  let rows = [];
  let current = null;
  let documentData = null;
  let request = 0;

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  function button(text, selected, action, className) {
    const node = element("button", text, className);
    node.type = "button";
    node.setAttribute("aria-pressed", String(selected));
    node.addEventListener("click", action);
    return node;
  }

  function parameters(includeDetail = true) {
    const params = new URLSearchParams();
    for (const key of ["project", "target", "scope", "profile", "baseline"]) {
      if (state[key]) params.set(key, state[key]);
    }
    if (includeDetail) {
      if (state.report) params.set("report", state.report);
      if (state.status !== "missing") params.set("status", state.status);
      if (state.search) params.set("q", state.search);
      if (state.kind) params.set("kind", state.kind);
    }
    return params;
  }

  function saveURL() {
    // A local HTTP server and GitHub Pages both support shareable filter URLs.
    if (location.protocol !== "file:") history.replaceState(null, "", `?${parameters(!embedded)}`);
  }

  function choices(key, values, allLabel) {
    if (allLabel) values = ["", ...values];
    if (!values.includes(state[key])) state[key] = values[0];
    $(key).replaceChildren(...values.map(value => {
      const option = element("option", value || allLabel);
      option.value = value;
      return option;
    }));
    $(key).value = state[key];
  }

  function renderFilters() {
    const projects = unique(reports.map(row => row.project));
    if (!projects.includes(state.project)) state.project = projects[0];
    $("projects").replaceChildren(...projects.map(project => button(project, state.project === project, () => {
      state.project = project;
      state.report = null;
      render();
    })));
    let filtered = reports.filter(row => row.project === state.project);
    for (const key of ["target", "scope", "profile"]) {
      choices(key, unique(filtered.map(row => row[key])));
      filtered = filtered.filter(row => row[key] === state[key]);
    }
    choices("baseline", unique(filtered.map(row => row.baseline)), "All baselines");
    rows = filtered.filter(row => !state.baseline || row.baseline === state.baseline);
  }

  function renderMatrix() {
    const baselines = unique(rows.map(row => row.baseline));
    const table = element("table", undefined, "matrix");
    table.setAttribute("aria-label", `${state.project} coverage version matrix`);
    const head = table.createTHead().insertRow();
    for (const label of ["Candidate", ...baselines]) {
      const th = element("th", label);
      th.scope = "col";
      head.append(th);
    }
    const body = table.createTBody();
    for (const version of unique(rows.map(row => row.version))) {
      const tr = body.insertRow();
      const th = element("th", version);
      th.scope = "row";
      const record = rows.find(row => row.version === version);
      if (/^[a-f0-9]{7,64}$/i.test(record.metadata.candidateCommit || "")) {
        th.append(element("span", record.metadata.candidateCommit.slice(0, 12), "candidate-note"));
      }
      tr.append(th);
      for (const baseline of baselines) {
        const td = tr.insertCell();
        const record = rows.find(row => row.version === version && row.baseline === baseline);
        if (!record) {
          const empty = element("span", "—", "matrix-empty");
          empty.title = "No report for this combination.";
          td.append(empty);
          continue;
        }
        const cell = button(undefined, record.id === state.report, () => {
          if (embedded) {
            const params = parameters(false);
            params.set("report", record.id);
            window.open(`index.html?${params}`, "_blank", "noopener");
          } else selectReport(record);
        }, "matrix-cell");
        cell.setAttribute("aria-label", `${version}, ${baseline}: ${percent(record.summary)}, ${record.summary.matched} of ${record.summary.reference}`);
        cell.append(element("strong", percent(record.summary)), element("span", `${number(record.summary.matched)} / ${number(record.summary.reference)}`));
        td.append(cell);
      }
    }
    $("matrix").replaceChildren(table);
    $("matrix-notes").textContent = unique(rows.flatMap(row => [...row.notes, ...row.warnings])).join(" ");
    if (embedded) {
      $("matrix-title").textContent = `${state.project} interface coverage`;
      $("matrix-description").textContent = `${state.target} · ${state.scope} · ${state.profile}`;
      $("full-report").href = `index.html?${parameters(false)}`;
    }
  }

  function render() {
    renderFilters();
    const selected = rows.find(row => row.id === state.report) || rows[0];
    state.report = selected.id;
    renderMatrix();
    if (!embedded) selectReport(selected, true);
    saveURL();
  }

  function renderSummary(record) {
    $("result-title").textContent = `${record.version} / ${record.baseline} · ${record.scope}`;
    $("download").href = record.report;
    $("metrics").replaceChildren(...[
      ["coverage", percent(record.summary)], ["matched", number(record.summary.matched)],
      ["missing", number(record.summary.missing)], ["extra", number(record.summary.extra)],
    ].map(([label, value]) => {
      const item = element("div");
      item.append(element("dt", label), element("dd", value));
      return item;
    }));
    $("notices").replaceChildren(...record.notes.map(note => element("p", note, "notice")),
      ...record.warnings.map(note => element("p", note, "notice warning")));
    $("statuses").replaceChildren(...["missing", "matched", "extra"].map(status => button(
      `${status[0].toUpperCase()}${status.slice(1)} ${number(record.summary[status])}`,
      status === state.status, () => {
        state.status = status;
        state.page = 0;
        renderSummary(record);
        renderEntries();
        saveURL();
      }
    )));
  }

  async function selectReport(record, preserveFilters = false) {
    const ticket = ++request;
    const changed = state.report !== record.id;
    state.report = record.id;
    current = record;
    documentData = null;
    state.page = 0;
    if (!preserveFilters && changed) state.kind = "";
    renderMatrix();
    renderSummary(record);
    $("entries").replaceChildren();
    $("metadata").replaceChildren();
    $("kind-breakdown").replaceChildren();
    $("result-count").textContent = "";
    $("previous").disabled = true;
    $("next").disabled = true;
    $("detail").setAttribute("aria-busy", "true");
    $("load-state").classList.remove("error");
    $("load-state").textContent = "Loading declarations…";
    saveURL();
    try {
      let data = cache.get(record.id);
      if (!data) {
        const response = await fetch(record.report);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        data = await response.json();
        cache.set(record.id, data);
      }
      if (ticket !== request) return;
      documentData = data;
      choices("kind", data.coverage.byKind.map(row => row.kind), "All kinds");
      $("load-state").textContent = "";
      renderEntries();
      renderMetadata();
    } catch (error) {
      if (ticket !== request) return;
      $("load-state").textContent = location.protocol === "file:"
        ? "Serve this directory with a local HTTP server to load declaration details. The version table is available offline."
        : `Could not load declarations: ${error.message}. Select the result again to retry.`;
      $("load-state").classList.add("error");
    } finally {
      if (ticket === request) $("detail").setAttribute("aria-busy", "false");
    }
  }

  function renderEntries() {
    if (!documentData) return;
    const text = state.search.toLowerCase().trim();
    const entries = documentData.coverage[state.status].filter(entry =>
      (!state.kind || entry.kind === state.kind) &&
      (!text || `${entry.owner} ${entry.name} ${entry.signature}`.toLowerCase().includes(text))
    );
    const pageSize = 50;
    const start = state.page * pageSize;
    const visible = entries.slice(start, start + pageSize);
    $("entries").replaceChildren(...visible.map(entry => {
      const row = element("tr");
      const kind = element("td");
      kind.append(element("code", entry.kind));
      const declaration = element("td");
      declaration.append(element("code", entry.owner, "owner"), element("code", entry.signature));
      declaration.append(element("span", entry.locations.map(item => `${item.path}:${item.line}`).join(" · "), "locations"));
      row.append(kind, declaration);
      return row;
    }));
    if (!entries.length) {
      const row = element("tr");
      const cell = element("td", "No declarations match these filters.", "caption");
      cell.colSpan = 2;
      row.append(cell);
      $("entries").append(row);
    }
    $("result-count").textContent = entries.length
      ? `${number(start + 1)}–${number(Math.min(start + pageSize, entries.length))} of ${number(entries.length)} declarations`
      : "0 declarations";
    $("previous").disabled = state.page === 0;
    $("next").disabled = start + pageSize >= entries.length;
  }

  function renderMetadata() {
    $("metadata").replaceChildren(...[
      ["Provenance", current.metadata], ["Matching rules", documentData.options],
      ["Reference interfaces", documentData.reference], ["Candidate interfaces", documentData.candidate],
    ].flatMap(([label, value]) => [element("h3", label), element("pre", JSON.stringify(value, null, 2))]));
    const table = element("table");
    const head = table.createTHead().insertRow();
    for (const label of ["Kind", "Reference", "Matched", "Missing", "Extra", "Coverage"]) {
      const th = element("th", label);
      th.scope = "col";
      head.append(th);
    }
    const body = table.createTBody();
    for (const {kind, count} of documentData.coverage.byKind) {
      const row = body.insertRow();
      for (const value of [kind, number(count.reference), number(count.matched), number(count.missing), number(count.extra), percent(count)]) {
        row.append(element("td", value));
      }
    }
    $("kind-breakdown").replaceChildren(table);
  }

  for (const key of ["target", "scope", "profile", "baseline"]) {
    $(key).addEventListener("change", () => {
      state[key] = $(key).value;
      state.report = null;
      state.kind = "";
      render();
    });
  }
  if (!["missing", "matched", "extra"].includes(state.status)) state.status = "missing";
  $("search").value = state.search;
  $("search").addEventListener("input", () => {
    state.search = $("search").value;
    state.page = 0;
    renderEntries();
    saveURL();
  });
  $("kind").addEventListener("change", () => {
    state.kind = $("kind").value;
    state.page = 0;
    renderEntries();
    saveURL();
  });
  $("previous").addEventListener("click", () => { state.page--; renderEntries(); });
  $("next").addEventListener("click", () => { state.page++; renderEntries(); });
  $("embed-button").addEventListener("click", () => {
    const url = new URL("embed.html", location.href);
    url.search = parameters(false).toString();
    $("embed-code").value = `<iframe src="${url.href.replaceAll("&", "&amp;").replaceAll('"', "&quot;")}" title="Interface coverage" width="100%" height="360" style="border:0" loading="lazy"></iframe>`;
    $("embed-preview").href = url.href;
    $("markdown-download").href = `tables/${current.group}.md`;
    $("svg-download").href = `tables/${current.group}.svg`;
    $("copy-state").textContent = "";
    $("embed-dialog").showModal();
  });
  $("copy-embed").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText($("embed-code").value);
      $("copy-state").textContent = "Copied.";
    } catch {
      $("embed-code").select();
      $("copy-state").textContent = "Select and copy the HTML above.";
    }
  });
  render();
})();
