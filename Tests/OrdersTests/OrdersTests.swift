import PassKit
import Testing
import XCTVapor
import Zip

@testable import Orders

@Suite("Orders Tests", .serialized)
struct OrdersTests {
    let ordersURI = "/api/orders/v1/"
    let decoder = JSONDecoder()

    @Test("Order Generation", arguments: [true, false])
    func orderGeneration(useEncryptedKey: Bool) async throws {
        try await withApp(useEncryptedKey: useEncryptedKey) { app, ordersService in
            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData.$order.get(on: app.db)

            let data = try await ordersService.build(order: orderData, on: app.db)

            let orderURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).order")
            try data.write(to: orderURL)
            let orderFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try Zip.unzipFile(orderURL, destination: orderFolder)

            #expect(FileManager.default.fileExists(atPath: orderFolder.path.appending("/signature")))

            #expect(FileManager.default.fileExists(atPath: orderFolder.path.appending("/pet_store_logo.png")))
            #expect(FileManager.default.fileExists(atPath: orderFolder.path.appending("/it-IT.lproj/pet_store_logo.png")))

            #expect(FileManager.default.fileExists(atPath: orderFolder.path.appending("/order.json")))
            let orderJSONData = try String(contentsOfFile: orderFolder.path.appending("/order.json")).data(using: .utf8)
            let orderJSON = try decoder.decode(OrderJSONData.self, from: orderJSONData!)
            #expect(orderJSON.authenticationToken == order.authenticationToken)
            let orderID = try order.requireID().uuidString
            #expect(orderJSON.orderIdentifier == orderID)

            let manifestJSONData = try String(contentsOfFile: orderFolder.path.appending("/manifest.json")).data(using: .utf8)
            let manifestJSON = try decoder.decode([String: String].self, from: manifestJSONData!)
            let iconData = try Data(contentsOf: orderFolder.appendingPathComponent("/icon.png"))
            #expect(manifestJSON["icon.png"] == SHA256.hash(data: iconData).hex)
            #expect(manifestJSON["pet_store_logo.png"] != nil)
            #expect(manifestJSON["it-IT.lproj/pet_store_logo.png"] != nil)
        }
    }

    @Test("Getting Order from Apple Wallet API")
    func getOrderFromAPI() async throws {
        try await withApp { app, ordersService in
            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData.$order.get(on: app.db)

            try await app.test(
                .GET,
                "\(ordersURI)orders/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)orders/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)orders/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)orders/\(order.typeIdentifier)/invalidID",
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

    @Test("Device Registration API")
    func apiDeviceRegistration() async throws {
        try await withApp { app, ordersService in
            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData.$order.get(on: app.db)
            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

            try await app.test(
                .GET,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)?ordersModifiedSince=0",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                }
            )

            try await app.test(
                .DELETE,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )

            // Test registration without authentication token
            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\("not-a-uuid")",
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
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)?ordersModifiedSince=0",
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
                "\(ordersURI)push/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)push/\(order.typeIdentifier)/\("not-a-uuid")",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .DELETE,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\("not-a-uuid")",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            try await app.test(
                .DELETE,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
                headers: ["Authorization": "AppleOrder \(order.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )
        }
    }

    @Test("Error Logging")
    func errorLog() async throws {
        try await withApp { app, ordersService in
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

    @Test("APNS Client", arguments: [true, false])
    func apnsClient(useEncryptedKey: Bool) async throws {
        try await withApp(useEncryptedKey: useEncryptedKey) { app, ordersService in
            #expect(app.apns.client(.init(string: "orders")) != nil)

            let orderData = OrderData(title: "Test Order")
            try await orderData.create(on: app.db)
            let order = try await orderData._$order.get(on: app.db)

            try await ordersService.sendPushNotifications(for: orderData, on: app.db)

            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

            // Test call with incorrect secret
            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.typeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "bar"],
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )

            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.typeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                }
            )

            try await app.test(
                .POST,
                "\(ordersURI)devices/\(deviceLibraryIdentifier)/registrations/\(order.typeIdentifier)/\(order.requireID())",
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
                "\(ordersURI)push/\(order.typeIdentifier)/\(order.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .internalServerError)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .POST,
                "\(ordersURI)push/\(order.typeIdentifier)/\("not-a-uuid")",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            if !useEncryptedKey {
                // Test `AsyncModelMiddleware` update method
                orderData.title = "Test Order 2"
                do {
                    try await orderData.update(on: app.db)
                } catch let error as HTTPClientError {
                    #expect(error.self == .remoteConnectionClosed)
                }
            }
        }
    }
}
