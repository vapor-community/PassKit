import PassKit
import Testing
import XCTVapor
import Zip

@testable import Passes

@Suite("Passes Tests with Encrypted PEM Key")
struct EncryptedPassesTests {
    let delegate = EncryptedPassesDelegate()
    let passesURI = "/api/passes/v1/"

    @Test("Pass Generation")
    func passGeneration() async throws {
        try await withApp(delegate: delegate) { app, passesService in
            let passData = PassData(title: "Test Pass")
            try await passData.create(on: app.db)
            let pass = try await passData.$pass.get(on: app.db)
            let data = try await passesService.generatePassContent(for: pass, on: app.db)
            let passURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.pkpass")
            try data.write(to: passURL)
            let passFolder = try Zip.quickUnzipFile(passURL)

            #expect(FileManager.default.fileExists(atPath: passFolder.path.appending("/signature")))

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
        }
    }

    @Test("Personalizable Pass Apple Wallet API")
    func personalizationAPI() async throws {
        try await withApp(delegate: delegate) { app, passesService in
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
        }
    }

    @Test("APNS Client")
    func apnsClient() async throws {
        try await withApp(delegate: delegate) { app, passesService in
            #expect(app.apns.client(.init(string: "passes")) != nil)

            let passData = PassData(title: "Test Pass")
            try await passData.create(on: app.db)
            let pass = try await passData._$pass.get(on: app.db)

            try await passesService.sendPushNotificationsForPass(id: pass.requireID(), of: pass.passTypeIdentifier, on: app.db)

            let deviceLibraryIdentifier = "abcdefg"
            let pushToken = "1234567890"

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

            // Test `PassDataMiddleware` update method
            passData.title = "Test Pass 2"
            do {
                try await passData.update(on: app.db)
            } catch {}
        }
    }
}
