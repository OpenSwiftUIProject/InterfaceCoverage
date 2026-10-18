# InterfaceCoverage

Compare API declarations in Swift `.swiftinterface` files. The tool reports
matched, missing, and extra signatures, with counts by declaration kind. It uses
SwiftSyntax to parse interfaces without loading or building their modules.

Coverage is `matched reference declarations / reference declarations`. A match
means that a declaration has the same normalized signature. It does not establish
that its implementation is complete or that its behavior is compatible. Stubs
with matching declarations count as covered.

## Build and test

Use Swift 6.3 or later. Run these commands from the Mono repository root:

```sh
swift build --package-path Tools/InterfaceCoverage -c release
swift test --package-path Tools/InterfaceCoverage
```

The executable is `Tools/InterfaceCoverage/.build/release/interface-coverage`.
The package builds only this tool and its dependencies.

## Compare one module

Supply an existing candidate interface for the same platform and target
environment as the SDK interface. Input files must contain the compiler-generated
`swift-module-flags` header with `-module-name`.

```sh
swift run --package-path Tools/InterfaceCoverage -c release interface-coverage \
  --reference Versions/6.0.70/SDK/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64-apple-ios-simulator.swiftinterface \
  --candidate path/to/OpenSwiftUI.swiftinterface
```

SwiftUI and SwiftUICore remain separate namespaces. Compare SwiftUICore with
OpenSwiftUICore in a separate invocation when separate coverage figures are
needed. A SwiftUI interface before v6 can be compared on its own.

For Combine:

```sh
interface-coverage \
  --reference path/to/Combine.swiftinterface \
  --candidate path/to/OpenCombine.swiftinterface
```

Replace `interface-coverage` with the built executable path if it is not on
`PATH`. The tool does not fetch repositories, build OpenSwiftUI or OpenCombine,
or regenerate input interfaces. Use fresh build artifacts when measuring current
source coverage.

## Optional interface merging

Repeat an input option to combine declaration inventories on that side of the
comparison. Identical signatures are counted once. Each namespace stays intact,
and declarations in extensions are matched against members of the same type.

```sh
interface-coverage \
  --reference path/to/SwiftUI.swiftinterface \
  --reference path/to/SwiftUICore.swiftinterface \
  --candidate path/to/OpenSwiftUI.swiftinterface \
  --candidate path/to/OpenSwiftUICore.swiftinterface
```

This merges inventories for a report. It does not emit a new compiler-loadable
`.swiftinterface` file. Re-exported imports are not followed automatically.
OpenCombineFoundation and OpenCombineDispatch can also be supplied as additional
candidate inputs when their APIs are part of the comparison.

To compare the single-module layout before SwiftUI v6 with the later split layout,
explicitly merge the namespaces:

```sh
interface-coverage \
  --reference path/to/SwiftUI-v5.swiftinterface \
  --candidate path/to/OpenSwiftUI.swiftinterface \
  --candidate path/to/OpenSwiftUICore.swiftinterface \
  --module-alias SwiftUICore=SwiftUI
```

The built-in `OpenSwiftUICore=SwiftUICore` mapping then resolves to `SwiftUI`.
Do not combine different platform variants as though they were one target.

## Optional namespace normalization

Use `--ignore-namespace NAME` when one implementation adds a namespace container
that should not affect the comparison. The rule is off by default, applies to
both sides, and can be repeated. It accepts any single namespace identifier.

For example, OpenCombine uses `OCombine` containers to avoid conflicts with
Apple's APIs. Enable this rule explicitly when comparing that layout:

```sh
interface-coverage \
  --reference path/to/Combine.swiftinterface \
  --candidate path/to/OpenCombine.swiftinterface \
  --ignore-namespace OCombine
```

With this option, `Swift.Optional<T>.OCombine.Publisher` and
`Swift.Optional<T>.Publisher` use the same type path. The tool omits the
`OCombine` container declaration and lifts its members and inheritance
relationships to the parent scope. It keeps each declaration's access and generic
constraints. Identical normalized declarations are counted once, with all source
locations retained.

Rules match complete path components, not substrings. Module names, method names,
and parameter labels stay intact. Generic argument lists are preserved, and their
qualified type paths use the same rule. A selected component with its own type
arguments, such as `Wrapper<T>` in `Module.Wrapper<T>.Value`, is kept. If a supplied
interface declares a selected namespace with its own generic parameters, the scan
fails. These rules do not expand type aliases or prove semantic equivalence.

Only select names that act as namespace containers in the supplied interfaces.
The same rule applies wherever that component occurs, so distinct paths can
become one. Text reports list the applied names, and JSON records them in
`options.ignoredNamespaces`. The implementation has no OpenCombine-specific
namespace rule.

## Reports and options

Text output includes totals and a table by declaration kind. Add `--show-missing`
to list missing signatures and their source locations. Add `--show-near-misses`
to list missing declarations next to extra declarations with the same kind,
owner, and name. A near miss usually shows a signature difference, such as a
different type spelling or a missing default argument, not an absent API. Use
it to find normalization gaps and real API differences. JSON includes all
matched, missing, and extra declarations with file paths and line numbers, and
a `nearMisses` list:

```sh
interface-coverage \
  --reference path/to/SwiftUI.swiftinterface \
  --candidate path/to/OpenSwiftUI.swiftinterface \
  --format json --output coverage.json
```

JSON includes the input module names and targets, scan options, warnings, and a
versioned `coverage` object. `options.rulesVersion` identifies the built-in
matching rules. It increases when a tool change can produce different signatures
for the same input. Reports without this field use version 1. Results and source locations are sorted for stable
diffs. If the reference has no declarations, text coverage is `n/a` and the JSON
count has no `percent` value. Extra declarations never increase coverage.
New reports also record each input's SHA-256 and compiler header.
Module selectors such as `Module::Type` use the same signature path as
`Module.Type`. Member selectors such as `Module::Outer.Module::Inner` reduce to
`Module.Outer.Inner`. This supports newer SDK interfaces; extension-origin
disambiguation is outside the declaration-path comparison model. Root module
names still follow the configured aliases and otherwise remain distinct.

## Local coverage site

The `site` subcommand converts JSON reports into a static site. It includes a
release coverage chart, project/target/module/profile filters, declaration
search, a near-miss view, counts by kind, input metadata, and an HTML table for embedding. Each
comparison group also has Markdown and SVG tables for README files.

Create the comparison reports first. Then prepare a manifest based on
[`Examples/site-manifest.json`](Examples/site-manifest.json). Report paths are
relative to the manifest. The example contains placeholder metadata, not results.

```sh
interface-coverage site --manifest results/manifest.json --output results/site
python3 -m http.server 8765 --bind 127.0.0.1 --directory results/site
```

Open `http://127.0.0.1:8765`. The generated directory can also be published to
GitHub Pages without a build step. It has no remote fonts, runtime dependencies,
or external requests. A local HTTP server is needed for declaration details;
the chart itself can also be opened from `index.html` without a server.

| Manifest field | Meaning |
| --- | --- |
| `schemaVersion` | Manifest format version. Currently `1`. |
| `title` | Optional site title. Defaults to `InterfaceCoverage`. |
| `siteURL` | Optional published site address, used for absolute links in summaries. |
| `reports` | Nonempty list of comparison reports. |
| `project`, `target`, `scope`, `profile` | Comparison group. Each group must use the same scan options and rules version. |
| `version`, `baseline` | Matrix row and column. Each cell must be unique in its group. |
| `report` | Path to an existing CLI JSON report. |
| `notes` | Optional input limitations shown with the chart/table and selected report. |
| `metadata` | Optional string-to-string provenance fields. These are shown in the report. |

Manifest order controls project, filter, baseline, and table row order. The main
page shows a grouped bar chart with a fixed 0–100% axis. Each group is a
candidate version, and each bar in a group is an SDK baseline. Numeric release
labels, including prereleases, sort from oldest to newest. Custom version labels
keep their manifest order. Select a bar to open its report, or select a legend
item to isolate a baseline and show its values. Bars support keyboard focus and
activation. Missing reports have no bar; empty references display `n/a` below
the chart. The HTML embed and Markdown/SVG exports remain version tables.

To collect OpenSwiftUI release reports, run
[`Scripts/collect_openswiftui_releases.py`](Scripts/collect_openswiftui_releases.py).
`collect` compares the iOS simulator and macOS interfaces of each release with
the SDK of each Xcode and generates the site. Downloads, inputs, and reports
stay in the ignored `.preview` directory by default.

```sh
swift build --package-path Tools/InterfaceCoverage -c release
python3 Tools/InterfaceCoverage/Scripts/collect_openswiftui_releases.py collect \
  --release 0.23.1 --release 0.23.0 \
  --xcode /Applications/Xcode-16.4.0.app --xcode /Applications/Xcode-26.6.0.app
```

Use `--all-releases` in place of `--release` to compare every published release
that includes both XCFrameworks. Pass `--site-url` to make summary links
absolute. Add `--include-manifest` with an earlier manifest to keep its reports
for other projects in the same site.

The results for one release, target, and SDK form a cache entry: one report for
each scope and a `cache.json` file. An entry is reused while its fingerprint
matches. The fingerprint covers the tool sources, the release asset digests,
and the SDK interfaces, so equal inputs share entries on every machine. Release
assets are downloaded with `gh` only when an entry must be generated.

With `--oci-repository`, missing entries are pulled from an OCI registry with
[`oras`](https://oras.land), and `--publish-oci-cache` pushes new entries. A
reference is `<version>-<sdk>-<fingerprint>`, and an existing reference is never
replaced. A local directory path uses an OCI image layout, which is useful for
offline tests.

To run each Xcode on a different machine, pass `--no-site` to `collect`, and
then build one site from their work directories:

```sh
python3 Tools/InterfaceCoverage/Scripts/collect_openswiftui_releases.py assemble \
  --input work-16.4 --input work-26.6 --site site
```

Labels come from the manifest; the generator does not infer a release from an interface.
Record the actual candidate commit, build SDK, compiler, build flags, dependency
versions, baseline SDK build, and tool revision when available. Use a distinct
profile for each comparison rule or tool revision. Baseline SDKs are independent
of the SDK used to build a candidate. Existing build artifacts with unknown source
revisions must be labeled as snapshots, not releases or current source coverage.

Published reports with the same reference inputs and matching rules share one
file of reference declarations under `pools/`. Each report lists its matched and
missing declarations as indices into that file, and keeps its extra declarations.
**Download JSON** gives the complete report with all declarations.

The site validates report schemas, counts, matrix cells, and scan options before
writing. An empty reference displays `n/a`; a missing matrix combination displays
`—`. Input warnings remain visible. Local input paths are replaced with logical
module paths in published reports. Interface hashes and compiler information are
preserved. Review user-supplied notes and metadata before publication.

The output directory must be empty or contain the generator's ownership marker.
Regeneration replaces the catalog and site assets. Report and table files are
named by content hash, so it removes the files that the new catalog does not
use. It does not accept input reports inside its output.

Select **Embed table** to copy an iframe for the current filters or download the
group's complete Markdown/SVG table. Query parameters retain project, target,
scope, profile, baseline, selected report, declaration status, kind, and search.
A `version` parameter selects a version when no report is selected.
The embedding page uses the same catalog and counts as the full report.

The `site` command does not collect releases, build candidates, schedule runs, or
deploy a site. It prepares the same output for local viewing and later CI publication.

## Badges and release summaries

The site also writes static files for other pages to use:

- `badges/<project>-<target>-<baseline>-<scope>-<profile>.json` is a
  [shields.io endpoint](https://shields.io/badges/endpoint-badge) for the latest
  version with a result. Each name part is lowercase, and other characters
  become `-`, for example
  `badges/openswiftui-ios-ios-18-5-swiftui-swiftuicore-default.json`.
- `summary/<project>/<version>.json` lists the coverage of one version for each
  target, baseline, scope, and profile. `summary/<project>/<version>.md` shows
  the same results as Markdown tables for release notes.

Summary links use `version` and `baseline` query parameters, which stay valid
when reports are generated again. Set `siteURL` in the manifest to make these
links absolute.

```text
https://img.shields.io/endpoint?url=https://openswiftuiproject.github.io/InterfaceCoverage/badges/openswiftui-ios-ios-18-5-swiftui-swiftuicore-default.json
```

To add a release summary to GitHub release notes, run
[`Scripts/update_release_notes.py`](Scripts/update_release_notes.py). It writes
an `## Interface Coverage` section between `<!-- interface-coverage:start -->`
and `<!-- interface-coverage:end -->` markers, with a link to the version's full
report. When it runs again, it replaces that section in place. Without the
markers, it adds the section at the end of the notes. Use `--dry-run` to print
the result without editing the release.

```sh
python3 Tools/InterfaceCoverage/Scripts/update_release_notes.py --version 0.23.1 \
  --summary https://openswiftuiproject.github.io/InterfaceCoverage/summary/openswiftui/0.23.1.json \
  --baseline "iOS 18.5" --baseline "macOS 15.5"
```

## Deployment

[`.github/workflows/pages.yml`](.github/workflows/pages.yml) publishes the site
to GitHub Pages at <https://openswiftuiproject.github.io/InterfaceCoverage/>.
It runs on a push to `main`, on manual dispatch, and when an OpenSwiftUI release
sends an `openswiftui-release` repository dispatch with `client_payload.version`.
All jobs use GitHub-hosted runners.

1. `tool` builds the tool on `macos-26`. `actions/cache` keeps `.build` for the
   same sources.
2. `compare` runs `collect --all-releases` once for each baseline Xcode, on the
   runner image that includes it: Xcode 16.4 (iOS 18.5 and macOS 15.5) on
   `macos-15`, Xcode 26.6 on `macos-26`, and Xcode 27.0 on `xcode-27`. SDK
   interfaces are read on that runner and are not stored. Cache entries are
   pulled from and pushed to `ghcr.io/openswiftuiproject/interface-coverage-cache`
   with `GITHUB_TOKEN`, so only new releases or changed tool sources are
   compared again.
3. `site` assembles the reports of all baselines, and `deploy` publishes them
   with `actions/deploy-pages`. The Pages source of this repository is GitHub
   Actions.
4. For a release dispatch, `update_release_notes.py` adds the iOS 18.5 and
   macOS 15.5 table to the OpenSwiftUI release notes. This needs the
   `OPENSWIFTUI_RELEASE_PAT` secret: a fine-grained token with write access to
   the contents of OpenSwiftUIProject/OpenSwiftUI.

The published site and the cache entries include the reference declarations of
each SDK baseline, because the declaration lists show matched and missing APIs.

## Comparison flags

| Option | Effect |
| --- | --- |
| `--module-alias Source=Target` | Map a module prefix on both sides. Repeat to add mappings. |
| `--ignore-namespace NAME` | Flatten a namespace container in owners and qualified type paths on both sides. Repeat for more names. |
| `--no-default-aliases` | Start with no module aliases. |
| `--exclude-underscored` | Exclude names and enclosing types that start with `_`. |
| `--include-spi` | Include declarations marked with `@_spi`. Supply private interfaces when needed. |
| `--allow-target-mismatch` | Permit an approximate comparison across target platforms or environments. |
| `--show-missing` | Include missing declarations in text output. |
| `--show-near-misses` | Include missing and extra declarations with the same kind, owner, and name in text output. |
| `--format text\|json` | Select the report format. |
| `--output PATH` | Write atomically to a report file instead of standard output. |

Default module aliases are:

| Source | Target |
| --- | --- |
| `OpenSwiftUI` | `SwiftUI` |
| `OpenSwiftUICore` | `SwiftUICore` |
| `OpenCombine` | `Combine` |
| `OpenCombineFoundation` | `Combine` |
| `OpenCombineDispatch` | `Combine` |
| `OpenObservation` | `Observation` |

Other module prefixes are kept. Alias chains are supported; cycles are errors.
Files for different operating systems or simulator/device environments are
rejected by default. Different architectures produce a warning. Deployment target
versions can differ because an interface can declare APIs newer than that target.

## Counting rules

- Count public/open types, functions, initializers, properties, subscripts,
  type aliases, protocol associated types and requirements, enum cases, macros,
  operators, and precedence groups. Each overload is a separate declaration.
- Count each explicit inheritance or conformance relationship separately from
  the type declaration. A missing conformance does not hide a matching type.
- Exclude internal/package/private declarations, declarations in hidden types,
  SPI by default, and declarations explicitly unavailable on all platforms or
  on the reference target platform. Underscored public names are included by
  default because they appear in public interfaces.
- Compare owners, declaration kinds, parameter labels and types, generic
  requirements, return types, static/instance modifiers, mutation modifiers,
  async/throws effects, property accessors, and macro roles.
- Normalize mapped module prefixes, `Swift.` type prefixes, whitespace, comments,
  local parameter names, generic parameter names, and generic requirement order.
  Ignore the `__owned` and `__shared` parameter specifiers, which spell default
  ownership conventions. `borrowing`, `consuming`, and `inout` remain distinct.
  In `@_opaqueReturnTypeOf` references, ignore the mangled name, which contains
  the module name, and compare the owner, ordinal, and generic arguments.
  An inline generic constraint and the same `where` constraint are equivalent.
  `T: P & Q` and `T: P, T: Q` are equivalent. An opaque parameter type, such as
  `some View`, is a generic parameter after the declared generic parameters,
  as in the compiler.
- Operator parameters have no external labels. Their local names, such as
  `lhs`/`rhs` or `a`/`b`, are ignored for all operators, including `static ==`.
  Ordinary function labels still distinguish overloads. Namespace containers
  are normalized only when selected with `--ignore-namespace`.
- Expand a member typealias, such as `SwiftUI.Key.Value` or
  `Combine.Just<T>.Failure`, when both sides declare that typealias. Each side
  uses its own definition, and the owner's generic arguments replace its
  generic parameters. A typealias declared on one side only is kept, because it
  can stand in for a type on the other side. Module-level and generic
  typealiases are not expanded.
- Apply same-type requirements. In `func body() -> Self.Body where Self.Body ==
  Never`, the return type is `Never`. A dependent member type, such as
  `Self.Body` or `T.Element`, is replaced with the other side. When both sides
  are dependent member types, one consistent spelling is used.
- Ignore parameter names in function types, such as `(_ value: Int) -> Void`.
  An empty tuple type `()` is `Void`. Tuple element labels remain distinct.
- Write normalized signatures with standard Swift spacing, such as
  `func map<T1>(_: (T0) -> T1) -> SwiftUI.Box<T1>`. Generic parameters are
  numbered from the outermost scope.
- Preserve whether a default argument exists, but ignore its expression.
  Ignore function/accessor bodies, enum raw values, documentation, declaration
  attributes other than SPI/availability filters and macro roles, and modifiers
  such as `final`, `override`, and `nonisolated`.
- Read all `#if` branches and deduplicate equal signatures. This is the union of
  emitted declarations, not an evaluation of compiler features or build flags.

This is a syntactic comparison, not a Swift type checker or an ABI checker. It
does not expand other type aliases, infer transitive conformances, resolve inherited
members, equate all equivalent Swift type spellings, or check actor isolation,
ownership in accessors, calling conventions, default values, or availability
version ranges. Generic names from an external type can only be normalized when
its declaring interface is also supplied. Malformed syntax and unsupported
declaration kinds fail the scan instead of silently producing partial coverage.
