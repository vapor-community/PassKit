import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Orders

final class OrdersTests: XCTestCase {
    var app: Application!
    let orderDelegate = TestOrdersDelegate()
    var ordersService: OrdersService!
    
    override func setUp() async throws {
        self.app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)

        OrdersService.register(migrations: app.migrations)
        app.migrations.add(CreateOrderData())
        ordersService = try OrdersService(app: app, delegate: orderDelegate)
        app.databases.middleware.use(OrderDataMiddleware(service: ordersService), on: .sqlite)

        try await app.autoMigrate()
    }

    func testOrderGeneration() async throws {
        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData.$order.get(on: app.db)
        let data = try await ordersService.generateOrderContent(for: order, on: app.db)
        XCTAssertNotNil(data)
    }
}
