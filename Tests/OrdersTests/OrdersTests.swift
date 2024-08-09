import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Orders
@testable import PassKit

final class OrdersTests: XCTestCase {
    let orderDelegate = TestOrdersDelegate()
    let ordersURI = "/api/orders/v1/"
    var ordersService: OrdersService!
    var app: Application!
    
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

    func testAPIDeviceRegistration() async throws {
        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData.$order.get(on: app.db)
        let deviceLibraryIdentifier = "abcdefg"

        try await app.test(
            .POST,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: "1234567890"))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            }
        )

        try await app.test(
            .POST,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: "1234567890"))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )

        try await app.test(
            .DELETE,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )
    }
}
