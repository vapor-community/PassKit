import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Orders
import PassKit
import Zip

final class OrdersTests: XCTestCase {
    let delegate = TestOrdersDelegate()
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

    // Tests the API Apple Wallet calls to get orders
    func testGetOrderFromAPI() async throws {
        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData.$order.get(on: app.db)

        try await app.test(
            .GET,
            "\(ordersURI)orders/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: [
                "Authorization": "AppleOrder \(order.authenticationToken)",
                "If-Modified-Since": "0"
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertNotNil(res.body)
                XCTAssertEqual(res.headers.contentType?.description, "application/vnd.apple.order")
                XCTAssertNotNil(res.headers.lastModified)
            }
        )
    }

    func testAPIDeviceRegistration() async throws {
        let orderData = OrderData(title: "Test Order")
        try await orderData.create(on: app.db)
        let order = try await orderData.$order.get(on: app.db)
        let deviceLibraryIdentifier = "abcdefg"
        let pushToken = "1234567890"

        // Test registration without authentication token
        try await app.test(
            .POST,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
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

        // Test registration of an already registered device
        try await app.test(
            .POST,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
            headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )

        try await app.test(
            .GET,
            "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)?ordersModifiedSince=0",
            afterResponse: { res async throws in
                let orders = try res.content.decode(OrdersForDeviceDTO.self)
                XCTAssertEqual(orders.orderIdentifiers.count, 1)
                let orderID = try order.requireID()
                XCTAssertEqual(orders.orderIdentifiers[0], orderID.uuidString)
                XCTAssertEqual(orders.lastModified, String(order.updatedAt!.timeIntervalSince1970))
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
        XCTAssertEqual(logs[1]._$message.value, log2)
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
        } catch let error as HTTPClientError {
            XCTAssertEqual(error.self, .remoteConnectionClosed)
        }
    }

    func testOrdersError() {
        XCTAssertEqual(OrdersError.templateNotDirectory.description, "OrdersError(errorType: templateNotDirectory)")
        XCTAssertEqual(OrdersError.pemCertificateMissing.description, "OrdersError(errorType: pemCertificateMissing)")
        XCTAssertEqual(OrdersError.pemPrivateKeyMissing.description, "OrdersError(errorType: pemPrivateKeyMissing)")
        XCTAssertEqual(OrdersError.opensslBinaryMissing.description, "OrdersError(errorType: opensslBinaryMissing)")
    }

    func testDefaultDelegate() {
        let delegate = DefaultOrdersDelegate()
        XCTAssertEqual(delegate.wwdrCertificate, "WWDR.pem")
        XCTAssertEqual(delegate.pemCertificate, "ordercertificate.pem")
        XCTAssertEqual(delegate.pemPrivateKey, "orderkey.pem")
        XCTAssertNil(delegate.pemPrivateKeyPassword)
        XCTAssertEqual(delegate.sslBinary, URL(fileURLWithPath: "/usr/bin/openssl"))
        XCTAssertFalse(delegate.generateSignatureFile(in: URL(fileURLWithPath: "")))
    }
}

final class DefaultOrdersDelegate: OrdersDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "", isDirectory: true)
    func template<O: OrderModel>(for order: O, db: any Database) async throws -> URL { URL(fileURLWithPath: "") }
    func encode<O: OrderModel>(order: O, db: any Database, encoder: JSONEncoder) async throws -> Data { Data() }
}
