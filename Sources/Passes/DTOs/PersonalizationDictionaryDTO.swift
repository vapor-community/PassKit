import Vapor

struct PersonalizationDictionaryDTO: Content {
    let personalizationToken: String
    let requiredPersonalizationInfo: RequiredPersonalizationInfo

    struct RequiredPersonalizationInfo: Content {
        let emailAddress: String?
        let familyName: String?
        let fullName: String?
        let givenName: String?
        let isoCountryCode: String?
        let phoneNumber: String?
        let postalCode: String?

        enum CodingKeys: String, CodingKey {
            case emailAddress
            case familyName
            case fullName
            case givenName
            case isoCountryCode = "ISOCountryCode"
            case phoneNumber
            case postalCode
        }
    }
}
