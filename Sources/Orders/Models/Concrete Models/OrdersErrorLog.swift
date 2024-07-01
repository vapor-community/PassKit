//
//  OrdersErrorLog.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import struct Foundation.Date
import FluentKit
import PassKit

/// The `Model` that stores Wallet orders error logs.
final public class OrdersErrorLog: ErrorLogModel, @unchecked Sendable {
    public static let schema = OrdersErrorLog.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    @Timestamp(key: OrdersErrorLog.FieldKeys.createdAt, on: .create)
    public var createdAt: Date?

    @Field(key: OrdersErrorLog.FieldKeys.message)
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public init() {}
}

extension OrdersErrorLog: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(OrdersErrorLog.FieldKeys.createdAt, .datetime, .required)
            .field(OrdersErrorLog.FieldKeys.message, .string, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension OrdersErrorLog {
    enum FieldKeys {
        static let schemaName = "orders_errors"
        static let createdAt = FieldKey(stringLiteral: "created_at")
        static let message = FieldKey(stringLiteral: "message")
    }
}