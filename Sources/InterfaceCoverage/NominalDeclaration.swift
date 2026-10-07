import SwiftSyntax

struct NominalDeclaration {
    let kind: APIKind
    let name: TokenSyntax
    let attributes: AttributeListSyntax
    let modifiers: DeclModifierListSyntax
    let parameters: GenericParameterClauseSyntax?
    let requirements: GenericWhereClauseSyntax?
    let inheritance: InheritanceClauseSyntax?
    let members: MemberBlockSyntax
    var primaryAssociatedTypes: PrimaryAssociatedTypeClauseSyntax?

    init?(_ declaration: DeclSyntax) {
        switch declaration.asProtocol(DeclSyntaxProtocol.self) {
        case let node as StructDeclSyntax:
            self.init(kind: .struct, name: node.name, attributes: node.attributes, modifiers: node.modifiers, parameters: node.genericParameterClause, requirements: node.genericWhereClause, inheritance: node.inheritanceClause, members: node.memberBlock)
        case let node as EnumDeclSyntax:
            self.init(kind: .enum, name: node.name, attributes: node.attributes, modifiers: node.modifiers, parameters: node.genericParameterClause, requirements: node.genericWhereClause, inheritance: node.inheritanceClause, members: node.memberBlock)
        case let node as ClassDeclSyntax:
            self.init(kind: .class, name: node.name, attributes: node.attributes, modifiers: node.modifiers, parameters: node.genericParameterClause, requirements: node.genericWhereClause, inheritance: node.inheritanceClause, members: node.memberBlock)
        case let node as ActorDeclSyntax:
            self.init(kind: .actor, name: node.name, attributes: node.attributes, modifiers: node.modifiers, parameters: node.genericParameterClause, requirements: node.genericWhereClause, inheritance: node.inheritanceClause, members: node.memberBlock)
        case let node as ProtocolDeclSyntax:
            self.init(kind: .protocol, name: node.name, attributes: node.attributes, modifiers: node.modifiers, parameters: nil, requirements: node.genericWhereClause, inheritance: node.inheritanceClause, members: node.memberBlock, primaryAssociatedTypes: node.primaryAssociatedTypeClause)
        default:
            return nil
        }
    }

    private init(
        kind: APIKind, name: TokenSyntax, attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax, parameters: GenericParameterClauseSyntax?,
        requirements: GenericWhereClauseSyntax?, inheritance: InheritanceClauseSyntax?,
        members: MemberBlockSyntax, primaryAssociatedTypes: PrimaryAssociatedTypeClauseSyntax? = nil
    ) {
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.modifiers = modifiers
        self.parameters = parameters
        self.requirements = requirements
        self.inheritance = inheritance
        self.members = members
        self.primaryAssociatedTypes = primaryAssociatedTypes
    }
}
