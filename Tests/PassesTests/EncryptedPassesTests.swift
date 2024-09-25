import Fluent
import FluentSQLiteDriver
import PassKit
import XCTVapor
import Zip

@testable import Passes

final class EncryptedPassesTests: XCTestCase {
    let delegate = EncryptedPassesDelegate()
    let passesURI = "/api/passes/v1/"
    var passesService: PassesService!
    var app: Application!

    override func setUp() async throws {
        self.app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)

        PassesService.register(migrations: app.migrations)
        app.migrations.add(CreatePassData())
        passesService = try PassesService(
            app: app,
            delegate: delegate,
            pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
            logger: app.logger
        )
        app.databases.middleware.use(PassDataMiddleware(service: passesService), on: .sqlite)

        try await app.autoMigrate()

        Zip.addCustomFileExtension("pkpass")
    }

    override func tearDown() async throws {
        try await app.autoRevert()
        try await self.app.asyncShutdown()
        self.app = nil
    }

    func testPassGeneration() async throws {
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let data = try await passesService.generatePassContent(for: pass, on: app.db)
        let passURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.pkpass")
        try data.write(to: passURL)
        let passFolder = try Zip.quickUnzipFile(passURL)

        XCTAssert(FileManager.default.fileExists(atPath: passFolder.path.appending("/signature")))

        let passJSONData = try String(contentsOfFile: passFolder.path.appending("/pass.json")).data(
            using: .utf8)
        let passJSON = try JSONSerialization.jsonObject(with: passJSONData!) as! [String: Any]
        XCTAssertEqual(passJSON["authenticationToken"] as? String, pass.authenticationToken)
        try XCTAssertEqual(passJSON["serialNumber"] as? String, pass.requireID().uuidString)
        XCTAssertEqual(passJSON["description"] as? String, passData.title)

        let manifestJSONData = try String(
            contentsOfFile: passFolder.path.appending("/manifest.json")
        ).data(using: .utf8)
        let manifestJSON =
            try JSONSerialization.jsonObject(with: manifestJSONData!) as! [String: Any]
        let iconData = try Data(contentsOf: passFolder.appendingPathComponent("/icon.png"))
        let iconHash = Array(Insecure.SHA1.hash(data: iconData)).hex
        XCTAssertEqual(manifestJSON["icon.png"] as? String, iconHash)
    }

    func testPersonalizationAPI() async throws {
        let passData = PassData(title: "Personalize")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let personalizationDict = PersonalizationDictionaryDTO(
            personalizationToken: "1234567890",
            requiredPersonalizationInfo: .init(
                emailAddress: "test@example.com",
                familyName: "Doe",
                fullName: "John Doe",
                givenName: "John",
                isoCountryCode: "US",
                phoneNumber: "1234567890",
                postalCode: "12345"
            )
        )

        try await app.test(
            .POST,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/\(pass.requireID())/personalize",
            headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(personalizationDict)
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertNotNil(res.body)
                XCTAssertEqual(res.headers.contentType?.description, "application/octet-stream")
            }
        )

        let personalizationQuery = try await UserPersonalization.query(on: app.db).all()
        XCTAssertEqual(personalizationQuery.count, 1)
        let passPersonalizationID = try await Pass.query(on: app.db).first()?
            ._$userPersonalization.get(on: app.db)?
            .requireID()
        XCTAssertEqual(personalizationQuery[0]._$id.value, passPersonalizationID)
        XCTAssertEqual(
            personalizationQuery[0]._$emailAddress.value,
            personalizationDict.requiredPersonalizationInfo.emailAddress)
        XCTAssertEqual(
            personalizationQuery[0]._$familyName.value,
            personalizationDict.requiredPersonalizationInfo.familyName)
        XCTAssertEqual(
            personalizationQuery[0]._$fullName.value,
            personalizationDict.requiredPersonalizationInfo.fullName)
        XCTAssertEqual(
            personalizationQuery[0]._$givenName.value,
            personalizationDict.requiredPersonalizationInfo.givenName)
        XCTAssertEqual(
            personalizationQuery[0]._$isoCountryCode.value,
            personalizationDict.requiredPersonalizationInfo.isoCountryCode)
        XCTAssertEqual(
            personalizationQuery[0]._$phoneNumber.value,
            personalizationDict.requiredPersonalizationInfo.phoneNumber)
        XCTAssertEqual(
            personalizationQuery[0]._$postalCode.value,
            personalizationDict.requiredPersonalizationInfo.postalCode)
    }

    func testAPNSClient() async throws {
        XCTAssertNotNil(app.apns.client(.init(string: "passes")))

        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData._$pass.get(on: app.db)

        try await passesService.sendPushNotificationsForPass(
            id: pass.requireID(), of: pass.passTypeIdentifier, on: app.db)

        let deviceLibraryIdentifier = "abcdefg"
        let pushToken = "1234567890"

        try await app.test(
            .POST,
            "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .noContent)
            }
        )

        try await app.test(
            .POST,
            "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            }
        )

        try await app.test(
            .POST,
            "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .internalServerError)
            }
        )

        // Test `PassDataMiddleware` update method
        passData.title = "Test Pass 2"
        do {
            try await passData.update(on: app.db)
        } catch {}
    }
}
