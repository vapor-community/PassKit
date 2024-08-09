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
        ordersService = try OrdersService(app: app, delegate: orderDelegate, pushRoutesMiddleware: SecretMiddleware(secret: "foo"))
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
        let pushToken = "1234567890"

        try await app.test(
            .POST,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertNotEqual(res.status, .unauthorized)
                XCTAssertEqual(res.status, .created)
            }
        )

        try await app.test(
            .POST,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertNotEqual(res.status, .unauthorized)
                XCTAssertEqual(res.status, .ok)
            }
        )

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = .withInternetDateTime
        try await app.test(
            .GET,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)?ordersModifiedSince=\(dateFormatter.string(from: Date.distantPast))",
            afterResponse: { res async throws in
                let orders = try res.content.decode(OrdersForDeviceDTO.self)
                XCTAssertEqual(orders.orderIdentifiers.count, 1)
                let orderID = try order.requireID()
                XCTAssertEqual(orders.orderIdentifiers[0], orderID.uuidString)
                XCTAssertEqual(orders.lastModified, dateFormatter.string(from: order.updatedAt!))
            }
        )

        try await app.test(
            .GET,
            "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                let pushTokens = try res.content.decode([String].self)
                XCTAssertEqual(pushTokens.count, 1)
                XCTAssertEqual(pushTokens[0], pushToken)
            }
        )

        try await app.test(
            .DELETE,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            afterResponse: { res async throws in
                XCTAssertNotEqual(res.status, .unauthorized)
                XCTAssertEqual(res.status, .ok)
            }
        )
    }

    func testErrorLog() async throws {
        let log1 = "Error 1"
        let log2 = "Error 2"

        try await app.test(
            .POST,
            "\(ordersURI)log",
            beforeRequest: { req async throws in
                try req.content.encode(ErrorLogDTO(logs: [log1, log2]))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )

        let logs = try await OrdersErrorLog.query(on: app.db).all()
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0].message, log1)
        XCTAssertEqual(logs[1].message, log2)
    }

    func testAPNSClient() async throws {
        XCTAssertNotNil(app.apns.client(.init(string: "orders")))
        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData.$order.get(on: app.db)
        try await ordersService.sendPushNotifications(for: order, on: app.db)
    }
}
