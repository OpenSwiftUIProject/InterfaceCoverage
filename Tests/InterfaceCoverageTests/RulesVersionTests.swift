import Testing
@testable import InterfaceCoverage

/// Cached release reports are generated again only when `ScanOptions.currentRulesVersion`
/// increases. This snapshot fails when the normalized signatures change, so that a change to
/// the matching rules also increases the version.
struct RulesVersionTests {
    @Test func signaturesMatchTheRulesVersionSnapshot() throws {
        let source = """
import Swift
import OpenObservation
public protocol View { associatedtype Body : OpenSwiftUI.View; var body: Self.Body { get } }
public protocol Style { associatedtype Resolved }
extension OpenSwiftUI.Style where Self.Resolved == Swift.Never { public func resolve() -> Self.Resolved }
public struct Key : Swift.Sendable & Swift.Hashable {
  public typealias Value = Swift.Int?
  public static func reduce(value: inout OpenSwiftUI.Key.Value, nextValue: () -> OpenSwiftUI.Key.Value)
}
public struct Box<Content> where Content : OpenSwiftUI.View {
  public typealias Body = @_opaqueReturnTypeOf("$s11OpenSwiftUI3BoxV4bodyQrvp", 0) __<Content>
  public init(@OpenSwiftUI.ViewBuilder content: () -> Content)
  public func map<T>(_ transform: @escaping @Sendable (_ value: Content) throws -> T?, values: [Swift.String : [T]] = [:]) async rethrows -> OpenSwiftUI.Box<T>? where T : OpenSwiftUI.View
  public func apply(content: some OpenSwiftUI.View & Swift.Sendable, phase: Swift.Int) -> some OpenSwiftUI.View
  public func receive<S>(subscriber: __owned S) -> () where S : OpenObservation.Observable
  public subscript(index: Swift.Int) -> Content { get set }
  public var handler: (() -> ())? { get }
  public static func == (lhs: OpenSwiftUI.Box<Content>, rhs: OpenSwiftUI.Box<Content>) -> Swift.Bool
}
public enum Edge : Swift.Int { case top, bottom; case custom(name: Swift.String, value: Swift.Double = 0) }
@freestanding(expression) public macro Preview(_ name: Swift.String) -> Swift.Void = #externalMacro(module: "M", type: "P")
infix operator <> : AdditionPrecedence
"""
        let inventory = try InterfaceScanner().scan([InterfaceInput(path: "Fixture.swiftinterface", module: "OpenSwiftUI", source: source)])
        let signatures = inventory.entries.map { "\($0.kind.rawValue)|\($0.owner)|\($0.signature)" }.sorted()
        let snapshot = [
            "associatedtype|SwiftUI.Style|associatedtype Resolved",
            "associatedtype|SwiftUI.View|associatedtype Body : SwiftUI.View",
            "enumCase|SwiftUI.Edge|case bottom",
            "enumCase|SwiftUI.Edge|case custom(name: String, value: Double = default)",
            "enumCase|SwiftUI.Edge|case top",
            "enum|SwiftUI|enum Edge",
            "function|SwiftUI.Box|func apply<T1>(content: T1, phase: Int) -> some SwiftUI.View where T0: SwiftUI.View, T1: Sendable, T1: SwiftUI.View",
            "function|SwiftUI.Box|func map<T1>(_: @escaping @Sendable (T0) throws -> T1?, values: [String: [T1]] = default) async rethrows -> SwiftUI.Box<T1>? where T0: SwiftUI.View, T1: SwiftUI.View",
            "function|SwiftUI.Box|func receive<T1>(subscriber: T1) -> Void where T0: SwiftUI.View, T1: Observation.Observable",
            "function|SwiftUI.Box|static func ==(_: SwiftUI.Box<T0>, _: SwiftUI.Box<T0>) -> Bool where T0: SwiftUI.View",
            "function|SwiftUI.Key|static func reduce(value: inout Int?, nextValue: () -> Int?) -> Void",
            "function|SwiftUI.Style|func resolve() -> Never where Never == Self.Resolved",
            "inheritance|SwiftUI.Edge|inherits Int",
            "inheritance|SwiftUI.Key|inherits Sendable & Hashable",
            "initializer|SwiftUI.Box|init(@SwiftUI.ViewBuilder content: () -> T0) where T0: SwiftUI.View",
            "macro|SwiftUI|@freestanding(expression) macro Preview(_: String) -> Void",
            "operator|SwiftUI|infix operator <>: AdditionPrecedence",
            "protocol|SwiftUI|protocol Style",
            "protocol|SwiftUI|protocol View",
            "struct|SwiftUI|struct Box<T0> where T0: SwiftUI.View",
            "struct|SwiftUI|struct Key",
            "subscript|SwiftUI.Box|subscript(_: Int) -> T0 { get set } where T0: SwiftUI.View",
            "typealias|SwiftUI.Box|typealias Body = @_opaqueReturnTypeOf(_, 0) __<T0> where T0: SwiftUI.View",
            "typealias|SwiftUI.Key|typealias Value = Int?",
            "variable|SwiftUI.Box|var handler: (() -> Void)? { get } where T0: SwiftUI.View",
            "variable|SwiftUI.View|var body: Self.Body { get }",
        ]
        #expect(
            signatures == snapshot,
            "The normalized signatures changed. Increase ScanOptions.currentRulesVersion, then update this snapshot and the expected version."
        )
        #expect(ScanOptions.currentRulesVersion == 2, "Update this snapshot when the rules version changes.")
    }
}
