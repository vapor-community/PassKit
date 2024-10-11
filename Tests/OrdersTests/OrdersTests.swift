import FluentKit
import PassKit
import Testing
import XCTVapor
import Zip

@testable import Orders

struct OrdersTests {
    let delegate = TestOrdersDelegate()
    let ordersURI = "/api/orders/v1/"

    @Test func orderGeneration() async throws {
        try await withApp(delegate: delegate) { app, ordersService in
            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData.$order.get(on: app.db)
            let data = try await ordersService.generateOrderContent(for: order, on: app.db)
            let orderURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.order")
            try data.write(to: orderURL)
            let orderFolder = try Zip.quickUnzipFile(orderURL)

            #expect(FileManager.default.fileExists(atPath: orderFolder.path.appending("/signature")))

            let passJSONData = try String(contentsOfFile: orderFolder.path.appending("/order.json")).data(using: .utf8)
            let passJSON = try JSONSerialization.jsonObject(with: passJSONData!) as! [String: Any]
            #expect(passJSON["authenticationToken"] as? String == order.authenticationToken)
            let orderID = try order.requireID().uuidString
            #expect(passJSON["orderIdentifier"] as? String == orderID)

            let manifestJSONData = try String(contentsOfFile: orderFolder.path.appending("/manifest.json")).data(using: .utf8)
            let manifestJSON = try JSONSerialization.jsonObject(with: manifestJSONData!) as! [String: Any]
            let iconData = try Data(contentsOf: orderFolder.appendingPathComponent("/icon.png"))
            let iconHash = Array(SHA256.hash(data: iconData)).hex
            #expect(manifestJSON["icon.png"] as? String == iconHash)
            #expect(manifestJSON["pet_store_logo.png"] != nil)
        }
    }

    // Tests the API Apple Wallet calls to get orders
    @Test func getOrderFromAPI() async throws {
        try await withApp(delegate: delegate) { app, ordersService in
            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData.$order.get(on: app.db)

            try await app.test(
                .GET,
                "\(ordersURI)orders/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: [
                    "Authorization": "AppleOrder \(order.authenticationToken)",
                    "If-Modified-Since": "0",
                ],
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.body != nil)
                    #expect(res.headers.contentType?.description == "application/vnd.apple.order")
                    #expect(res.headers.lastModified != nil)
                }
            )

            // Test call with invalid authentication token
            try await app.test(
                .GET,
                "\(ordersURI)orders/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: [
                    "Authorization": "AppleOrder invalidToken",
                    "If-Modified-Since": "0",
                ],
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )

            // Test distant future `If-Modified-Since` date
            try await app.test(
                .GET,
                "\(ordersURI)orders/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: [
                    "Authorization": "AppleOrder \(order.authenticationToken)",
                    "If-Modified-Since": "2147483647",
                ],
                afterResponse: { res async throws in
                    #expect(res.status == .notModified)
                }
            )

            // Test call with invalid order ID
            try await app.test(
                .GET,
                "\(ordersURI)orders/\(order.orderTypeIdentifier)/invalidID",
                headers: [
                    "Authorization": "AppleOrder \(order.authenticationToken)",
                    "If-Modified-Since": "0",
                ],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid order type identifier
            try await app.test(
                .GET,
                "\(ordersURI)orders/order.com.example.InvalidType/\(order.requireID())",
                headers: [
                    "Authorization": "AppleOrder \(order.authenticationToken)",
                    "If-Modified-Since": "0",
                ],
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    @Test func apiDeviceRegistration() async throws {
        try await withApp(delegate: delegate) { app, ordersService in
            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData.$order.get(on: app.db)
            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

            try await app.test(
                .GET,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)?ordersModifiedSince=0",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                }
            )

            try await app.test(
                .DELETE,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )

            // Test registration without authentication token
            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
                beforeRequest: { req async throws in
                    try req.content.encode(RegistrationDTO(pushToken: pushToken))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )

            // Test registration of a non-existing order
            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\("order.com.example.NotFound")/\(UUID().uuidString)",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                beforeRequest: { req async throws in
                    try req.content.encode(RegistrationDTO(pushToken: pushToken))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )

            // Test call without DTO
            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\("not-a-uuid")",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                beforeRequest: { req async throws in
                    try req.content.encode(RegistrationDTO(pushToken: pushToken))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
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
                    #expect(res.status == .created)
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
                    #expect(res.status == .ok)
                }
            )

            try await app.test(
                .GET,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)?ordersModifiedSince=0",
                afterResponse: { res async throws in
                    let orders = try res.content.decode(OrdersForDeviceDTO.self)
                    #expect(orders.orderIdentifiers.count == 1)
                    let orderID = try order.requireID()
                    #expect(orders.orderIdentifiers[0] == orderID.uuidString)
                    #expect(orders.lastModified == String(order.updatedAt!.timeIntervalSince1970))
                }
            )

            try await app.test(
                .GET,
                "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    let pushTokens = try res.content.decode([String].self)
                    #expect(pushTokens.count == 1)
                    #expect(pushTokens[0] == pushToken)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .GET,
                "\(ordersURI)push/\(order.orderTypeIdentifier)/\("not-a-uuid")",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .DELETE,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\("not-a-uuid")",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            try await app.test(
                .DELETE,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )
        }
    }

    @Test func errorLog() async throws {
        try await withApp(delegate: delegate) { app, ordersService in
            let log1 = "Error 1"
            let log2 = "Error 2"

            try await app.test(
                .POST,
                "\(ordersURI)log",
                beforeRequest: { req async throws in
                    try req.content.encode(ErrorLogDTO(logs: [log1, log2]))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )

            let logs = try await OrdersErrorLog.query(on: app.db).all()
            #expect(logs.count == 2)
            #expect(logs[0].message == log1)
            #expect(logs[1]._$message.value == log2)

            // Test call with no DTO
            try await app.test(
                .POST,
                "\(ordersURI)log",
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with empty logs
            try await app.test(
                .POST,
                "\(ordersURI)log",
                beforeRequest: { req async throws in
                    try req.content.encode(ErrorLogDTO(logs: []))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test func apnsClient() async throws {
        try await withApp(delegate: delegate) { app, ordersService in
            #expect(app.apns.client(.init(string: "orders")) != nil)

            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData._$order.get(on: app.db)

            try await ordersService.sendPushNotificationsForOrder(id: order.requireID(), of: order.orderTypeIdentifier, on: app.db)

            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

            // Test call with incorrect secret
            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "bar"],
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )

            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
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
                    #expect(res.status == .created)
                }
            )

            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.orderTypeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .internalServerError)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.orderTypeIdentifier)/\("not-a-uuid")",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test `OrderDataMiddleware` update method
            orderData.title = "Test Order 2"
            do {
                try await orderData.update(on: app.db)
            } catch let error as HTTPClientError {
                #expect(error.self == .remoteConnectionClosed)
            }
        }
    }

    @Test func ordersError() {
        #expect(OrdersError.templateNotDirectory.description == "OrdersError(errorType: templateNotDirectory)")
        #expect(OrdersError.pemCertificateMissing.description == "OrdersError(errorType: pemCertificateMissing)")
        #expect(OrdersError.pemPrivateKeyMissing.description == "OrdersError(errorType: pemPrivateKeyMissing)")
        #expect(OrdersError.opensslBinaryMissing.description == "OrdersError(errorType: opensslBinaryMissing)")
    }

    @Test func defaultDelegate() {
        let delegate = DefaultOrdersDelegate()
        #expect(delegate.wwdrCertificate == "WWDR.pem")
        #expect(delegate.pemCertificate == "ordercertificate.pem")
        #expect(delegate.pemPrivateKey == "orderkey.pem")
        #expect(delegate.pemPrivateKeyPassword == nil)
        #expect(delegate.sslBinary == URL(fileURLWithPath: "/usr/bin/openssl"))
        #expect(!delegate.generateSignatureFile(in: URL(fileURLWithPath: "")))
    }
}

final class DefaultOrdersDelegate: OrdersDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "", isDirectory: true)
    func template<O: OrderModel>(for order: O, db: any Database) async throws -> URL {
        URL(fileURLWithPath: "")
    }
    func encode<O: OrderModel>(order: O, db: any Database, encoder: JSONEncoder) async throws -> Data {
        Data()
    }
}
