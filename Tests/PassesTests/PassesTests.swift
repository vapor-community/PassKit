import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Passes
import PassKit

final class PassesTests: XCTestCase {
    let passDelegate = TestPassesDelegate()
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
            delegate: passDelegate,
            pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
            logger: app.logger
        )
        app.databases.middleware.use(PassDataMiddleware(service: passesService), on: .sqlite)

        try await app.autoMigrate()
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
        XCTAssertNotNil(data)
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
    }

    func testPersonalization() async throws {
        let passDataPersonalize = PassData(title: "Personalize")
        try await passDataPersonalize.create(on: app.db)
        let passPersonalize = try await passDataPersonalize.$pass.get(on: app.db)
        let dataPersonalize = try await passesService.generatePassContent(for: passPersonalize, on: app.db)

        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let data = try await passesService.generatePassContent(for: pass, on: app.db)

        XCTAssertGreaterThan(dataPersonalize.count, data.count)
    }

    // Tests the API Apple Wallet calls to get passes
    func testGetPassFromAPI() async throws {
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        try await app.test(
            .GET,
            "\(passesURI)passes/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: [
                "Authorization": "ApplePass \(pass.authenticationToken)",
                "If-Modified-Since": dateFormatter.string(from: Date.distantPast)
            ],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertNotNil(res.body)
                XCTAssertEqual(res.headers.contentType?.description, "application/vnd.apple.pkpass")
                XCTAssertNotNil(res.headers.lastModified)
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
        XCTAssertEqual(personalizationQuery[0]._$emailAddress.value, personalizationDict.requiredPersonalizationInfo.emailAddress)
        XCTAssertEqual(personalizationQuery[0]._$familyName.value, personalizationDict.requiredPersonalizationInfo.familyName)
        XCTAssertEqual(personalizationQuery[0]._$fullName.value, personalizationDict.requiredPersonalizationInfo.fullName)
        XCTAssertEqual(personalizationQuery[0]._$givenName.value, personalizationDict.requiredPersonalizationInfo.givenName)
        XCTAssertEqual(personalizationQuery[0]._$ISOCountryCode.value, personalizationDict.requiredPersonalizationInfo.ISOCountryCode)
        XCTAssertEqual(personalizationQuery[0]._$phoneNumber.value, personalizationDict.requiredPersonalizationInfo.phoneNumber)
        XCTAssertEqual(personalizationQuery[0]._$postalCode.value, personalizationDict.requiredPersonalizationInfo.postalCode)
    }

    func testAPIDeviceRegistration() async throws {
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let deviceLibraryIdentifier = "abcdefg"
        let pushToken = "1234567890"

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
    }

    func testAPNSClient() async throws {
        XCTAssertNotNil(app.apns.client(.init(string: "passes")))
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData._$pass.get(on: app.db)
        try await passesService.sendPushNotifications(for: pass, on: app.db)
        try await passesService.sendPushNotificationsForPass(id: pass.requireID(), of: pass.passTypeIdentifier, on: app.db)

        try await app.test(
            .POST,
            "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
            headers: ["X-Secret": "foo"],
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .noContent)
            }
        )
    }

    func testPassesError() {
        XCTAssertEqual(PassesError.templateNotDirectory.description, "PassesError(errorType: templateNotDirectory)")
        XCTAssertEqual(PassesError.pemCertificateMissing.description, "PassesError(errorType: pemCertificateMissing)")
        XCTAssertEqual(PassesError.pemPrivateKeyMissing.description, "PassesError(errorType: pemPrivateKeyMissing)")
        XCTAssertEqual(PassesError.opensslBinaryMissing.description, "PassesError(errorType: opensslBinaryMissing)")
        XCTAssertEqual(PassesError.invalidNumberOfPasses.description, "PassesError(errorType: invalidNumberOfPasses)")
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
        let data = try await delegate.encodePersonalization(for: pass, db: app.db, encoder: JSONEncoder())
        XCTAssertNil(data)
    }
}
