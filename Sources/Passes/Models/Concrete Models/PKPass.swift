//
//  PKPass.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 29/06/24.
//

import Foundation
import FluentKit

/// The `Model` that stores PassKit passes.
open class PKPass: PassModel, @unchecked Sendable {
    public static let schema = PKPass.FieldKeys.schemaName

    @ID
    public var id: UUID?

    @Timestamp(key: PKPass.FieldKeys.updatedAt, on: .update)
    public var updatedAt: Date?

    @Field(key: PKPass.FieldKeys.passTypeIdentifier)
    public var passTypeIdentifier: String

    @Field(key: PKPass.FieldKeys.authenticationToken)
    public var authenticationToken: String
    
    public required init() { }

    public required init(passTypeIdentifier: String, authenticationToken: String) {
        self.passTypeIdentifier = passTypeIdentifier
        self.authenticationToken = authenticationToken
    }
}

extension PKPass: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field(PKPass.FieldKeys.updatedAt, .datetime, .required)
            .field(PKPass.FieldKeys.passTypeIdentifier, .string, .required)
            .field(PKPass.FieldKeys.authenticationToken, .string, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension PKPass {
    enum FieldKeys {
        static let schemaName = "passes"
        static let updatedAt = FieldKey(stringLiteral: "updated_at")
        static let passTypeIdentifier = FieldKey(stringLiteral: "pass_type_identifier")
        static let authenticationToken = FieldKey(stringLiteral: "authentication_token")
    }
}
