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
swift test --package-path Tools/InterfaceCoverage --filter InterfaceScannerTests
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

| Option | Effect |
| --- | --- |
| `--module-alias Source=Target` | Map a module prefix on both sides. Repeat to add mappings. |
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
