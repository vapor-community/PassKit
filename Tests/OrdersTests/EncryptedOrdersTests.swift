import FluentKit
import PassKit
import Testing
import XCTVapor
import Zip

@testable import Orders

struct EncryptedOrdersTests {
    let delegate = EncryptedOrdersDelegate()
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

            // Test `OrderDataMiddleware` update method
            orderData.title = "Test Order 2"
            do {
                try await orderData.update(on: app.db)
            } catch {}
        }
    }
}
