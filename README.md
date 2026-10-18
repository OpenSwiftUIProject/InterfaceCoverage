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
to list missing signatures and their source locations. JSON includes all matched,
missing, and extra declarations with file paths and line numbers:

```sh
interface-coverage \
  --reference path/to/SwiftUI.swiftinterface \
  --candidate path/to/OpenSwiftUI.swiftinterface \
  --format json --output coverage.json
```

JSON includes the input module names and targets, scan options, warnings, and a
versioned `coverage` object. Results and source locations are sorted for stable
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
search, counts by kind, input metadata, and an HTML table for embedding. Each
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
| `reports` | Nonempty list of comparison reports. |
| `project`, `target`, `scope`, `profile` | Comparison group. Each group must use the same scan options. |
| `version`, `baseline` | Matrix row and column. Each cell must be unique in its group. |
| `report` | Path to an existing CLI JSON report. |
| `notes` | Optional input limitations shown with the chart/table and selected report. |
| `metadata` | Optional string-to-string provenance fields. These are shown in the report. |

Manifest order controls project, filter, baseline, and table row order. The main
page shows a line chart with one series per SDK baseline and a fixed 0–100% axis.
Numeric release labels, including prereleases, sort from oldest to newest. Custom
version labels keep their manifest order. Select a point to open its report, or
select a legend item to isolate a baseline. Points support keyboard focus and
activation. Missing reports leave gaps; empty references display `n/a` below the
chart. The HTML embed and Markdown/SVG exports remain version tables.

Labels come from the manifest; the generator does not infer a release from an interface.
Record the actual candidate commit, build SDK, compiler, build flags, dependency
versions, baseline SDK build, and tool revision when available. Use a distinct
profile for each comparison rule or tool revision. Baseline SDKs are independent
of the SDK used to build a candidate. Existing build artifacts with unknown source
revisions must be labeled as snapshots, not releases or current source coverage.

The site validates report schemas, counts, matrix cells, and scan options before
writing. An empty reference displays `n/a`; a missing matrix combination displays
`—`. Input warnings remain visible. Local input paths are replaced with logical
module paths in published reports. Interface hashes and compiler information are
preserved. Review user-supplied notes and metadata before publication.

The output directory must be empty or contain the generator's ownership marker.
Regeneration replaces the catalog and site assets and keeps existing report files.
It does not remove historical files or accept input reports inside its output.

Select **Embed table** to copy an iframe for the current filters or download the
group's complete Markdown/SVG table. Query parameters retain project, target,
scope, profile, baseline, selected report, declaration status, kind, and search.
The embedding page uses the same catalog and counts as the full report.

This command does not collect releases, build candidates, schedule runs, or deploy
a site. It prepares the same output for local viewing and later CI publication.

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
  An inline generic constraint and the same `where` constraint are equivalent.
- Operator parameters have no external labels. Their local names, such as
  `lhs`/`rhs` or `a`/`b`, are ignored for all operators, including `static ==`.
  Ordinary function labels still distinguish overloads. Namespace containers
  are normalized only when selected with `--ignore-namespace`.
- Preserve whether a default argument exists, but ignore its expression.
  Ignore function/accessor bodies, enum raw values, documentation, declaration
  attributes other than SPI/availability filters and macro roles, and modifiers
  such as `final`, `override`, and `nonisolated`.
- Read all `#if` branches and deduplicate equal signatures. This is the union of
  emitted declarations, not an evaluation of compiler features or build flags.

This is a syntactic comparison, not a Swift type checker or an ABI checker. It
does not expand type aliases, infer transitive conformances, resolve inherited
members, equate all equivalent Swift type spellings, or check actor isolation,
ownership in accessors, calling conventions, default values, or availability
version ranges. Generic names from an external type can only be normalized when
its declaring interface is also supplied. Malformed syntax and unsupported
declaration kinds fail the scan instead of silently producing partial coverage.
