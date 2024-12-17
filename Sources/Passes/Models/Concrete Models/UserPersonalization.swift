import FluentKit

/// The `Model` that stores user personalization info.
final public class UserPersonalization: UserPersonalizationModel, @unchecked Sendable {
    /// The schema name of the user personalization model.
    public static let schema = UserPersonalization.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    /// The user’s full name, as entered by the user.
    @OptionalField(key: UserPersonalization.FieldKeys.fullName)
    public var fullName: String?

    /// The user’s given name, parsed from the full name.
    ///
    /// This is the name bestowed upon an individual to differentiate them from other members of a group that share a family name (for example, “John”).
    /// In some locales, this is also known as a first name or forename.
    @OptionalField(key: UserPersonalization.FieldKeys.givenName)
    public var givenName: String?

    /// The user’s family name, parsed from the full name.
    ///
    /// This is the name bestowed upon an individual to denote membership in a group or family (for example, “Appleseed”).
    @OptionalField(key: UserPersonalization.FieldKeys.familyName)
    public var familyName: String?

    /// The email address, as entered by the user.
    @OptionalField(key: UserPersonalization.FieldKeys.emailAddress)
    public var emailAddress: String?

    /// The postal code, as entered by the user.
    @OptionalField(key: UserPersonalization.FieldKeys.postalCode)
    public var postalCode: String?

    /// The user’s ISO country code.
    ///
    /// This key is only included when the system can deduce the country code.
    @OptionalField(key: UserPersonalization.FieldKeys.isoCountryCode)
    public var isoCountryCode: String?

    /// The phone number, as entered by the user.
    @OptionalField(key: UserPersonalization.FieldKeys.phoneNumber)
    public var phoneNumber: String?

    public init() {}
}

extension UserPersonalization: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(UserPersonalization.FieldKeys.fullName, .string)
            .field(UserPersonalization.FieldKeys.givenName, .string)
            .field(UserPersonalization.FieldKeys.familyName, .string)
            .field(UserPersonalization.FieldKeys.emailAddress, .string)
            .field(UserPersonalization.FieldKeys.postalCode, .string)
            .field(UserPersonalization.FieldKeys.isoCountryCode, .string)
            .field(UserPersonalization.FieldKeys.phoneNumber, .string)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension UserPersonalization {
    enum FieldKeys {
        static let schemaName = "user_personalization_info"
        static let fullName = FieldKey(stringLiteral: "full_name")
        static let givenName = FieldKey(stringLiteral: "given_name")
        static let familyName = FieldKey(stringLiteral: "family_name")
        static let emailAddress = FieldKey(stringLiteral: "email_address")
        static let postalCode = FieldKey(stringLiteral: "postal_code")
        static let isoCountryCode = FieldKey(stringLiteral: "iso_country_code")
        static let phoneNumber = FieldKey(stringLiteral: "phone_number")
    }
}
