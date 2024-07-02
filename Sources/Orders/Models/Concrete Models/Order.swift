//
//  Order.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import Foundation
import FluentKit

/// The `Model` that stores Wallet orders.
open class Order: OrderModel, @unchecked Sendable {
    public static let schema = Order.FieldKeys.schemaName

    @ID
    public var id: UUID?

    @Timestamp(key: Order.FieldKeys.updatedAt, on: .update)
    public var updatedAt: Date?

    @Field(key: Order.FieldKeys.orderTypeIdentifier)
    public var orderTypeIdentifier: String

    @Field(key: Order.FieldKeys.authenticationToken)
    public var authenticationToken: String

    public required init() { }

    public required init(orderTypeIdentifier: String, authenticationToken: String) {
        self.orderTypeIdentifier = orderTypeIdentifier
        self.authenticationToken = authenticationToken
    }
}

extension Order: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field(Order.FieldKeys.updatedAt, .datetime, .required)
            .field(Order.FieldKeys.orderTypeIdentifier, .string, .required)
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
        static let updatedAt = FieldKey(stringLiteral: "updated_at")
        static let orderTypeIdentifier = FieldKey(stringLiteral: "order_type_identifier")
        static let authenticationToken = FieldKey(stringLiteral: "authentication_token")
    }
}
