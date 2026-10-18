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
  const pools = new Map();
  let downloadURL = null;
  let groupRows = [];
  let rows = [];
  let chartWidth = 0;
  let current = null;
  let documentData = null;
  let request = 0;
  const statuses = ["missing", "near", "matched", "extra"];
  const statusLabels = {missing: "Missing", near: "Near misses", matched: "Matched", extra: "Extra"};
  const nameKey = entry => `${entry.kind}|${entry.owner}|${entry.name}`;

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
    groupRows = filtered;
    rows = filtered.filter(row => !state.baseline || row.baseline === state.baseline);
  }

  function versionOrder(versions) {
    const parsed = versions.map(version => ({version, parts: /^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([\da-z-]+(?:\.[\da-z-]+)*))?(?:\+[\da-z-]+(?:\.[\da-z-]+)*)?$/i.exec(version)}));
    // Custom labels have no implied chronology. Keep their manifest order.
    if (parsed.some(item => !item.parts)) return versions;
    return parsed.sort((a, b) => {
      for (let index = 1; index <= 3; index++) {
        const difference = Number(a.parts[index] || 0) - Number(b.parts[index] || 0);
        if (difference) return difference;
      }
      const left = a.parts[4]?.split(".") || [];
      const right = b.parts[4]?.split(".") || [];
      if (!left.length || !right.length) return right.length ? 1 : left.length ? -1 : 0;
      for (let index = 0; index < Math.max(left.length, right.length); index++) {
        if (left[index] === undefined) return -1;
        if (right[index] === undefined) return 1;
        if (left[index] === right[index]) continue;
        const leftNumber = /^\d+$/.test(left[index]);
        const rightNumber = /^\d+$/.test(right[index]);
        if (leftNumber && rightNumber) return Number(left[index]) - Number(right[index]);
        if (leftNumber !== rightNumber) return leftNumber ? -1 : 1;
        return left[index] < right[index] ? -1 : 1;
      }
      return 0;
    }).map(item => item.version);
  }

  function svgElement(tag, attributes = {}, text) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function chartReadout(record) {
    if (!record || !$("chart-readout")) return;
    $("chart-readout").replaceChildren(
      element("strong", `${record.version} · ${record.baseline}`),
      element("span", `${percent(record.summary)} · ${number(record.summary.matched)} / ${number(record.summary.reference)} declarations`)
    );
  }

  function updateChartSelection() {
    $("chart").querySelectorAll("[data-report]").forEach(point => {
      point.setAttribute("aria-pressed", String(point.dataset.report === state.report));
    });
    chartReadout(rows.find(row => row.id === state.report));
  }

  function renderChart() {
    const focused = document.activeElement?.closest("[data-report]")?.dataset.report;
    const scrollLeft = $("chart-scroll")?.scrollLeft || 0;
    const baselines = unique(groupRows.map(row => row.baseline));
    const versions = versionOrder(unique(groupRows.map(row => row.version)));
    const header = element("div", undefined, "chart-header");
    const legend = element("div", undefined, "chart-legend");
    legend.setAttribute("aria-label", "Chart baselines");
    const readout = element("p", undefined, "chart-readout");
    readout.id = "chart-readout";
    readout.setAttribute("aria-live", "polite");
    for (const [index, baseline] of baselines.entries()) {
      const item = button(undefined, !state.baseline || state.baseline === baseline, () => {
        state.baseline = state.baseline === baseline ? "" : baseline;
        state.report = null;
        state.kind = "";
        render();
        $("chart").querySelectorAll(".chart-legend button")[index].focus({preventScroll: true});
      }, "chart-legend-item");
      item.setAttribute("aria-label", `Show ${baseline}`);
      item.style.setProperty("--series-color", `var(--series-${index % 6})`);
      const swatch = svgElement("svg", {viewBox: "0 0 12 12", width: 12, height: 12, "aria-hidden": "true"});
      swatch.append(svgElement("rect", {width: 12, height: 12, rx: 2}));
      item.append(swatch, element("span", baseline));
      legend.append(item);
    }
    header.append(legend, readout);
    const scroll = element("div", undefined, "chart-scroll");
    scroll.id = "chart-scroll";
    const stage = element("div", undefined, "chart-stage");
    stage.setAttribute("role", "group");
    stage.setAttribute("aria-label", `${state.project} coverage by version`);
    scroll.append(stage);
    $("chart").replaceChildren(header, scroll);
    chartWidth = $("chart").clientWidth;
    // Group bars by version. Each bar in a group is one visible SDK baseline.
    const visible = baselines.filter(baseline => !state.baseline || baseline === state.baseline);
    const gap = 4, left = 56, right = 16, height = 292, top = 28, bottom = 238;
    const minimumBand = Math.max(visible.length * 14 + (visible.length - 1) * gap + 24, ...versions.map(version => version.length * 7 + 20));
    const band = Math.max(minimumBand, (scroll.clientWidth - left - right) / Math.max(versions.length, 1));
    const width = left + right + band * versions.length;
    const barWidth = Math.min(visible.length === 1 ? 48 : 32, (band - 24 - (visible.length - 1) * gap) / Math.max(visible.length, 1));
    const groupWidth = visible.length * barWidth + (visible.length - 1) * gap;
    const center = index => left + band * (index + 0.5);
    const y = value => bottom - value / 100 * (bottom - top);
    stage.style.width = `${width}px`;
    stage.style.height = `${height}px`;
    const svg = svgElement("svg", {viewBox: `0 0 ${width} ${height}`, width, height, role: "img", "aria-labelledby": "chart-svg-title chart-svg-description"});
    svg.append(svgElement("title", {id: "chart-svg-title"}, `${state.project} interface coverage`),
      svgElement("desc", {id: "chart-svg-description"}, "Coverage from 0 to 100 percent for each candidate version. Each bar in a group is an SDK baseline. Missing reports and empty references have no bar. Use the bar buttons to open a report."));
    for (let value = 0; value <= 100; value += 25) {
      svg.append(svgElement("line", {x1: left, x2: width - right, y1: y(value), y2: y(value), class: "chart-grid"}),
        svgElement("text", {x: left - 12, y: y(value) + 4, "text-anchor": "end", class: "chart-axis"}, `${value}%`));
    }
    versions.forEach((version, index) => {
      svg.append(svgElement("text", {x: center(index), y: bottom + 28, "text-anchor": "middle", class: "chart-axis chart-version"}, version));
    });
    stage.append(svg);
    const unavailable = element("div", undefined, "chart-unavailable");
    for (const [index, baseline] of baselines.entries()) {
      const slot = visible.indexOf(baseline);
      if (slot < 0) continue;
      const series = new Map(rows.filter(row => row.baseline === baseline).map(row => [row.version, row]));
      versions.forEach((version, versionIndex) => {
        const record = series.get(version);
        if (!record) return;
        const plottable = record.summary.reference > 0;
        const label = `${version}, ${baseline}: ${percent(record.summary)}, ${record.summary.matched} of ${record.summary.reference}`;
        const bar = button(undefined, record.id === state.report, () => selectReport(record), plottable ? "chart-bar" : "chart-unavailable-point");
        bar.dataset.report = record.id;
        bar.setAttribute("aria-label", label);
        bar.title = label;
        bar.style.setProperty("--series-color", `var(--series-${index % 6})`);
        bar.addEventListener("pointerenter", () => chartReadout(record));
        bar.addEventListener("focus", () => chartReadout(record));
        bar.addEventListener("pointerleave", () => {
          if (document.activeElement !== bar) chartReadout(rows.find(row => row.id === state.report));
        });
        bar.addEventListener("blur", () => chartReadout(rows.find(row => row.id === state.report)));
        if (!plottable) {
          bar.textContent = `${version} / ${baseline}: n/a`;
          unavailable.append(bar);
          return;
        }
        const value = 100 * record.summary.matched / record.summary.reference;
        const x = center(versionIndex) - groupWidth / 2 + slot * (barWidth + gap);
        // The button covers the whole column, so a short bar is still easy to select.
        bar.style.left = `${x}px`;
        bar.style.top = `${top}px`;
        bar.style.width = `${barWidth}px`;
        bar.style.height = `${bottom - top}px`;
        const fill = element("span");
        fill.style.height = `${Math.max(2, bottom - y(value))}px`;
        bar.append(fill);
        stage.append(bar);
        // Values fit above the bars when one baseline is shown.
        if (visible.length === 1) {
          svg.append(svgElement("text", {x: x + barWidth / 2, y: y(value) - 6, "text-anchor": "middle", class: "chart-value"}, percent(record.summary)));
        }
      });
    }
    if (unavailable.childElementCount) {
      unavailable.prepend(element("p", "Not plotted: these references contain no declarations.", "caption"));
      $("chart").append(unavailable);
    }
    scroll.scrollLeft = scrollLeft;
    updateChartSelection();
    if (focused) Array.from(stage.querySelectorAll("[data-report]")).find(point => point.dataset.report === focused)?.focus({preventScroll: true});
  }

  function renderOverview() {
    $("matrix").hidden = !embedded;
    $("chart").hidden = embedded;
    if (embedded) renderMatrix();
    else renderChart();
    $("matrix-notes").textContent = unique(rows.flatMap(row => [...row.notes, ...row.warnings])).join(" ");
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
    renderOverview();
    if (!embedded) selectReport(selected, true);
    saveURL();
  }

  function renderSummary(record) {
    $("result-title").textContent = `${record.version} / ${record.baseline} · ${record.scope}`;
    $("download").removeAttribute("href");
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
    $("statuses").replaceChildren(...statuses.map(status => button(
      `${statusLabels[status]} ${number(status === "near" ? record.nearMisses ?? 0 : record.summary[status])}`,
      status === state.status, () => {
        state.status = status;
        state.page = 0;
        renderSummary(record);
        renderEntries();
        saveURL();
      }
    )));
  }

  async function fetchJSON(path) {
    const response = await fetch(path);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  }

  // Reports with the same reference share a pool of reference declarations.
  // Matched and missing declarations are indices into that pool.
  async function loadReport(path) {
    const data = await fetchJSON(path);
    const coverage = data.coverage;
    if (coverage.pool) {
      if (!pools.has(coverage.pool)) {
        const pending = fetchJSON(coverage.pool).then(pool => pool.entries);
        pending.catch(() => pools.delete(coverage.pool));
        pools.set(coverage.pool, pending);
      }
      const entries = await pools.get(coverage.pool);
      coverage.matched = coverage.matched.map(index => entries[index]);
      coverage.missing = coverage.missing.map(index => entries[index]);
      delete coverage.pool;
    }
    return data;
  }

  async function selectReport(record, preserveFilters = false) {
    const ticket = ++request;
    const changed = state.report !== record.id;
    state.report = record.id;
    current = record;
    documentData = null;
    state.page = 0;
    if (!preserveFilters && changed) state.kind = "";
    updateChartSelection();
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
        data = await loadReport(record.report);
        cache.set(record.id, data);
      }
      if (ticket !== request) return;
      documentData = data;
      // Offer the complete report, with pool indices resolved to declarations.
      if (downloadURL) URL.revokeObjectURL(downloadURL);
      downloadURL = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], {type: "application/json"}));
      $("download").href = downloadURL;
      $("download").download = `${record.id}.json`;
      choices("kind", data.coverage.byKind.map(row => row.kind), "All kinds");
      $("load-state").textContent = "";
      renderEntries();
      renderMetadata();
    } catch (error) {
      if (ticket !== request) return;
      $("load-state").textContent = location.protocol === "file:"
        ? "Serve this directory with a local HTTP server to load declaration details. The coverage chart is available offline."
        : `Could not load declarations: ${error.message}. Select the result again to retry.`;
      $("load-state").classList.add("error");
    } finally {
      if (ticket === request) $("detail").setAttribute("aria-busy", "false");
    }
  }

  function renderEntries() {
    if (!documentData) return;
    const text = state.search.toLowerCase().trim();
    const entries = statusEntries().filter(entry =>
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
      for (const candidate of entry.candidates || []) declaration.append(element("code", candidate.signature, "candidate"));
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

  // A near miss is a missing declaration with an extra declaration of the same
  // kind, owner, and name. It usually shows a signature difference.
  function statusEntries() {
    const coverage = documentData.coverage;
    if (state.status !== "near") return coverage[state.status];
    const extras = new Map();
    for (const entry of coverage.extra) extras.set(nameKey(entry), [...(extras.get(nameKey(entry)) || []), entry]);
    return coverage.missing.filter(entry => extras.has(nameKey(entry)))
      .map(entry => ({...entry, candidates: extras.get(nameKey(entry))}));
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
  if (!statuses.includes(state.status)) state.status = "missing";
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
  if (!embedded) {
    new ResizeObserver(() => {
      if ($("chart").clientWidth !== chartWidth) renderChart();
    }).observe($("chart"));
  }
})();
