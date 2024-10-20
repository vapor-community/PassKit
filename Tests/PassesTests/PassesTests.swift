import FluentKit
import PassKit
import Testing
import XCTVapor
import Zip

@testable import Passes

@Suite("Passes Tests")
struct PassesTests {
    let passesURI = "/api/passes/v1/"

    @Test("Pass Generation", .serialized, arguments: [true, false])
    func passGeneration(useEncryptedKey: Bool) async throws {
        try await withApp(useEncryptedKey: useEncryptedKey) { app, passesService in
            let passData = PassData(title: "Test Pass")
            try await passData.create(on: app.db)
            let pass = try await passData.$pass.get(on: app.db)
            let data = try await passesService.generatePassContent(for: pass, on: app.db)
            let passURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.pkpass")
            try data.write(to: passURL)
            let passFolder = try Zip.quickUnzipFile(passURL)

            #expect(FileManager.default.fileExists(atPath: passFolder.path.appending("/signature")))

            #expect(FileManager.default.fileExists(atPath: passFolder.path.appending("/pass.json")))
            let passJSONData = try String(contentsOfFile: passFolder.path.appending("/pass.json")).data(using: .utf8)
            let passJSON = try JSONSerialization.jsonObject(with: passJSONData!) as! [String: Any]
            #expect(passJSON["authenticationToken"] as? String == pass.authenticationToken)
            let passID = try pass.requireID().uuidString
            #expect(passJSON["serialNumber"] as? String == passID)
            #expect(passJSON["description"] as? String == passData.title)

            let manifestJSONData = try String(contentsOfFile: passFolder.path.appending("/manifest.json")).data(using: .utf8)
            let manifestJSON = try JSONSerialization.jsonObject(with: manifestJSONData!) as! [String: Any]
            let iconData = try Data(contentsOf: passFolder.appendingPathComponent("/icon.png"))
            let iconHash = Array(Insecure.SHA1.hash(data: iconData)).hex
            #expect(manifestJSON["icon.png"] as? String == iconHash)
            #expect(manifestJSON["logo.png"] != nil)
            #expect(manifestJSON["personalizationLogo.png"] != nil)
        }
    }

    @Test("Generating Multiple Passes")
    func passesGeneration() async throws {
        try await withApp { app, passesService in
            let passData1 = PassData(title: "Test Pass 1")
            try await passData1.create(on: app.db)
            let pass1 = try await passData1.$pass.get(on: app.db)

            let passData2 = PassData(title: "Test Pass 2")
            try await passData2.create(on: app.db)
            let pass2 = try await passData2._$pass.get(on: app.db)

            let data = try await passesService.generatePassesContent(for: [pass1, pass2], on: app.db)
            #expect(data != nil)

            do {
                let data = try await passesService.generatePassesContent(for: [pass1], on: app.db)
                Issue.record("Expected error, got \(data)")
            } catch let error as PassesError {
                #expect(error == .invalidNumberOfPasses)
            }
        }
    }

    @Test("Personalizable Passes")
    func personalization() async throws {
        try await withApp { app, passesService in
            let passData = PassData(title: "Personalize")
            try await passData.create(on: app.db)
            let pass = try await passData.$pass.get(on: app.db)
            let data = try await passesService.generatePassContent(for: pass, on: app.db)
            let passURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.pkpass")
            try data.write(to: passURL)
            let passFolder = try Zip.quickUnzipFile(passURL)

            #expect(FileManager.default.fileExists(atPath: passFolder.path.appending("/signature")))

            #expect(FileManager.default.fileExists(atPath: passFolder.path.appending("/pass.json")))
            let passJSONData = try String(contentsOfFile: passFolder.path.appending("/pass.json")).data(using: .utf8)
            let passJSON = try JSONSerialization.jsonObject(with: passJSONData!) as! [String: Any]
            #expect(passJSON["authenticationToken"] as? String == pass.authenticationToken)
            let passID = try pass.requireID().uuidString
            #expect(passJSON["serialNumber"] as? String == passID)
            #expect(passJSON["description"] as? String == passData.title)

            let personalizationJSONData = try String(contentsOfFile: passFolder.path.appending("/personalization.json")).data(using: .utf8)
            let personalizationJSON = try JSONSerialization.jsonObject(with: personalizationJSONData!) as! [String: Any]
            #expect(personalizationJSON["description"] as? String == "Hello, World!")

            let manifestJSONData = try String(contentsOfFile: passFolder.path.appending("/manifest.json")).data(using: .utf8)
            let manifestJSON = try JSONSerialization.jsonObject(with: manifestJSONData!) as! [String: Any]
            let iconData = try Data(contentsOf: passFolder.appendingPathComponent("/personalizationLogo.png"))
            let iconHash = Array(Insecure.SHA1.hash(data: iconData)).hex
            #expect(manifestJSON["personalizationLogo.png"] as? String == iconHash)
        }
    }

    @Test("Getting Pass from Apple Wallet API")
    func getPassFromAPI() async throws {
        try await withApp { app, passesService in
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
                    #expect(res.status == .ok)
                    #expect(res.body != nil)
                    #expect(res.headers.contentType?.description == "application/vnd.apple.pkpass")
                    #expect(res.headers.lastModified != nil)
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
                    #expect(res.status == .unauthorized)
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
                    #expect(res.status == .notModified)
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
                    #expect(res.status == .badRequest)
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
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    @Test("Personalizable Pass Apple Wallet API", arguments: [true, false])
    func personalizationAPI(useEncryptedKey: Bool) async throws {
        try await withApp(useEncryptedKey: useEncryptedKey) { app, passesService in
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
                beforeRequest: { req async throws in
                    try req.content.encode(personalizationDict)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.body != nil)
                    #expect(res.headers.contentType?.description == "application/octet-stream")
                }
            )

            let personalizationQuery = try await UserPersonalization.query(on: app.db).all()
            #expect(personalizationQuery.count == 1)
            let passPersonalizationID = try await Pass.query(on: app.db).first()?._$userPersonalization.get(on: app.db)?.requireID()
            #expect(personalizationQuery[0]._$id.value == passPersonalizationID)
            #expect(personalizationQuery[0]._$emailAddress.value == personalizationDict.requiredPersonalizationInfo.emailAddress)
            #expect(personalizationQuery[0]._$familyName.value == personalizationDict.requiredPersonalizationInfo.familyName)
            #expect(personalizationQuery[0]._$fullName.value == personalizationDict.requiredPersonalizationInfo.fullName)
            #expect(personalizationQuery[0]._$givenName.value == personalizationDict.requiredPersonalizationInfo.givenName)
            #expect(personalizationQuery[0]._$isoCountryCode.value == personalizationDict.requiredPersonalizationInfo.isoCountryCode)
            #expect(personalizationQuery[0]._$phoneNumber.value == personalizationDict.requiredPersonalizationInfo.phoneNumber)
            #expect(personalizationQuery[0]._$postalCode.value == personalizationDict.requiredPersonalizationInfo.postalCode)

            // Test call with invalid pass ID
            try await app.test(
                .POST,
                "\(passesURI)passes/\(pass.passTypeIdentifier)/invalid-uuid/personalize",
                beforeRequest: { req async throws in
                    try req.content.encode(personalizationDict)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
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
                    #expect(res.status == .notFound)
                }
            )
        }
    }

    @Test("Device Registration API")
    func apiDeviceRegistration() async throws {
        try await withApp { app, passesService in
            let passData = PassData(title: "Test Pass")
            try await passData.create(on: app.db)
            let pass = try await passData.$pass.get(on: app.db)
            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

            try await app.test(
                .GET,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)?passesUpdatedSince=0",
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                }
            )

            try await app.test(
                .DELETE,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
                headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                }
            )

            // Test registration without authentication token
            try await app.test(
                .POST,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
                beforeRequest: { req async throws in
                    try req.content.encode(RegistrationDTO(pushToken: pushToken))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )

            // Test registration of a non-existing pass
            try await app.test(
                .POST,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\("pass.com.example.NotFound")/\(UUID().uuidString)",
                headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
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
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
                headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .POST,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\("not-a-uuid")",
                headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
                beforeRequest: { req async throws in
                    try req.content.encode(RegistrationDTO(pushToken: pushToken))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
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
                    #expect(res.status == .created)
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
                    #expect(res.status == .ok)
                }
            )

            try await app.test(
                .GET,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)?passesUpdatedSince=0",
                afterResponse: { res async throws in
                    let passes = try res.content.decode(PassesForDeviceDTO.self)
                    #expect(passes.serialNumbers.count == 1)
                    let passID = try pass.requireID()
                    #expect(passes.serialNumbers[0] == passID.uuidString)
                    #expect(passes.lastUpdated == String(pass.updatedAt!.timeIntervalSince1970))
                }
            )

            try await app.test(
                .GET,
                "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
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
                "\(passesURI)push/\(pass.passTypeIdentifier)/\("not-a-uuid")",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .DELETE,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\("not-a-uuid")",
                headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            try await app.test(
                .DELETE,
                "\(passesURI)devices/\(deviceLibraryIdentifier)/registrations/\(pass.passTypeIdentifier)/\(pass.requireID())",
                headers: ["Authorization": "ApplePass \(pass.authenticationToken)"],
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )
        }
    }

    @Test("Error Logging")
    func errorLog() async throws {
        try await withApp { app, passesService in
            let log1 = "Error 1"
            let log2 = "Error 2"

            try await app.test(
                .POST,
                "\(passesURI)log",
                beforeRequest: { req async throws in
                    try req.content.encode(ErrorLogDTO(logs: [log1, log2]))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                }
            )

            let logs = try await PassesErrorLog.query(on: app.db).all()
            #expect(logs.count == 2)
            #expect(logs[0].message == log1)
            #expect(logs[1]._$message.value == log2)

            // Test call with no DTO
            try await app.test(
                .POST,
                "\(passesURI)log",
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
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
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    @Test("APNS Client", arguments: [true, false])
    func apnsClient(useEncryptedKey: Bool) async throws {
        try await withApp(useEncryptedKey: useEncryptedKey) { app, passesService in
            #expect(app.apns.client(.init(string: "passes")) != nil)

            let passData = PassData(title: "Test Pass")
            try await passData.create(on: app.db)
            let pass = try await passData._$pass.get(on: app.db)

            try await passesService.sendPushNotificationsForPass(id: pass.requireID(), of: pass.passTypeIdentifier, on: app.db)

            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

            // Test call with incorrect secret
            try await app.test(
                .POST,
                "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
                headers: ["X-Secret": "bar"],
                afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                }
            )

            try await app.test(
                .POST,
                "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .noContent)
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
                    #expect(res.status == .created)
                }
            )

            try await app.test(
                .POST,
                "\(passesURI)push/\(pass.passTypeIdentifier)/\(pass.requireID())",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .internalServerError)
                }
            )

            // Test call with invalid UUID
            try await app.test(
                .POST,
                "\(passesURI)push/\(pass.passTypeIdentifier)/\("not-a-uuid")",
                headers: ["X-Secret": "foo"],
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                }
            )

            // Test `PassDataMiddleware` update method
            // TODO: Fix this test
            // passData.title = "Test Pass 2"
            // do {
            //     try await passData.update(on: app.db)
            // } catch let error as HTTPClientError {
            //     #expect(error.self == .remoteConnectionClosed)
            // }
        }
    }

    @Test("PassesError")
    func passesError() {
        #expect(PassesError.templateNotDirectory.description == "PassesError(errorType: templateNotDirectory)")
        #expect(PassesError.pemCertificateMissing.description == "PassesError(errorType: pemCertificateMissing)")
        #expect(PassesError.pemPrivateKeyMissing.description == "PassesError(errorType: pemPrivateKeyMissing)")
        #expect(PassesError.opensslBinaryMissing.description == "PassesError(errorType: opensslBinaryMissing)")
        #expect(PassesError.invalidNumberOfPasses.description == "PassesError(errorType: invalidNumberOfPasses)")
    }

    @Test("Default PassesDelegate Properties")
    func defaultDelegate() async throws {
        final class DefaultPassesDelegate: PassesDelegate {
            func template<P: PassModel>(for pass: P, db: any Database) async throws -> String { "" }
            func encode<P: PassModel>(pass: P, db: any Database, encoder: JSONEncoder) async throws -> Data { Data() }
        }

        let defaultDelegate = DefaultPassesDelegate()
        #expect(!defaultDelegate.generateSignatureFile(in: URL(fileURLWithPath: "")))

        try await withApp { app, passesService in
            let passData = PassData(title: "Test Pass")
            try await passData.create(on: app.db)
            let pass = try await passData.$pass.get(on: app.db)
            let data = try await defaultDelegate.personalizationJSON(for: pass, db: app.db)
            #expect(data == nil)
        }
    }
}
