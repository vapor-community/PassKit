import Fluent
import FluentSQLiteDriver
import PassKit
import XCTVapor
import Zip

@testable import Passes

final class PassesTests: XCTestCase {
    let delegate = TestPassesDelegate()
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

    func testPassesGeneration() async throws {
        let passData1 = PassData(title: "Test Pass 1")
        try await passData1.create(on: app.db)
        let pass1 = try await passData1.$pass.get(on: app.db)

        let passData2 = PassData(title: "Test Pass 2")
        try await passData2.create(on: app.db)
        let pass2 = try await passData2._$pass.get(on: app.db)

        let data = try await passesService.generatePassesContent(for: [pass1, pass2], on: app.db)
        XCTAssertNotNil(data)

        do {
            let data = try await passesService.generatePassesContent(for: [pass1], on: app.db)
            XCTFail("Expected error, got \(data)")
        } catch let error as PassesError {
            XCTAssertEqual(error, .invalidNumberOfPasses)
        }
    }

    func testPersonalization() async throws {
        let passData = PassData(title: "Personalize")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let data = try await passesService.generatePassContent(for: pass, on: app.db)
        let passURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.pkpass")
        try data.write(to: passURL)
        let passFolder = try Zip.quickUnzipFile(passURL)

        let passJSONData = try String(contentsOfFile: passFolder.path.appending("/pass.json")).data(
            using: .utf8)
        let passJSON = try JSONSerialization.jsonObject(with: passJSONData!) as! [String: Any]
        XCTAssertEqual(passJSON["authenticationToken"] as? String, pass.authenticationToken)
        try XCTAssertEqual(passJSON["serialNumber"] as? String, pass.requireID().uuidString)
        XCTAssertEqual(passJSON["description"] as? String, passData.title)

        let personalizationJSONData = try String(
            contentsOfFile: passFolder.path.appending("/personalization.json")
        ).data(using: .utf8)
        let personalizationJSON =
            try JSONSerialization.jsonObject(with: personalizationJSONData!) as! [String: Any]
        XCTAssertEqual(personalizationJSON["description"] as? String, "Hello, World!")

        let manifestJSONData = try String(
            contentsOfFile: passFolder.path.appending("/manifest.json")
        ).data(using: .utf8)
        let manifestJSON =
            try JSONSerialization.jsonObject(with: manifestJSONData!) as! [String: Any]
        let iconData = try Data(
            contentsOf: passFolder.appendingPathComponent("/personalizationLogo.png"))
        let iconHash = Array(Insecure.SHA1.hash(data: iconData)).hex
        XCTAssertEqual(manifestJSON["personalizationLogo.png"] as? String, iconHash)
    }

    // Tests the API Apple Wallet calls to get passes
    func testGetPassFromAPI() async throws {
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)

        try await app.test(
            .GET,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: [
                "Authorization": "ApplePass \(pass.authenticationToken)",
                "If-Modified-Since": "0",
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertNotNil(res.body)
                XCTAssertEqual(res.headers.contentType?.description, "application/vnd.apple.pkpass")
                XCTAssertNotNil(res.headers.lastModified)
            }
        )

        // Test call with invalid authentication token
        try await app.test(
            .GET,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: [
                "Authorization": "ApplePass invalid-token",
                "If-Modified-Since": "0",
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            }
        )

        // Test distant future `If-Modified-Since` date
        try await app.test(
            .GET,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: [
                "Authorization": "ApplePass \(pass.authenticationToken)",
                "If-Modified-Since": "2147483647",
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notModified)
            }
        )

        // Test call with invalid pass ID
        try await app.test(
            .GET,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/invalid-uuid",
            headers: [
                "Authorization": "ApplePass \(pass.authenticationToken)",
                "If-Modified-Since": "0",
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            }
        )

        // Test call with invalid pass type identifier
        try await app.test(
            .GET,
            "\(passesURI)passes/pass.com.example.InvalidType/\(pass.requireID())",
            headers: [
                "Authorization": "ApplePass \(pass.authenticationToken)",
                "If-Modified-Since": "0",
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
            }
        )
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
                ISOCountryCode: "US",
                phoneNumber: "1234567890",
                postalCode: "12345"
            )
        )

        try await app.test(
            .POST,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/\(pass.requireID())/personalize",
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
            personalizationQuery[0]._$ISOCountryCode.value,
            personalizationDict.requiredPersonalizationInfo.ISOCountryCode)
        XCTAssertEqual(
            personalizationQuery[0]._$phoneNumber.value,
            personalizationDict.requiredPersonalizationInfo.phoneNumber)
        XCTAssertEqual(
            personalizationQuery[0]._$postalCode.value,
            personalizationDict.requiredPersonalizationInfo.postalCode)

        // Test call with invalid pass ID
        try await app.test(
            .POST,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/invalid-uuid/personalize",
            beforeRequest: { req async throws in
                try req.content.encode(personalizationDict)
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            }
        )

        // Test call with invalid pass type identifier
        try await app.test(
            .POST,
            "\(passesURI)passes/pass.com.example.InvalidType/\(pass.requireID())/personalize",
            beforeRequest: { req async throws in
                try req.content.encode(personalizationDict)
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .notFound)
            }
        )
    }

    func testAPIDeviceRegistration() async throws {
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let deviceLibraryIdentifier = "abcdefg"
        let pushToken = "1234567890"

        // Test registration without authentication token
        try await app.test(
            .POST,
            "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
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

        // Test registration of an already registered device
        try await app.test(
            .POST,
            "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
            beforeRequest: { req async throws in
                try req.content.encode(RegistrationDTO(pushToken: pushToken))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )

        try await app.test(
            .GET,
            "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)?passesUpdatedSince=0",
            afterResponse: { res async throws in
                let passes = try res.content.decode(PassesForDeviceDTO.self)
                XCTAssertEqual(passes.serialNumbers.count, 1)
                let passID = try pass.requireID()
                XCTAssertEqual(passes.serialNumbers[0], passID.uuidString)
                XCTAssertEqual(passes.lastUpdated, String(pass.updatedAt!.timeIntervalSince1970))
            }
        )

        try await app.test(
            .GET,
            "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                let pushTokens = try res.content.decode([String].self)
                XCTAssertEqual(pushTokens.count, 1)
                XCTAssertEqual(pushTokens[0], pushToken)
            }
        )

        try await app.test(
            .GET,
            "\(passesURI)push/\(pass.passTypeIdentifier)/\("not-a-uuid")",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            }
        )

        try await app.test(
            .DELETE,
            "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
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
            "\(passesURI)log",
            beforeRequest: { req async throws in
                try req.content.encode(ErrorLogDTO(logs: [log1, log2]))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        )

        let logs = try await PassesErrorLog.query(on: app.db).all()
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0].message, log1)
        XCTAssertEqual(logs[1]._$message.value, log2)

        // Test call with no DTO
        try await app.test(
            .POST,
            "\(passesURI)log",
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            }
        )

        // Test call with empty logs
        try await app.test(
            .POST,
            "\(passesURI)log",
            beforeRequest: { req async throws in
                try req.content.encode(ErrorLogDTO(logs: []))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            }
        )
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

        try await app.test(
            .POST,
            "\(passesURI)push/\(pass.passTypeIdentifier)/\("not-a-uuid")",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest)
            }
        )

        // Test `PassDataMiddleware` update method
        passData.title = "Test Pass 2"
        do {
            try await passData.update(on: app.db)
        } catch let error as HTTPClientError {
            XCTAssertEqual(error.self, .remoteConnectionClosed)
        }
    }

    func testPassesError() {
        XCTAssertEqual(
            PassesError.templateNotDirectory.description,
            "PassesError(errorType: templateNotDirectory)")
        XCTAssertEqual(
            PassesError.pemCertificateMissing.description,
            "PassesError(errorType: pemCertificateMissing)")
        XCTAssertEqual(
            PassesError.pemPrivateKeyMissing.description,
            "PassesError(errorType: pemPrivateKeyMissing)")
        XCTAssertEqual(
            PassesError.opensslBinaryMissing.description,
            "PassesError(errorType: opensslBinaryMissing)")
        XCTAssertEqual(
            PassesError.invalidNumberOfPasses.description,
            "PassesError(errorType: invalidNumberOfPasses)")
    }

    func testDefaultDelegate() async throws {
        let delegate = DefaultPassesDelegate()
        XCTAssertEqual(delegate.wwdrCertificate, "WWDR.pem")
        XCTAssertEqual(delegate.pemCertificate, "passcertificate.pem")
        XCTAssertEqual(delegate.pemPrivateKey, "passkey.pem")
        XCTAssertNil(delegate.pemPrivateKeyPassword)
        XCTAssertEqual(delegate.sslBinary, URL(fileURLWithPath: "/usr/bin/openssl"))
        XCTAssertFalse(delegate.generateSignatureFile(in: URL(fileURLWithPath: "")))

        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let data = try await delegate.encodePersonalization(
            for: pass, db: app.db, encoder: JSONEncoder())
        XCTAssertNil(data)
    }
}

final class DefaultPassesDelegate: PassesDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "", isDirectory: true)
    func template<P: PassModel>(for pass: P, db: any Database) async throws -> URL {
        URL(fileURLWithPath: "")
    }
    func encode<P: PassModel>(
        pass: P, db: any Database, encoder: JSONEncoder
    ) async throws -> Data {
        Data()
    }
}
