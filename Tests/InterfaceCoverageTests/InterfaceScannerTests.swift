import Testing
@testable import InterfaceCoverage

struct InterfaceScannerTests {
    @Test func moduleSelectorsMatchLegacyTypePathsAndExtensionOwners() throws {
        let result = try compare(
            """
            public struct Box<Element> { public struct Nested {} }
            extension SwiftUI::Box {
              public func map<Output>(_ transform: (Element) -> Swift::Optional<Output>) -> SwiftUI::Box<Output>.SwiftUI::Nested
            }
            public func wrap<T>(_ value: T) -> Swift::Optional<T>.SwiftUI::Publisher
            """,
            """
            public struct Box<Value> { public struct Nested {} }
            extension OpenSwiftUI.Box {
              public func map<Result>(_ transform: (Value) -> Swift.Optional<Result>) -> OpenSwiftUI.Box<Result>.Nested
            }
            public func wrap<U>(_ value: U) -> Swift.Optional<U>.Publisher
            """
        )
        #expect(result.summary.reference == 4)
        #expect(result.summary.matched == 4)
    }

    @Test func rootModuleSelectorsKeepExternalModuleIdentity() throws {
        let result = try compare(
            "public func read() -> First::Value",
            "public func read() -> Second::Value"
        )
        #expect(result.summary.matched == 0)
        #expect(result.summary.missing == 1)
    }

    @Test func moduleSelectorIsNotRenamedAsAGenericParameter() throws {
        let result = try compare(
            "public func read<External>(_ value: External) -> External::Value",
            "public func read<T>(_ value: T) -> External.Value"
        )
        #expect(result.summary.matched == 1)
    }

    private func input(_ source: String, module: String = "SwiftUI") -> InterfaceInput {
        InterfaceInput(path: "\(module).swiftinterface", module: module, source: source)
    }

    private func compare(_ reference: String, _ candidate: String) throws -> CoverageReport {
        try InterfaceScanner().compare(reference: [input(reference)], candidate: [input(candidate, module: "OpenSwiftUI")])
    }

    @Test func moduleAliasesBodiesAndLocalParameterNames() throws {
        let result = try compare(
            """
            public struct Label {
              public init(_ text: Swift.String)
              public func value(for key: Swift.Int = 0) -> SwiftUI.Label
            }
            """,
            """
            public struct Label {
              public init(_ value: Swift.String) {}
              @inlinable public func value(for index: Swift.Int = 1) -> OpenSwiftUI.Label {
                func helper() {}
                return self
              }
            }
            """
        )
        #expect(result.summary.reference == 3)
        #expect(result.summary.matched == 3)
        #expect(result.summary.extra == 0)
    }

    @Test func nearMissesPairMissingAndExtraDeclarationsByName() throws {
        let result = try compare(
            """
            public struct Value {
              public func read(_ x: Swift.Int) -> Swift.Int
              public func write(_ x: Swift.Int)
              public func keep()
            }
            """,
            """
            public struct Value {
              public func read(_ x: Swift.Int) -> Swift.String
              public func read(_ x: Swift.Int) -> Swift.Bool
              public func store(_ x: Swift.Int)
              public func keep()
            }
            """
        )
        #expect(result.summary.missing == 2)
        #expect(result.summary.extra == 3)
        let nearMisses = result.nearMisses
        #expect(nearMisses.count == 1)
        #expect(nearMisses.first?.name == "read")
        #expect(nearMisses.first?.missing.count == 1)
        #expect(nearMisses.first?.extra.count == 2)
    }

    @Test func openObservationMatchesObservationByDefault() throws {
        let result = try compare(
            "public func track<T>(_ value: T) where T: AnyObject, T: Observation.Observable",
            "public func track<T>(_ value: T) where T: AnyObject, T: OpenObservation.Observable"
        )
        #expect(result.summary.matched == 1)
    }

    @Test func defaultOwnershipSpecifiersDoNotAffectCoverage() throws {
        let result = try compare(
            """
            public func receive<S>(subscriber: __owned S)
            public func read(_ value: __shared Swift.String)
            public func take(_ value: consuming Swift.String)
            """,
            """
            public func receive<S>(subscriber: S)
            public func read(_ value: Swift.String)
            public func take(_ value: Swift.String)
            """
        )
        #expect(result.summary.matched == 2)
        #expect(result.missing.map(\.name) == ["take"])
    }

    @Test func opaqueReturnTypeReferencesIgnoreMangledNames() throws {
        let result = try compare(
            """
            public struct Box<Content> {
              public typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI3BoxV4bodyQrvp", 0) __<Content>
              public typealias Other = @_opaqueReturnTypeOf("$s7SwiftUI3BoxV5otherQrvp", 1) __<Content>
            }
            """,
            """
            public struct Box<Content> {
              public typealias Body = @_opaqueReturnTypeOf("$s11OpenSwiftUI3BoxV4bodyQrvp", 0) __<Content>
              public typealias Other = @_opaqueReturnTypeOf("$s11OpenSwiftUI3BoxV5otherQrvp", 0) __<Content>
            }
            """
        )
        #expect(result.summary.reference == 3)
        #expect(result.summary.matched == 2)
        #expect(result.missing.map(\.name) == ["Other"])
    }

    @Test func opaqueParametersMatchTrailingGenericParameters() throws {
        let result = try compare(
            """
            public protocol View {}
            public func apply<T, V>(content: V, value: T, other: T) -> some SwiftUI.View where V: SwiftUI.View
            public func pair<A, B>(_ a: A, _ b: B) where A: SwiftUI.View, A: Swift.Sendable, B: SwiftUI.View
            public struct Box { public init<V>(_ content: V) where V: SwiftUI.View }
            public func swapped<V, T>(content: V, value: T) where V: SwiftUI.View
            """,
            """
            public protocol View {}
            public func apply<T>(content: some OpenSwiftUI.View, value: T, other: T) -> some OpenSwiftUI.View
            public func pair(_ a: some OpenSwiftUI.View & Swift.Sendable, _ b: some OpenSwiftUI.View)
            public struct Box { public init(_ content: some OpenSwiftUI.View) }
            public func swapped<T>(content: some OpenSwiftUI.View, value: T)
            """
        )
        #expect(result.summary.reference == 6)
        // An opaque parameter follows the explicit generic parameters.
        #expect(result.missing.map(\.name) == ["swapped"])
    }

    @Test func signaturesUseSwiftSpacing() throws {
        let inventory = try InterfaceScanner().scan([input(
            """
            public struct Box<Value> {
              public func map<T>(_ transform: @escaping @Sendable (Value) throws -> T?, values: [Swift.String : [T]] = [:], rest: T...) async rethrows -> SwiftUI.Box<(T, Value)>.Type where T: Swift.Hashable & Swift.Sendable, T == Value.Element
              public typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI3BoxV4bodyQrvp", 0) __<Value>
              public var handler: () -> Swift.Void { get set }
            }
            infix operator <>: AdditionPrecedence
            """
        )])
        let signatures = Set(inventory.entries.map(\.signature))
        #expect(signatures.contains(
            "func map<T1>(_: @escaping @Sendable (T0) throws -> T1?, values: [String: [T1]] = default, rest: T1...) async rethrows -> SwiftUI.Box<(T1, T0)>.Type where T0.Element == T1, T1: Hashable, T1: Sendable"
        ))
        #expect(signatures.contains("typealias Body = @_opaqueReturnTypeOf(_, 0) __<T0>"))
        #expect(signatures.contains("var handler: () -> Void { get set }"))
        #expect(signatures.contains("infix operator <>: AdditionPrecedence"))
    }

    @Test func sharedMemberTypealiasesAreExpanded() throws {
        let result = try compare(
            """
            public struct Key { public typealias Value = Swift.Int? }
            extension SwiftUI.Key { public static func reduce(value: inout SwiftUI.Key.Value) }
            public struct Just<Output> {
              public typealias Failure = Swift.Never
              public typealias Pair = (Output, SwiftUI.Just<Output>.Failure)
              public func first() -> SwiftUI.Just<Output>.Pair
              public func swapped<T>(_ value: SwiftUI.Just<T>.Pair) -> SwiftUI.Just<(Output, T)>.Failure
            }
            public struct Angle { public typealias AnimatableData = Swift.Double; public var animatableData: Swift.Double }
            public struct Stand { public typealias Value = Swift.Int }
            public func use(_ value: SwiftUI.Stand.Value)
            public struct Wrapper<T> {}
            public func wrap(_ value: SwiftUI.Wrapper<SwiftUI.Key.Value>)
            """,
            """
            public struct Key { public typealias Value = Swift.Optional<Swift.Int> }
            extension OpenSwiftUI.Key { public static func reduce(value: inout Swift.Int?) }
            public struct Just<Output> {
              public typealias Failure = Swift.Never
              public typealias Pair = (Output, Swift.Never)
              public func first() -> (Output, Swift.Never)
              public func swapped<T>(_ value: (T, Swift.Never)) -> Swift.Never
            }
            public struct Angle { public typealias AnimatableData = Swift.Double; public var animatableData: OpenSwiftUI.Angle.AnimatableData }
            public struct Stand { public struct Value {} }
            public func use(_ value: OpenSwiftUI.Stand.Value)
            public struct Wrapper<T> {}
            public func wrap(_ value: OpenSwiftUI.Wrapper<Swift.Int?>)
            """
        )
        // Each side expands `Key.Value` with its own definition. `Stand.Value`
        // is a typealias on one side only, so it is not expanded.
        #expect(result.missing.map(\.name) == ["Value", "Value"])
        #expect(result.matched.contains { $0.name == "reduce" })
        #expect(result.matched.contains { $0.name == "use" })
        #expect(result.matched.contains { $0.name == "wrap" })
    }

    @Test func sameTypeRequirementsCanonicalizeDependentTypes() throws {
        let result = try compare(
            """
            public protocol Style { associatedtype Resolved }
            extension SwiftUI.Style where Self.Resolved == Swift.Never { public func resolve() -> Swift.Never }
            public protocol Modifier { associatedtype Body }
            extension SwiftUI.Modifier where Self.Body == Swift.Never { public func body() -> Self.Body }
            public func first<C, T>(_ c: C) -> C.Element where C: Swift.Collection, C.Element == T
            public func pair<A, B>(_ a: A, _ b: B) -> A.Element where A: Swift.Sequence, B: Swift.Sequence, A.Element == B.Element
            public func other<C>(_ c: C) -> C.Element where C: Swift.Collection, C.Index == Swift.Int
            """,
            """
            public protocol Style { associatedtype Resolved }
            extension OpenSwiftUI.Style where Self.Resolved == Swift.Never { public func resolve() -> Self.Resolved }
            public protocol Modifier { associatedtype Body }
            extension OpenSwiftUI.Modifier where Self.Body == Swift.Never { public func body() -> Swift.Never }
            public func first<C, T>(_ c: C) -> T where C: Swift.Collection, C.Element == T
            public func pair<A, B>(_ a: A, _ b: B) -> B.Element where A: Swift.Sequence, B: Swift.Sequence, A.Element == B.Element
            public func other<C>(_ c: C) -> Swift.Int where C: Swift.Collection, C.Index == Swift.Int
            """
        )
        #expect(result.missing.map(\.name) == ["other"])
    }

    @Test func overloadsReturnTypesAndExternalModulesRemainDistinct() throws {
        let result = try compare(
            """
            public func read(_ x: Swift.Int) -> Swift.String
            public func read(_ x: Swift.String) -> Swift.String
            public func load(_ x: One.Value) -> Swift.Bool
            """,
            """
            public func read(_ x: Swift.Int) -> Swift.Int
            public func read(_ x: Swift.String) -> Swift.String
            public func load(_ x: Two.Value) -> Swift.Bool
            """
        )
        #expect(result.summary.reference == 3)
        #expect(result.summary.matched == 1)
        #expect(result.summary.missing == 2)
        #expect(result.summary.extra == 2)
    }

    @Test func genericNamesAndRequirementOrderDoNotChangeCoverage() throws {
        let result = try compare(
            """
            public struct Box<Value: Swift.Equatable> {
              public func map<T>(_ f: (Value) -> T) -> T where T: Swift.Hashable, T: Swift.Sendable
            }
            extension SwiftUI.Box where Value: Swift.Hashable {
              public func hashValue() -> Swift.Int
            }
            """,
            """
            public struct Box<Element> where Element: Swift.Equatable {
              public func map<Result>(_ f: (Element) -> Result) -> Result where Result: Swift.Sendable, Result: Swift.Hashable
            }
            extension OpenSwiftUI.Box where Element: Swift.Hashable {
              public func hashValue() -> Swift.Int
            }
            """
        )
        #expect(result.summary.reference == 3)
        #expect(result.summary.matched == 3)
    }

    @Test func extensionConstraintsAndMutabilityAffectSignatures() throws {
        let result = try compare(
            """
            public struct Box<T> {
              public var value: T { get set }
              public subscript(_ index: Swift.Int) -> T { get }
            }
            extension SwiftUI.Box where T: Swift.Equatable { public func check() }
            """,
            """
            public struct Box<T> {
              public var value: T { get }
              public subscript(_ index: Swift.Int) -> T { get }
            }
            extension OpenSwiftUI.Box where T: Swift.Hashable { public func check() }
            """
        )
        #expect(result.summary.reference == 4)
        #expect(result.summary.matched == 2)
    }

    @Test func protocolRequirementsNestedTypesAndEnumCases() throws {
        let inventory = try InterfaceScanner().scan([input("""
            public protocol Source {
              associatedtype Output
              var value: Self.Output { get }
              func next() -> Self.Output
            }
            public enum Result {
              case success(Swift.Int), failure(message: Swift.String)
              public struct Detail { public init() }
            }
            """)])
        #expect(inventory.entries.count == 9)
        #expect(inventory.entries.filter { $0.kind == .enumCase }.count == 2)
        #expect(inventory.entries.contains { $0.owner == "SwiftUI.Result.Detail" && $0.kind == .initializer })
    }

    @Test func filtersRespectEnclosingAccessSPIAndAvailability() throws {
        let source = """
            internal struct Hidden { public func hidden() }
            @_spi(Private) public struct Secret { public func hidden() }
            @available(*, unavailable) public struct Removed { public func hidden() }
            @available(iOS, unavailable) public struct Desktop { public func hidden() }
            public struct Visible {
              internal func hidden()
              @usableFromInline internal var storage: Swift.Int
              public private(set) var value: Swift.Int
              public func _hook()
            }
            public protocol _InternalProtocol { func hidden() }
            """
        let options = ScanOptions(excludeUnderscored: true, platform: "iOS")
        let inventory = try InterfaceScanner(options: options).scan([input(source)])
        #expect(inventory.entries.count == 2)
        #expect(inventory.entries.contains { $0.name == "value" && !$0.signature.contains("set") })
    }

    @Test func conditionalBranchesAndRepeatedInputsAreDeduplicated() throws {
        let source = """
            #if compiler(>=5.3) && $Feature
            public func value(_ x: Swift.Int)
            #else
            public func value(_ y: Swift.Int)
            #endif
            """
        let inventory = try InterfaceScanner().scan([input(source), input(source)])
        #expect(inventory.entries.count == 1)
        #expect(inventory.entries.first?.locations.count == 2)
    }

    @Test func inheritanceIsCountedApartFromTheType() throws {
        let result = try compare(
            "public struct Value: Swift.Equatable, Swift.Hashable {}",
            """
            public struct Value {}
            extension OpenSwiftUI.Value: Swift.Equatable {}
            """
        )
        #expect(result.summary.reference == 3)
        #expect(result.summary.matched == 2)
        #expect(result.missing.first?.kind == .inheritance)
    }

    @Test func typealiasesStaticMembersAndEffectsAreCompared() throws {
        let result = try compare(
            """
            public typealias Count = Swift.Int
            public struct S {
              public static func run() async throws -> Swift.Int
              public init?(_ value: Swift.Int)
            }
            """,
            """
            public typealias Count = Swift.String
            public struct S {
              public func run() -> Swift.Int
              public init(_ value: Swift.Int)
            }
            """
        )
        #expect(result.summary.reference == 4)
        #expect(result.summary.matched == 1)
    }

    @Test func multipleModulesMatchExtensionsAcrossFiles() throws {
        let scanner = InterfaceScanner()
        let reference = try scanner.scan([
            input("public struct Value {}", module: "SwiftUICore"),
            input("extension SwiftUICore.Value { public func show() }"),
        ])
        let candidate = try scanner.scan([
            input("public struct Value { public func show() }", module: "OpenSwiftUICore"),
        ])
        let result = CoverageReport.compare(reference: reference, candidate: candidate)
        #expect(result.summary.reference == 2)
        #expect(result.summary.matched == 2)
    }

    @Test func malformedInputFailsInsteadOfReturningPartialCoverage() throws {
        #expect(throws: CoverageError.self) {
            try InterfaceScanner().scan([input("public struct Broken { public func value(")])
        }
    }

    @Test func emptyReferenceHasNoPercentage() throws {
        let result = try compare("", "public struct Extra {}")
        #expect(result.summary.percent == nil)
        #expect(result.summary.extra == 1)
    }

    @Test func moduleMergingIsExplicitAndAliasesCanChain() throws {
        let reference = input("public struct Value {}", module: "SwiftUI")
        let candidate = input("public struct Value {}", module: "OpenSwiftUICore")
        let scanner = InterfaceScanner()
        let separate = try CoverageReport.compare(reference: scanner.scan([reference]), candidate: scanner.scan([candidate]))
        #expect(separate.summary.matched == 0)

        var options = ScanOptions()
        options.moduleAliases["SwiftUICore"] = "SwiftUI"
        let combinedScanner = InterfaceScanner(options: options)
        let combined = try CoverageReport.compare(reference: combinedScanner.scan([reference]), candidate: combinedScanner.scan([candidate]))
        #expect(combined.summary.matched == 1)
    }

    @Test func cyclicAliasesAreRejected() throws {
        let options = ScanOptions(moduleAliases: ["One": "Two", "Two": "One"])
        #expect(throws: CoverageError.self) {
            try InterfaceScanner(options: options).scan([input("public struct Value {}")])
        }
    }

    @Test func spiCanBeIncludedAndUnavailableExtensionsAreExcluded() throws {
        let source = input("""
            @_spi(Private) public struct Secret { public func value() }
            @available(*, unavailable) extension SwiftUI.Secret: Swift.Sendable {}
            """)
        let inventory = try InterfaceScanner(options: ScanOptions(includeSPI: true)).scan([source])
        #expect(inventory.entries.count == 2)
        #expect(!inventory.entries.contains { $0.kind == .inheritance })
    }

    @Test func extensionBeforeGenericTypeIsIndependentOfInputOrder() throws {
        let extensionInput = input("extension SwiftUI.Box where Value: Swift.Hashable { public func check() }")
        let typeInput = input("public struct Box<Value> {}")
        let scanner = InterfaceScanner()
        let forward = try scanner.scan([extensionInput, typeInput])
        let backward = try scanner.scan([typeInput, extensionInput])
        #expect(forward.entries.map(\.id) == backward.entries.map(\.id))
        #expect(forward.entries.first { $0.kind == .function }?.signature.contains("T0: Hashable") == true)
    }

    @Test func macroRolesAndDefaultArgumentPresenceAffectCoverage() throws {
        let result = try compare(
            """
            @freestanding(expression) public macro value() -> Swift.Int = #externalMacro(module: "Macros", type: "Value")
            public func run(_ value: Swift.Int = 0)
            """,
            """
            @attached(peer) public macro value() -> Swift.Int = #externalMacro(module: "Macros", type: "Value")
            public func run(_ value: Swift.Int)
            """
        )
        #expect(result.summary.reference == 2)
        #expect(result.summary.matched == 0)
    }

    @Test func platformIdentityIgnoresDeploymentVersionButKeepsEnvironment() {
        let macOS = TargetPlatform(triple: "arm64e-apple-macos26.5")
        let oldMacOS = TargetPlatform(triple: "arm64-apple-macosx15.0")
        #expect(macOS?.platform == "macOS")
        #expect(macOS?.comparisonKey == oldMacOS?.comparisonKey)
        let simulator = TargetPlatform(triple: "arm64-apple-ios18.0-simulator")
        let device = TargetPlatform(triple: "arm64-apple-ios18.0")
        #expect(simulator?.comparisonKey != device?.comparisonKey)
        #expect(TargetPlatform(triple: "arm64-apple-ios18.0-macabi")?.platform == "macCatalyst")
    }

    @Test func subscriptParameterNamesAreLocalUnlessALabelIsExplicit() throws {
        let result = try compare(
            """
            public struct Buffer {
              public subscript(position: Swift.Int) -> Swift.Int { get }
              public subscript(at position: Swift.String) -> Swift.Int { get }
            }
            """,
            """
            public struct Buffer {
              public subscript(_ index: Swift.Int) -> Swift.Int { get }
              public subscript(for key: Swift.String) -> Swift.Int { get }
            }
            """
        )
        #expect(result.summary.reference == 3)
        #expect(result.summary.matched == 2)
    }

    @Test func operatorParameterNamesDoNotAffectCoverage() throws {
        let result = try compare(
            """
            public struct Value {
              public static func ==(lhs: SwiftUI.Value, rhs: SwiftUI.Value) -> Swift.Bool
              public static prefix func -(value: SwiftUI.Value) -> SwiftUI.Value
              public func compare(lhs: SwiftUI.Value) -> Swift.Bool
            }
            """,
            """
            public struct Value {
              public static func ==(a: OpenSwiftUI.Value, b: OpenSwiftUI.Value) -> Swift.Bool
              public static prefix func -(operand: OpenSwiftUI.Value) -> OpenSwiftUI.Value
              public func compare(value: OpenSwiftUI.Value) -> Swift.Bool
            }
            """
        )
        #expect(result.summary.reference == 4)
        #expect(result.summary.matched == 3)
        #expect(result.missing.first?.name == "compare")
    }

    @Test func namespaceIgnoringIsOptInAndNormalizesOwnersAndTypePaths() throws {
        let reference = input("""
            extension Swift.Optional {
              public struct Publisher {
                public func receive(_ value: Wrapped) -> Swift.Optional<Wrapped>.Publisher
              }
              public var publisher: Swift.Optional<Wrapped>.Publisher { get }
            }
            public func consume(_ publisher: Swift.Optional<Swift.Int>.Publisher)
            """)
        let candidate = input("""
            extension Swift.Optional {
              public struct Adapter {
                public struct Publisher {
                  public func receive(_ element: Wrapped) -> Swift.Optional<Wrapped>.Adapter.Publisher
                }
              }
              public var publisher: Swift.Optional<Wrapped>.Adapter.Publisher { get }
            }
            public func consume(_ publisher: Swift.Optional<Swift.Int>.Adapter.Publisher)
            """, module: "OpenSwiftUI")
        let strict = InterfaceScanner()
        let strictReport = try CoverageReport.compare(reference: strict.scan([reference]), candidate: strict.scan([candidate]))
        #expect(strictReport.summary.reference == 4)
        #expect(strictReport.summary.matched == 0)

        let scanner = InterfaceScanner(options: ScanOptions(ignoredNamespaces: ["Adapter"]))
        let report = try CoverageReport.compare(reference: scanner.scan([reference]), candidate: scanner.scan([candidate]))
        #expect(report.summary.reference == 4)
        #expect(report.summary.matched == 4)
        #expect(report.summary.extra == 0)
    }

    @Test func namespaceRulesPreserveNamesLabelsModulesAndGenericArguments() throws {
        let options = ScanOptions(moduleAliases: [:], ignoredNamespaces: ["Adapter", "Layer"])
        let scanner = InterfaceScanner(options: options)
        let reference = input("""
            public struct Value {
              public func Adapter(Adapter value: Swift.Int) -> Adapter.Value
            }
            public struct AdapterExtra {}
            public func use<T>(_ value: Adapter.Box<Adapter.Value>.Child<T>)
            """, module: "Adapter")
        let candidate = input("""
            public enum Adapter {
              public enum Layer {
                public struct Value {
                  public func Adapter(Adapter value: Swift.Int) -> Adapter.Adapter.Layer.Value
                }
              }
            }
            public struct AdapterExtra {}
            public func use<T>(_ value: Adapter.Box<Adapter.Adapter.Layer.Value>.Layer.Child<T>)
            """, module: "Adapter")
        let report = try CoverageReport.compare(reference: scanner.scan([reference]), candidate: scanner.scan([candidate]))
        #expect(report.summary.reference == 4)
        #expect(report.summary.matched == 4)
        #expect(report.summary.extra == 0)
        #expect(report.matched.contains { $0.name == "Adapter" && $0.signature.contains("Adapter:") })
    }

    @Test func namespaceRulesPreserveGenericTypeScopesAcrossExtensions() throws {
        let scanner = InterfaceScanner(options: ScanOptions(ignoredNamespaces: ["Adapter"]))
        let reference = input("""
            public struct Box<Value> {
              public func read() -> Value
            }
            """)
        let candidate = input("""
            public enum Adapter {
              public struct Box<Element> {}
            }
            extension OpenSwiftUI.Adapter.Box {
              public func read() -> Element
            }
            """, module: "OpenSwiftUI")
        let report = try CoverageReport.compare(reference: scanner.scan([reference]), candidate: scanner.scan([candidate]))
        #expect(report.summary.reference == 2)
        #expect(report.summary.matched == 2)
    }

    @Test func namespaceRulesDeduplicateMatchesWithoutExposingHiddenTypes() throws {
        let source = input("""
            public struct Value { public func read() }
            public enum Adapter {
              public struct Value { public func read() }
            }
            private enum Layer {
              public struct Hidden { public func read() }
            }
            """)
        let scanner = InterfaceScanner(options: ScanOptions(ignoredNamespaces: ["Adapter", "Layer"]))
        let inventory = try scanner.scan([source])
        #expect(inventory.entries.count == 2)
        #expect(inventory.entries.allSatisfy { $0.locations.count == 2 })
    }

    @Test func invalidNamespaceRulesAndGenericNamespacesAreRejected() throws {
        for name in ["", "Outer.Inner", "123", "A<T>"] {
            #expect(throws: CoverageError.self) {
                try InterfaceScanner(options: ScanOptions(ignoredNamespaces: [name])).scan([])
            }
        }
        #expect(throws: CoverageError.self) {
            try InterfaceScanner(options: ScanOptions(ignoredNamespaces: ["Adapter"]))
                .scan([input("public struct Adapter<T> { public struct Value {} }")])
        }
    }

    @Test func namespaceNormalizationPrecedesStandardLibraryPrefixRemoval() throws {
        let scanner = InterfaceScanner(options: ScanOptions(ignoredNamespaces: ["Layer"]))
        let reference = input("""
            public struct Value {
              public func read(_ value: Swift.Value) -> Swift.Value
            }
            """, module: "Swift")
        let candidate = input("""
            public enum Layer {
              public struct Value {
                public func read(_ value: Swift.Layer.Value) -> Swift.Layer.Value
              }
            }
            """, module: "Swift")
        let report = try CoverageReport.compare(reference: scanner.scan([reference]), candidate: scanner.scan([candidate]))
        #expect(report.summary.reference == 2)
        #expect(report.summary.matched == 2)
    }
}
