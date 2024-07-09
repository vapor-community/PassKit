//
//  PersonalizationJSON.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 04/07/24.
//

/// The structure of a `personalization.json` file.
///
/// This file specifies the personal information requested by the signup form.
/// It also contains a description of the program and (optionally) the program’s terms and conditions.
public struct PersonalizationJSON {
    /// A protocol that defines the structure of a `personalization.json` file.
    ///
    /// > Tip: See the [documentation](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/PassPersonalization.html#//apple_ref/doc/uid/TP40012195-CH12-SW2) to understand the keys.
    public protocol Properties: Encodable {
        /// The contents of this array define the data requested from the user.
        ///
        /// The signup form’s fields are generated based on these keys.
        var requiredPersonalizationFields: [PersonalizationField] { get }

        /// A brief description of the program.
        ///
        /// This is displayed on the signup sheet, under the personalization logo.
        var description: String { get }
    }
}

extension PersonalizationJSON {
    /// Personal information requested by the signup form.
    public enum PersonalizationField: String, Encodable {
        /// Prompts the user for their name.
        ///
        /// `fullName`, `givenName`, and `familyName` are submitted in the personalize request.
        case name = "PKPassPersonalizationFieldName"

        /// Prompts the user for their postal code.
        ///
        /// `postalCode` and `ISOCountryCode` are submitted in the personalize request.
        case postalCode = "PKPassPersonalizationFieldPostalCode"

        /// Prompts the user for their email address.
        ///
        /// `emailAddress` is submitted in the personalize request.
        case emailAddress = "PKPassPersonalizationFieldEmailAddress"

        /// Prompts the user for their phone number.
        ///
        /// `phoneNumber` is submitted in the personalize request.
        case phoneNumber = "PKPassPersonalizationFieldPhoneNumber"
    }
}