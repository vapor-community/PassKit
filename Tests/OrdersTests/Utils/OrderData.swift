import Fluent
import Foundation
import Orders

final class OrderData: OrderDataModel, @unchecked Sendable {
    static let schema = OrderData.FieldKeys.schemaName

    static let typeIdentifier = "order.com.example.pet-store"

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

extension OrderData {
    func orderJSON(on db: any Database) async throws -> any OrderJSON.Properties {
        try await OrderJSONData(data: self, order: self.$order.get(on: db))
    }

    func template(on db: any Database) async throws -> String {
        "\(FileManager.default.currentDirectoryPath)/Tests/OrdersTests/Templates/"
    }
}
