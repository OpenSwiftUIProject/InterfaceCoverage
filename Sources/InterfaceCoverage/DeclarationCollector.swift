import SwiftSyntax

final class DeclarationCollector {
    let normalization: Normalization
    var types: [String: DeclarationContext] = [:]
    var entries: [String: APIEntry] = [:]
    var input: InterfaceInput
    var converter: SourceLocationConverter
    var indexOnly = true
    var indexExtensions = false

    init(options: ScanOptions, input: InterfaceInput, tree: SourceFileSyntax) {
        normalization = Normalization(options: options)
        self.input = input
        converter = SourceLocationConverter(fileName: input.path, tree: tree)
    }

    func collect(_ declarations: [DeclSyntax], context: DeclarationContext) throws {
        for declaration in declarations {
            if let nominal = NominalDeclaration(declaration) {
                try collect(nominal, node: declaration, parent: context)
            } else if let node = declaration.as(ExtensionDeclSyntax.self) {
                if !indexOnly || indexExtensions { try collect(node, parent: context) }
            } else if let node = declaration.as(IfConfigDeclSyntax.self) {
                for clause in node.clauses {
                    switch clause.elements {
                    case .decls(let members):
                        try collect(members.map(\.decl), context: context)
                    case .statements(let statements):
                        try collect(statements.compactMap { $0.item.as(DeclSyntax.self) }, context: context)
                    default:
                        break
                    }
                }
            } else if !indexOnly && context.visible {
                try collectMember(declaration, context: context)
            }
        }
    }

    private func collect(_ nominal: NominalDeclaration, node: DeclSyntax, parent: DeclarationContext) throws {
        let name = normalization.text(nominal.name)
        var context = parent
        context.owner += "." + name
        context.visible = visible(nominal.modifiers, nominal.attributes, name: name, context: parent)
        context.implicitPublic = nominal.kind == .protocol
        context.isEnum = nominal.kind == .enum
        let ignoredNamespace = normalization.options.ignoredNamespaces.contains(name)
        if ignoredNamespace && context.visible && nominal.parameters != nil {
            throw failure("Cannot ignore generic namespace '\(name)'", node: node)
        }
        let parameters = context.add(nominal.parameters)
        context.requirements += normalization.requirements(nominal.requirements, parameters: nominal.parameters, generics: context.generics)
        if indexOnly {
            types[context.owner] = context
        } else if context.visible {
            if !ignoredNamespace {
                let primaryTypes = normalization.text(nominal.primaryAssociatedTypes)
                add(nominal.kind, name: name,
                    signature: "\(nominal.kind.rawValue) \(name)\(parameters)\(primaryTypes)",
                    context: context, owner: parent.owner, node: node)
            }
            inherit(nominal.inheritance, context: context)
        }
        try collect(nominal.members.members.map(\.decl), context: context)
    }

    private func collect(_ node: ExtensionDeclSyntax, parent: DeclarationContext) throws {
        let owner = normalization.owner(node.extendedType, module: input.module)
        var context = types[owner] ?? DeclarationContext(owner: owner)
        context.visible = parent.visible && context.visible
            && attributesVisible(node.attributes) && nameVisible(owner)
            && !node.modifiers.contains { ["private", "fileprivate", "internal", "package"].contains($0.name.text) }
        context.implicitPublic = node.modifiers.contains { ["public", "open"].contains($0.name.text) }
        context.isEnum = false
        context.requirements += normalization.requirements(node.genericWhereClause, generics: context.generics)
        if !indexOnly && context.visible { inherit(node.inheritanceClause, context: context) }
        try collect(node.memberBlock.members.map(\.decl), context: context)
    }

    private func collectMember(_ declaration: DeclSyntax, context: DeclarationContext) throws {
        if let node = declaration.as(FunctionDeclSyntax.self) {
            let name = normalization.text(node.name)
            guard visible(node.modifiers, node.attributes, name: name, context: context) else { return }
            let (scope, generics, clause) = genericScope(context, node.genericParameterClause, node.genericWhereClause, node.signature.parameterClause)
            let isOperator: Bool
            switch node.name.tokenKind {
            case .binaryOperator, .prefixOperator, .postfixOperator:
                isOperator = true
            default:
                isOperator = false
            }
            add(.function, name: name,
                signature: "\(modifiers(node.modifiers))func \(name)\(generics)\(function(node.signature.with(\.parameterClause, clause), context: scope, implicitUnlabeled: isOperator))",
                context: scope, node: node)
        } else if let node = declaration.as(InitializerDeclSyntax.self) {
            guard visible(node.modifiers, node.attributes, name: "init", context: context) else { return }
            let (scope, generics, clause) = genericScope(context, node.genericParameterClause, node.genericWhereClause, node.signature.parameterClause)
            add(.initializer, name: "init",
                signature: "init\(node.optionalMark?.text ?? "")\(generics)\(function(node.signature.with(\.parameterClause, clause), context: scope, hasReturn: false))",
                context: scope, node: node)
        } else if let node = declaration.as(VariableDeclSyntax.self) {
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier else {
                    throw failure("Unsupported property pattern", node: binding)
                }
                let identifier = normalization.text(name)
                guard visible(node.modifiers, node.attributes, name: identifier, context: context) else { continue }
                guard let type = binding.typeAnnotation?.type else {
                    throw failure("Interface property has no explicit type", node: binding)
                }
                let accessors = accessors(binding.accessorBlock, storedMutable: node.bindingSpecifier.text == "var", modifiers: node.modifiers, context: context)
                add(.variable, name: identifier,
                    signature: "\(modifiers(node.modifiers))var \(identifier): \(normalization.type(type, generics: context.generics)) \(accessors)",
                    context: context, node: binding)
            }
        } else if let node = declaration.as(SubscriptDeclSyntax.self) {
            guard visible(node.modifiers, node.attributes, name: "subscript", context: context) else { return }
            let (scope, generics, clause) = genericScope(context, node.genericParameterClause, node.genericWhereClause, node.parameterClause)
            let type = normalization.type(node.returnClause.type, generics: scope.generics)
            add(.subscript, name: "subscript",
                signature: "\(modifiers(node.modifiers))subscript\(generics)\(parameters(clause, context: scope, implicitUnlabeled: true)) -> \(type) \(accessors(node.accessorBlock, modifiers: node.modifiers, context: scope))",
                context: scope, node: node)
        } else if let node = declaration.as(TypeAliasDeclSyntax.self) {
            let name = normalization.text(node.name)
            guard visible(node.modifiers, node.attributes, name: name, context: context) else { return }
            var scope = context
            let generics = scope.add(node.genericParameterClause)
            scope.requirements += normalization.requirements(node.genericWhereClause, parameters: node.genericParameterClause, generics: scope.generics)
            add(.typealias, name: name,
                signature: "typealias \(name)\(generics) = \(normalization.type(node.initializer.value, generics: scope.generics))",
                context: scope, node: node)
        } else if let node = declaration.as(AssociatedTypeDeclSyntax.self) {
            let name = normalization.text(node.name)
            guard visible(node.modifiers, node.attributes, name: name, context: context) else { return }
            var scope = context
            scope.requirements += normalization.requirements(node.genericWhereClause, generics: scope.generics)
            let inheritance = normalization.text(node.inheritanceClause, generics: scope.generics)
            let value = normalization.text(node.initializer, generics: scope.generics)
            add(.associatedtype, name: name, signature: ["associatedtype", name, inheritance, value].filter { !$0.isEmpty }.joined(separator: " "), context: scope, node: node)
        } else if let node = declaration.as(EnumCaseDeclSyntax.self) {
            guard context.isEnum && attributesVisible(node.attributes) else { return }
            for element in node.elements {
                let name = normalization.text(element.name)
                guard nameVisible(name) else { continue }
                let values = element.parameterClause?.parameters.map { parameter in
                    let label = parameter.firstName.map { normalization.text($0) } ?? "_"
                    let type = normalization.type(parameter.type, generics: context.generics)
                    return "\(label): \(type)" + (parameter.defaultValue == nil ? "" : " = default")
                }
                let parameters = values.map { "(\($0.joined(separator: ", ")))" } ?? ""
                add(.enumCase, name: name, signature: "case \(name)\(parameters)", context: context, node: element)
            }
        } else if let node = declaration.as(MacroDeclSyntax.self) {
            let name = normalization.text(node.name)
            guard visible(node.modifiers, node.attributes, name: name, context: context) else { return }
            var scope = context
            let generics = scope.add(node.genericParameterClause)
            scope.requirements += normalization.requirements(node.genericWhereClause, parameters: node.genericParameterClause, generics: scope.generics)
            let roles = node.attributes.compactMap { element -> String? in
                guard let attribute = element.as(AttributeSyntax.self),
                      ["attached", "freestanding"].contains(attribute.attributeName.trimmedDescription) else { return nil }
                return normalization.text(attribute, generics: scope.generics)
            }.sorted().joined(separator: " ")
            add(.macro, name: name, signature: "\(roles) macro \(name)\(generics)\(function(node.signature, context: scope))", context: scope, node: node)
        } else if let node = declaration.as(OperatorDeclSyntax.self) {
            add(.operator, name: normalization.text(node.name), signature: normalization.text(node), context: context, node: node)
        } else if let node = declaration.as(PrecedenceGroupDeclSyntax.self) {
            guard nameVisible(normalization.text(node.name)) else { return }
            add(.precedenceGroup, name: normalization.text(node.name), signature: normalization.text(node), context: context, node: node)
        } else if declaration.is(ImportDeclSyntax.self) || declaration.is(DeinitializerDeclSyntax.self)
            || declaration.is(PoundSourceLocationSyntax.self) {
            return
        } else {
            throw failure("Unsupported interface declaration: \(declaration.kind)", node: declaration)
        }
    }

    private func genericScope(
        _ context: DeclarationContext, _ parameters: GenericParameterClauseSyntax?,
        _ requirements: GenericWhereClauseSyntax?, _ clause: FunctionParameterClauseSyntax
    ) -> (DeclarationContext, String, FunctionParameterClauseSyntax) {
        var scope = context
        let (clause, opaque) = normalization.opaqueParameters(clause)
        let generics = scope.add(parameters, opaque: opaque)
        scope.requirements += normalization.requirements(requirements, parameters: parameters, generics: scope.generics)
        for parameter in opaque {
            scope.requirements += normalization.conformances(scope.generics[parameter.name] ?? parameter.name, parameter.constraint, generics: scope.generics)
        }
        return (scope, generics, clause)
    }

    private func function(
        _ signature: FunctionSignatureSyntax, context: DeclarationContext,
        hasReturn: Bool = true, implicitUnlabeled: Bool = false
    ) -> String {
        var result = parameters(signature.parameterClause, context: context, implicitUnlabeled: implicitUnlabeled)
        let effects = normalization.text(signature.effectSpecifiers, generics: context.generics)
        if !effects.isEmpty { result += " " + effects }
        if hasReturn { result += " -> " + normalization.type(signature.returnClause?.type, generics: context.generics) }
        return result
    }

    private func parameters(
        _ clause: FunctionParameterClauseSyntax, context: DeclarationContext,
        implicitUnlabeled: Bool = false
    ) -> String {
        let parameters = clause.parameters.map { parameter in
            let attributes = normalization.text(parameter.attributes, generics: context.generics)
            let modifiers = normalization.text(parameter.modifiers, generics: context.generics)
            let label = implicitUnlabeled && parameter.secondName == nil ? "_" : normalization.text(parameter.firstName)
            let type = normalization.type(parameter.type, generics: context.generics)
            let prefix = [attributes, modifiers].filter { !$0.isEmpty }.joined(separator: " ")
            return (prefix.isEmpty ? "" : prefix + " ") + "\(label): \(type)"
                + (parameter.ellipsis?.text ?? "") + (parameter.defaultValue == nil ? "" : " = default")
        }
        return "(\(parameters.joined(separator: ", ")))"
    }

    private func modifiers(_ modifiers: DeclModifierListSyntax) -> String {
        let words = modifiers.map(\.name.text).filter {
            ["static", "class", "mutating", "nonmutating", "consuming", "borrowing", "distributed", "prefix", "postfix"].contains($0)
        }.sorted()
        return words.isEmpty ? "" : words.joined(separator: " ") + " "
    }

    private func accessors(
        _ block: AccessorBlockSyntax?, storedMutable: Bool = false,
        modifiers: DeclModifierListSyntax, context: DeclarationContext
    ) -> String {
        var getter = "get"
        var hasSetter = block == nil && storedMutable
        if case .accessors(let accessors) = block?.accessors {
            for accessor in accessors {
                switch accessor.accessorSpecifier.text {
                case "get", "_read":
                    let effects = normalization.text(accessor.effectSpecifiers, generics: context.generics)
                    getter = "get" + (effects.isEmpty ? "" : " " + effects)
                case "set", "_modify", "willSet", "didSet":
                    hasSetter = true
                default:
                    break
                }
            }
        }
        if modifiers.contains(where: { $0.detail?.detail.text == "set" && !["public", "open"].contains($0.name.text) }) {
            hasSetter = false
        }
        return "{ \(getter)\(hasSetter ? " set" : "") }"
    }

    private func inherit(_ clause: InheritanceClauseSyntax?, context: DeclarationContext) {
        for inherited in clause?.inheritedTypes ?? [] {
            let name = normalization.text(inherited.type, generics: context.generics)
            add(.inheritance, name: name, signature: "inherits \(name)", context: context, node: inherited)
        }
    }

    private func visible(_ modifiers: DeclModifierListSyntax, _ attributes: AttributeListSyntax, name: String, context: DeclarationContext) -> Bool {
        guard context.visible && nameVisible(name) && attributesVisible(attributes) else { return false }
        let access = modifiers.filter { $0.detail == nil }.map(\.name.text)
        if access.contains(where: { ["private", "fileprivate", "internal", "package"].contains($0) }) { return false }
        return context.implicitPublic || access.contains("public") || access.contains("open")
    }

    private func nameVisible(_ name: String) -> Bool {
        !normalization.options.excludeUnderscored || !name.split(separator: ".").contains { $0.hasPrefix("_") }
    }

    private func attributesVisible(_ attributes: AttributeListSyntax) -> Bool {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let name = attribute.attributeName.trimmedDescription
            if name == "_spi" && !normalization.options.includeSPI { return false }
            if name == "available", let arguments = attribute.arguments {
                let words = arguments.tokens(viewMode: .sourceAccurate).map(\.text)
                if words.contains("unavailable"), let platform = words.first,
                   platform == "*" || platform.lowercased() == normalization.options.platform?.lowercased() {
                    return false
                }
            }
        }
        return true
    }

    private func add(
        _ kind: APIKind, name: String, signature: String, context: DeclarationContext,
        owner: String? = nil, node: some SyntaxProtocol
    ) {
        let position = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let location = SourceLocation(path: input.path, line: position.line)
        // Keep original owners in the type index so flattened scopes cannot replace
        // each other's generic parameters. Normalize only the emitted inventory.
        let entry = APIEntry(kind: kind, owner: normalization.normalizedOwner(owner ?? context.owner), name: name,
                             signature: context.constrained(signature), locations: [location])
        if var existing = entries[entry.id] {
            if !existing.locations.contains(location) { existing.locations.append(location) }
            entries[entry.id] = existing
        } else {
            entries[entry.id] = entry
        }
    }

    private func failure(_ message: String, node: some SyntaxProtocol) -> CoverageError {
        let position = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return CoverageError("\(input.path):\(position.line): \(message)")
    }
}
