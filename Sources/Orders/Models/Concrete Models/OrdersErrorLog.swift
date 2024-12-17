import FluentKit
import PassKit

import struct Foundation.Date

/// The `Model` that stores Wallet orders error logs.
final public class OrdersErrorLog: ErrorLogModel, @unchecked Sendable {
    /// The schema name of the error log model.
    public static let schema = OrdersErrorLog.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    /// The date and time the error log was created.
    @Timestamp(key: OrdersErrorLog.FieldKeys.createdAt, on: .create)
    public var createdAt: Date?

    /// The error message provided by Apple Wallet.
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
