import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Orders

final class OrdersTests: XCTestCase {
    var app: Application!
    let orderDelegate = OrderDelegate()
    
    override func setUp() async throws {
        self.app = try await Application.make(.testing)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        OrdersService.register(migrations: app.migrations)
        app.migrations.add(CreateOrderData())
        let ordersService = try OrdersService(app: app, delegate: orderDelegate)
        app.databases.middleware.use(OrderDataMiddleware(service: ordersService), on: .sqlite)

        try await app.autoMigrate()
    }
    
    override func tearDown() async throws { 
        try await app.autoRevert()
        try await self.app.asyncShutdown()
        self.app = nil
    }
}
