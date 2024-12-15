import FluentKit
import PassKit

import struct Foundation.Date

/// The `Model` that stores Apple Wallet passes error logs.
final public class PassesErrorLog: ErrorLogModel, @unchecked Sendable {
    /// The schema name of the error log model.
    public static let schema = PassesErrorLog.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    /// The date and time the error log was created.
    @Timestamp(key: PassesErrorLog.FieldKeys.createdAt, on: .create)
    public var createdAt: Date?

    /// The error message provided by Apple Wallet.
    @Field(key: PassesErrorLog.FieldKeys.message)
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public init() {}
}

extension PassesErrorLog: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(PassesErrorLog.FieldKeys.createdAt, .datetime, .required)
            .field(PassesErrorLog.FieldKeys.message, .string, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension PassesErrorLog {
    enum FieldKeys {
        static let schemaName = "passes_errors"
        static let createdAt = FieldKey(stringLiteral: "created_at")
        static let message = FieldKey(stringLiteral: "message")
    }
}
