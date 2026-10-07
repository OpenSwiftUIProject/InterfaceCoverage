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
        var result = clause?.requirements.map { requirement -> String in
            let value = text(requirement.requirement, generics: generics)
            if let sameType = requirement.requirement.as(SameTypeRequirementSyntax.self) {
                return [text(sameType.leftType, generics: generics), text(sameType.rightType, generics: generics)]
                    .sorted().joined(separator: " == ")
            }
            return value
        } ?? []
        for parameter in parameters?.parameters ?? [] {
            if let inherited = parameter.inheritedType {
                result.append("\(generics[parameter.name.text] ?? parameter.name.text) : \(text(inherited, generics: generics))")
            }
        }
        return result
    }
}

struct DeclarationContext {
    var owner: String
    var generics: [String: String] = [:]
    var requirements: [String] = []
    var visible = true
    var implicitPublic = false
    var isEnum = false

    mutating func add(_ parameters: GenericParameterClauseSyntax?) -> String {
        var names: [String] = []
        let start = Set(generics.values).count
        for (index, parameter) in (parameters?.parameters ?? []).enumerated() {
            let name = "T\(start + index)"
            generics[parameter.name.text] = name
            names.append((parameter.specifier.map { $0.text + " " } ?? "") + name)
        }
        return names.isEmpty ? "" : "<\(names.joined(separator: ", "))>"
    }

    func constrained(_ signature: String) -> String {
        let requirements = Set(requirements).sorted()
        return requirements.isEmpty ? signature : "\(signature) where \(requirements.joined(separator: ", "))"
    }
}
