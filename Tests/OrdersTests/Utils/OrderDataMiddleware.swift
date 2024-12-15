import Fluent
import Foundation
import Orders

struct OrderDataMiddleware: AsyncModelMiddleware {
    private unowned let service: OrdersService<OrderData>

    init(service: OrdersService<OrderData>) {
        self.service = service
    }

    func create(model: OrderData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let order = Order(
            typeIdentifier: OrderData.typeIdentifier,
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
        try await service.sendPushNotifications(for: model, on: db)
    }
}
