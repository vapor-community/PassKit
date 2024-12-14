import Fluent
import Passes
import Vapor

import struct Foundation.UUID

final class PassData: PassDataModel, @unchecked Sendable {
    static let schema = PassData.FieldKeys.schemaName

    static let typeIdentifier = "pass.com.vapor-community.PassKit"

    @ID(key: .id)
    var id: UUID?

    @Field(key: PassData.FieldKeys.title)
    var title: String

    @Parent(key: PassData.FieldKeys.passID)
    var pass: Pass

    init() {}

    init(id: UUID? = nil, title: String) {
        self.id = id
        self.title = title
    }
}

struct CreatePassData: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PassData.FieldKeys.schemaName)
            .id()
            .field(PassData.FieldKeys.title, .string, .required)
            .field(PassData.FieldKeys.passID, .uuid, .required, .references(Pass.schema, .id, onDelete: .cascade))
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PassData.FieldKeys.schemaName).delete()
    }
}

extension PassData {
    enum FieldKeys {
        static let schemaName = "pass_data"
        static let title = FieldKey(stringLiteral: "title")
        static let passID = FieldKey(stringLiteral: "pass_id")
    }
}

extension PassData {
    func passJSON(on db: any Database) async throws -> any PassJSON.Properties {
        try await PassJSONData(data: self, pass: self.$pass.get(on: db))
    }

    func template(on db: any Database) async throws -> String {
        "\(FileManager.default.currentDirectoryPath)/Tests/PassesTests/Templates/"
    }

    func personalizationJSON(on db: any Database) async throws -> PersonalizationJSON? {
        if self.title != "Personalize" { return nil }

        if try await self.$pass.get(on: db).$userPersonalization.get(on: db) == nil {
            return PersonalizationJSON(
                requiredPersonalizationFields: [.name, .postalCode, .emailAddress, .phoneNumber],
                description: "Hello, World!"
            )
        } else {
            return nil
        }
    }
}

// MARK: - PassJSON

extension PassJSON.FormatVersion: Decodable {}
extension PassJSON.BarcodeFormat: Decodable {}
extension PassJSON.TransitType: Decodable {}

struct PassJSONData: PassJSON.Properties, Decodable {
    let description: String
    let formatVersion = PassJSON.FormatVersion.v1
    let organizationName = "vapor-community"
    let passTypeIdentifier = PassData.typeIdentifier
    let serialNumber: String
    let teamIdentifier = "K6512ZA2S5"

    private let webServiceURL = "https://www.example.com/api/passes/"
    let authenticationToken: String
    private let logoText = "Vapor Community"
    private let sharingProhibited = true
    let backgroundColor = "rgb(207, 77, 243)"
    let foregroundColor = "rgb(255, 255, 255)"

    let barcodes = Barcode(message: "test")
    struct Barcode: PassJSON.Barcodes, Decodable {
        let format = PassJSON.BarcodeFormat.qr
        let message: String
        let messageEncoding = "iso-8859-1"

        enum CodingKeys: String, CodingKey {
            case format, message, messageEncoding
        }
    }

    let boardingPass = Boarding(transitType: .air)
    struct Boarding: PassJSON.BoardingPass, Decodable {
        let transitType: PassJSON.TransitType
        let headerFields: [PassField]
        let primaryFields: [PassField]
        let secondaryFields: [PassField]
        let auxiliaryFields: [PassField]
        let backFields: [PassField]

        struct PassField: PassJSON.PassFieldContent, Decodable {
            let key: String
            let label: String
            let value: String
        }

        init(transitType: PassJSON.TransitType) {
            self.headerFields = [.init(key: "header", label: "Header", value: "Header")]
            self.primaryFields = [.init(key: "primary", label: "Primary", value: "Primary")]
            self.secondaryFields = [.init(key: "secondary", label: "Secondary", value: "Secondary")]
            self.auxiliaryFields = [.init(key: "auxiliary", label: "Auxiliary", value: "Auxiliary")]
            self.backFields = [.init(key: "back", label: "Back", value: "Back")]
            self.transitType = transitType
        }
    }

    enum CodingKeys: String, CodingKey {
        case description
        case formatVersion
        case organizationName, passTypeIdentifier, serialNumber, teamIdentifier
        case webServiceURL, authenticationToken
        case logoText, sharingProhibited, backgroundColor, foregroundColor
        case barcodes, boardingPass
    }

    init(data: PassData, pass: Pass) {
        self.description = data.title
        self.serialNumber = pass.id!.uuidString
        self.authenticationToken = pass.authenticationToken
    }
}

// MARK: - PassDataMiddleware

struct PassDataMiddleware: AsyncModelMiddleware {
    private unowned let service: PassesService<PassData>

    init(service: PassesService<PassData>) {
        self.service = service
    }

    func create(model: PassData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = Pass(
            typeIdentifier: PassData.typeIdentifier,
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString()
        )
        try await pass.save(on: db)
        model.$pass.id = try pass.requireID()
        try await next.create(model, on: db)
    }

    func update(model: PassData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = try await model.$pass.get(on: db)
        pass.updatedAt = Date()
        try await pass.save(on: db)
        try await next.update(model, on: db)
        try await service.sendPushNotifications(for: model, on: db)
    }
}
