import Passes

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
