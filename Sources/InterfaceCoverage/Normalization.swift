import SwiftSyntax

struct Normalization {
    let options: ScanOptions

    private struct TokenSpelling {
        let text: String
        var isModule = false
    }

    func validate() throws {
        for name in options.ignoredNamespaces {
            guard let first = name.first, first.isLetter || first == "_",
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                throw CoverageError("Invalid namespace '\(name)'. Use one identifier, such as Wrapper.")
            }
        }
        for key in options.moduleAliases.keys {
            var visited: Set<String> = []
            var current = key
            while let next = options.moduleAliases[current], next != current {
                guard visited.insert(current).inserted else {
                    throw CoverageError("Module aliases contain a cycle at \(current)")
                }
                current = next
            }
        }
    }

    func module(_ name: String) -> String {
        var name = name
        while let next = options.moduleAliases[name], next != name { name = next }
        return name
    }

    func text(_ node: (some SyntaxProtocol)?, generics: [String: String] = [:]) -> String {
        guard let node else { return "" }
        return tokens(node, generics: generics).joined(separator: " ")
    }

    func type(_ node: (some SyntaxProtocol)?, generics: [String: String]) -> String {
        let value = text(node, generics: generics)
        return value == "( )" || value.isEmpty ? "Void" : value
    }

    func owner(_ node: some SyntaxProtocol, module sourceModule: String) -> String {
        let parts = tokens(node, stripSwift: false, normalizeNamespaces: false)
        let value = parts.joined()
        return parts.contains(".") ? value : "\(module(sourceModule)).\(value)"
    }

    func normalizedOwner(_ owner: String) -> String {
        let parts = owner.split(separator: ".").map(String.init)
        return parts.enumerated().compactMap { index, part in
            index > 0 && options.ignoredNamespaces.contains(part) ? nil : part
        }.joined(separator: ".")
    }

    func tokens(
        _ node: some SyntaxProtocol,
        generics: [String: String] = [:],
        stripSwift: Bool = true,
        normalizeNamespaces: Bool = true
    ) -> [String] {
        let sourceTokens = node.tokens(viewMode: .sourceAccurate).compactMap { token -> TokenSpelling? in
            let raw = token.text
            // `__owned` and `__shared` spell the default parameter conventions.
            if ["__owned", "__shared"].contains(raw), token.parent?.is(SimpleTypeSpecifierSyntax.self) == true {
                return nil
            }
            if let literal = opaqueReturnTypeName(containing: token) {
                // The mangled name includes the module name. The owner and the
                // ordinal already identify the opaque type.
                return token.id == literal.openingQuote.id ? TokenSpelling(text: "_") : nil
            }
            let text = raw.hasPrefix("`") && raw.hasSuffix("`") ? String(raw.dropFirst().dropLast()) : raw
            if let selector = token.parent?.as(ModuleSelectorSyntax.self) {
                // Member selectors encode the declaring module, not another type-path component.
                // Legacy interfaces do not carry this disambiguation information.
                if selector.parent?.is(MemberTypeSyntax.self) == true ||
                    (selector.parent?.is(DeclReferenceExprSyntax.self) == true &&
                     selector.parent?.parent?.is(MemberAccessExprSyntax.self) == true) {
                    return nil
                }
                if token.tokenKind == .colonColon { return TokenSpelling(text: ".") }
                return TokenSpelling(text: text, isModule: true)
            }
            return TokenSpelling(text: text)
        }
        let tokens = normalizeNamespaces ? removingNamespaces(from: sourceTokens) : sourceTokens
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index].text
            let isRoot = index == 0 || tokens[index - 1].text != "."
            if isRoot, index + 1 < tokens.count, tokens[index + 1].text == "." {
                if stripSwift && token == "Swift" {
                    index += 2
                    continue
                }
                if options.moduleAliases[token] != nil {
                    result.append(module(token))
                    index += 1
                    continue
                }
            }
            result.append(isRoot && !tokens[index].isModule ? generics[token] ?? token : token)
            index += 1
        }
        return result
    }

    private func opaqueReturnTypeName(containing token: TokenSyntax) -> StringLiteralExprSyntax? {
        guard token.parent?.is(StringLiteralExprSyntax.self) == true || token.parent?.is(StringSegmentSyntax.self) == true,
              let literal = token.ancestorOrSelf(mapping: { $0.as(StringLiteralExprSyntax.self) }),
              let attribute = literal.ancestorOrSelf(mapping: { $0.as(AttributeSyntax.self) }),
              attribute.attributeName.trimmedDescription == "_opaqueReturnTypeOf" else { return nil }
        return literal
    }

    private func removingNamespaces(from tokens: [TokenSpelling]) -> [TokenSpelling] {
        guard !options.ignoredNamespaces.isEmpty else { return tokens }
        var result: [TokenSpelling] = []
        var index = 0
        while index < tokens.count {
            if index > 0, tokens[index].text == ".", index + 1 < tokens.count,
               options.ignoredNamespaces.contains(tokens[index + 1].text),
               index + 2 == tokens.count || tokens[index + 2].text != "<" {
                index += 2
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    func requirements(
        _ clause: GenericWhereClauseSyntax?,
        parameters: GenericParameterClauseSyntax? = nil,
        generics: [String: String]
    ) -> [String] {
        var result = clause?.requirements.flatMap { requirement -> [String] in
            if let sameType = requirement.requirement.as(SameTypeRequirementSyntax.self) {
                return [[text(sameType.leftType, generics: generics), text(sameType.rightType, generics: generics)]
                    .sorted().joined(separator: " == ")]
            }
            if let conformance = requirement.requirement.as(ConformanceRequirementSyntax.self) {
                return conformances(text(conformance.leftType, generics: generics), conformance.rightType, generics: generics)
            }
            return [text(requirement.requirement, generics: generics)]
        } ?? []
        for parameter in parameters?.parameters ?? [] {
            if let inherited = parameter.inheritedType {
                result += conformances(generics[parameter.name.text] ?? parameter.name.text, inherited, generics: generics)
            }
        }
        return result
    }

    /// Splits `T: P & Q` into `T: P` and `T: Q`, which have the same meaning.
    func conformances(_ subject: String, _ type: TypeSyntax, generics: [String: String]) -> [String] {
        let types = type.as(CompositionTypeSyntax.self)?.elements.map(\.type) ?? [type]
        return types.map { "\(subject) : \(text($0, generics: generics))" }
    }

    /// Replaces each opaque parameter type (`some P`) with a placeholder
    /// generic parameter. The compiler adds these after the declared ones.
    func opaqueParameters(_ clause: FunctionParameterClauseSyntax) -> (FunctionParameterClauseSyntax, [OpaqueParameter]) {
        let rewriter = OpaqueParameterRewriter()
        let result = rewriter.rewrite(clause).cast(FunctionParameterClauseSyntax.self)
        return (result, rewriter.parameters)
    }
}

struct DeclarationContext {
    var owner: String
    var generics: [String: String] = [:]
    var requirements: [String] = []
    var visible = true
    var implicitPublic = false
    var isEnum = false

    mutating func add(_ parameters: GenericParameterClauseSyntax?, opaque: [OpaqueParameter] = []) -> String {
        var names: [String] = []
        let start = Set(generics.values).count
        let declared = (parameters?.parameters ?? []).map { ($0.name.text, $0.specifier.map { $0.text + " " } ?? "") }
        for (index, (parameter, specifier)) in (declared + opaque.map { ($0.name, "") }).enumerated() {
            let name = "T\(start + index)"
            generics[parameter] = name
            names.append(specifier + name)
        }
        return names.isEmpty ? "" : "<\(names.joined(separator: ", "))>"
    }

    func constrained(_ signature: String) -> String {
        let requirements = Set(requirements).sorted()
        return requirements.isEmpty ? signature : "\(signature) where \(requirements.joined(separator: ", "))"
    }
}

struct OpaqueParameter {
    let name: String
    let constraint: TypeSyntax
}

private final class OpaqueParameterRewriter: SyntaxRewriter {
    var parameters: [OpaqueParameter] = []

    override func visit(_ node: SomeOrAnyTypeSyntax) -> TypeSyntax {
        guard node.someOrAnySpecifier.tokenKind == .keyword(.some) else { return super.visit(node) }
        let name = "__opaque\(parameters.count)"
        parameters.append(OpaqueParameter(name: name, constraint: node.constraint))
        return TypeSyntax(IdentifierTypeSyntax(name: .identifier(name)))
    }
}
