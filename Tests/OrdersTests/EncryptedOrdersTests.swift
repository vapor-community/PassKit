import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Orders
import PassKit
import Zip

final class EncryptedOrdersTests: XCTestCase {
    let delegate = EncryptedOrdersDelegate()
    let ordersURI = "/api/orders/v1/"
    var ordersService: OrdersService!
    var app: Application!
    
    override func setUp() async throws {
        self.app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)

        OrdersService.register(migrations: app.migrations)
        app.migrations.add(CreateOrderData())
        ordersService = try OrdersService(
            app: app,
            delegate: delegate,
            pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
            logger: app.logger
        )
        app.databases.middleware.use(OrderDataMiddleware(service: ordersService), on: .sqlite)

        try await app.autoMigrate()

        Zip.addCustomFileExtension("order")
    }

    override func tearDown() async throws { 
        try await app.autoRevert()
        try await self.app.asyncShutdown()
        self.app = nil
    }

    func testOrderGeneration() async throws {
        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData.$order.get(on: app.db)
        let data = try await ordersService.generateOrderContent(for: order, on: app.db)
        let orderURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.order")
        try data.write(to: orderURL)
        let orderFolder = try Zip.quickUnzipFile(orderURL)

        XCTAssert(FileManager.default.fileExists(atPath: orderFolder.path.appending("/signature")))

        let passJSONData = try String(contentsOfFile: orderFolder.path.appending("/order.json")).data(using: .utf8)
        let passJSON = try JSONSerialization.jsonObject(with: passJSONData!) as! [String: Any]
        XCTAssertEqual(passJSON["authenticationToken"] as? String, order.authenticationToken)
        try XCTAssertEqual(passJSON["orderIdentifier"] as? String, order.requireID().uuidString)

        let manifestJSONData = try String(contentsOfFile: orderFolder.path.appending("/manifest.json")).data(using: .utf8)
        let manifestJSON = try JSONSerialization.jsonObject(with: manifestJSONData!) as! [String: Any]
        let iconData = try Data(contentsOf: orderFolder.appendingPathComponent("/icon.png"))
        let iconHash = Array(SHA256.hash(data: iconData)).hex
        XCTAssertEqual(manifestJSON["icon.png"] as? String, iconHash)
    }

    func testAPNSClient() async throws {
        XCTAssertNotNil(app.apns.client(.init(string: "orders")))

        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData._$order.get(on: app.db)

        try await ordersService.sendPushNotificationsForOrder(id: order.requireID(), of: order.orderTypeIdentifier, on: app.db)

        let deviceLibraryIdentifier = "abcdefg"
        let pushToken = "1234567890"

        try await app.test(
            .POST,
            "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .noContent)
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
                XCTAssertEqual(res.status, .created)
            }
        )

        try await app.test(
            .POST,
            "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .internalServerError)
            }
        )

        // Test `OrderDataMiddleware` update method
        orderData.title = "Test Order 2"
        do {
            try await orderData.update(on: app.db)
        } catch {}
    }
}