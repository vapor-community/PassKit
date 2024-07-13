//
//  PKPass.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 29/06/24.
//

import Foundation
import FluentKit

/// The `Model` that stores PassKit passes.
///
/// Uses a UUID so people can't easily guess pass serial numbers.
final public class PKPass: PassModel, @unchecked Sendable {
    public typealias UserPersonalizationType = UserPersonalization

    /// The schema name of the pass model.
    public static let schema = PKPass.FieldKeys.schemaName

    /// The pass alphanumeric serial number.
    ///
    /// The combination of the serial number and pass type identifier must be unique for each pass.
    /// Uses a UUID so people can't easily guess the pass serial number.
    @ID
    public var id: UUID?

    /// The last time the pass was modified.
    @Timestamp(key: PKPass.FieldKeys.updatedAt, on: .update)
    public var updatedAt: Date?

    /// The pass type identifier that’s registered with Apple.
    @Field(key: PKPass.FieldKeys.passTypeIdentifier)
    public var passTypeIdentifier: String

    /// The authentication token to use with the web service in the `webServiceURL` key.
    @Field(key: PKPass.FieldKeys.authenticationToken)
    public var authenticationToken: String

    /// The user personalization info.
    @OptionalParent(key: PKPass.FieldKeys.userPersonalizationID)
    public var userPersonalization: UserPersonalizationType?
    
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
            .field(PKPass.FieldKeys.userPersonalizationID, .int, .references(UserPersonalizationType.schema, .id))
            .unique(on: PKPass.FieldKeys.userPersonalizationID)
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
        static let userPersonalizationID = FieldKey(stringLiteral: "user_personalization_id")
    }
}
