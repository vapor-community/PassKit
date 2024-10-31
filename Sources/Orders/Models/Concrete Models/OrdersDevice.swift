//
//  OrdersDevice.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import FluentKit
import PassKit

/// The `Model` that stores Wallet orders devices.
final public class OrdersDevice: DeviceModel, @unchecked Sendable {
    /// The schema name of the orders device model.
    public static let schema = OrdersDevice.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    /// The push token used for sending updates to the device.
    @Field(key: OrdersDevice.FieldKeys.pushToken)
    public var pushToken: String

    /// The identifier Apple Wallet provides for the device.
    @Field(key: OrdersDevice.FieldKeys.libraryIdentifier)
    public var libraryIdentifier: String

    public init(libraryIdentifier: String, pushToken: String) {
        self.libraryIdentifier = libraryIdentifier
        self.pushToken = pushToken
    }

    public init() {}
}

extension OrdersDevice: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(OrdersDevice.FieldKeys.pushToken, .string, .required)
            .field(OrdersDevice.FieldKeys.libraryIdentifier, .string, .required)
            .unique(on: OrdersDevice.FieldKeys.pushToken, OrdersDevice.FieldKeys.libraryIdentifier)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension OrdersDevice {
    enum FieldKeys {
        static let schemaName = "orders_devices"
        static let pushToken = FieldKey(stringLiteral: "push_token")
        static let libraryIdentifier = FieldKey(stringLiteral: "library_identifier")
    }
}
