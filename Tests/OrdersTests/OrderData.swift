import Fluent
import Orders
import Vapor

import struct Foundation.UUID

final class OrderData: OrderDataModel, @unchecked Sendable {
    static let schema = OrderData.FieldKeys.schemaName

    @ID(key: .id)
    var id: UUID?

    @Field(key: OrderData.FieldKeys.title)
    var title: String

    @Parent(key: OrderData.FieldKeys.orderID)
    var order: Order

    init() {}

    init(id: UUID? = nil, title: String) {
        self.id = id
        self.title = title
    }
}

struct CreateOrderData: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OrderData.FieldKeys.schemaName)
            .id()
            .field(OrderData.FieldKeys.title, .string, .required)
            .field(OrderData.FieldKeys.orderID, .uuid, .required, .references(Order.schema, .id, onDelete: .cascade))
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OrderData.FieldKeys.schemaName).delete()
    }
}

extension OrderData {
    enum FieldKeys {
        static let schemaName = "order_data"
        static let title = FieldKey(stringLiteral: "title")
        static let orderID = FieldKey(stringLiteral: "order_id")
    }
}

struct OrderJSONData: OrderJSON.Properties {
    let schemaVersion = OrderJSON.SchemaVersion.v1
    let orderTypeIdentifier = "order.com.example.pet-store"
    let orderIdentifier: String
    let orderType = OrderJSON.OrderType.ecommerce
    let orderNumber = "HM090772020864"
    let createdAt: String
    let updatedAt: String
    let status = OrderJSON.OrderStatus.open
    let merchant: MerchantData
    let orderManagementURL = "https://www.example.com/"
    let authenticationToken: String

    private let webServiceURL = "https://www.example.com/api/orders/"

    struct MerchantData: OrderJSON.Merchant {
        let merchantIdentifier = "com.example.pet-store"
        let displayName: String
        let url = "https://www.example.com/"
        let logo = "pet_store_logo.png"
    }

    init(data: OrderData, order: Order) {
        self.orderIdentifier = order.id!.uuidString
        self.authenticationToken = order.authenticationToken
        self.merchant = MerchantData(displayName: data.title)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = .withInternetDateTime
        self.createdAt = dateFormatter.string(from: order.createdAt!)
        self.updatedAt = dateFormatter.string(from: order.updatedAt!)
    }
}

struct OrderDataMiddleware: AsyncModelMiddleware {
    private unowned let service: OrdersService

    init(service: OrdersService) {
        self.service = service
    }

    func create(model: OrderData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let order = Order(
            orderTypeIdentifier: "order.com.example.pet-store",
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString()
        )
        try await order.save(on: db)
        model.$order.id = try order.requireID()
        try await next.create(model, on: db)
    }

    func update(model: OrderData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let order = try await model.$order.get(on: db)
        order.updatedAt = Date()
        try await order.save(on: db)
        try await next.update(model, on: db)
        try await service.sendPushNotifications(for: order, on: db)
    }
}
