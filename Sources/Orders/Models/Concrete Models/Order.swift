//
//  Order.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import FluentKit
import Foundation

/// The `Model` that stores Wallet orders.
final public class Order: OrderModel, @unchecked Sendable {
    /// The schema name of the order model.
    public static let schema = Order.FieldKeys.schemaName

    /// A unique order identifier scoped to your order type identifier.
    ///
    /// In combination with the order type identifier, this uniquely identifies an order within the system and isn’t displayed to the user.
    @ID
    public var id: UUID?

    /// The date and time when the customer created the order.
    @Timestamp(key: Order.FieldKeys.createdAt, on: .create)
    public var createdAt: Date?

    /// The date and time when the order was last updated.
    @Timestamp(key: Order.FieldKeys.updatedAt, on: .update)
    public var updatedAt: Date?

    /// An identifier for the order type associated with the order.
    @Field(key: Order.FieldKeys.typeIdentifier)
    public var typeIdentifier: String

    /// The authentication token supplied to your web service.
    @Field(key: Order.FieldKeys.authenticationToken)
    public var authenticationToken: String

    public required init() {}

    public required init(typeIdentifier: String, authenticationToken: String) {
        self.typeIdentifier = typeIdentifier
        self.authenticationToken = authenticationToken
    }
}

extension Order: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field(Order.FieldKeys.createdAt, .datetime, .required)
            .field(Order.FieldKeys.updatedAt, .datetime, .required)
            .field(Order.FieldKeys.typeIdentifier, .string, .required)
            .field(Order.FieldKeys.authenticationToken, .string, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension Order {
    enum FieldKeys {
        static let schemaName = "orders"
        static let createdAt = FieldKey(stringLiteral: "created_at")
        static let updatedAt = FieldKey(stringLiteral: "updated_at")
        static let typeIdentifier = FieldKey(stringLiteral: "type_identifier")
        static let authenticationToken = FieldKey(stringLiteral: "authentication_token")
    }
}
