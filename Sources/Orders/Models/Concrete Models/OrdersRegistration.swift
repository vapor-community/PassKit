import FluentKit

/// The `Model` that stores orders registrations.
final public class OrdersRegistration: OrdersRegistrationModel, @unchecked Sendable {
    public typealias OrderType = Order
    public typealias DeviceType = OrdersDevice

    /// The schema name of the orders registration model.
    public static let schema = OrdersRegistration.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    /// The device for this registration.
    @Parent(key: OrdersRegistration.FieldKeys.deviceID)
    public var device: DeviceType

    /// The order for this registration.
    @Parent(key: OrdersRegistration.FieldKeys.orderID)
    public var order: OrderType

    public init() {}
}

extension OrdersRegistration: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(
                OrdersRegistration.FieldKeys.deviceID, .int, .required,
                .references(DeviceType.schema, .id, onDelete: .cascade)
            )
            .field(
                OrdersRegistration.FieldKeys.orderID, .uuid, .required,
                .references(OrderType.schema, .id, onDelete: .cascade)
            )
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension OrdersRegistration {
    enum FieldKeys {
        static let schemaName = "orders_registrations"
        static let deviceID = FieldKey(stringLiteral: "device_id")
        static let orderID = FieldKey(stringLiteral: "order_id")
    }
}
