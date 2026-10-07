import SwiftSyntax

struct Normalization {
    let options: ScanOptions

    func validate() throws {
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
        let parts = tokens(node, stripSwift: false)
        let value = parts.joined()
        return parts.contains(".") ? value : "\(module(sourceModule)).\(value)"
    }

    func tokens(
        _ node: some SyntaxProtocol,
        generics: [String: String] = [:],
        stripSwift: Bool = true
    ) -> [String] {
        let tokens = node.tokens(viewMode: .sourceAccurate).map { token in
            let text = token.text
            return text.hasPrefix("`") && text.hasSuffix("`") ? String(text.dropFirst().dropLast()) : text
        }
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let isRoot = index == 0 || tokens[index - 1] != "."
            if isRoot, index + 1 < tokens.count, tokens[index + 1] == "." {
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
            result.append(isRoot ? generics[token] ?? token : token)
            index += 1
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
