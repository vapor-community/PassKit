//
//  PersonalizationDictionaryDTO.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 04/07/24.
//

import Vapor

struct PersonalizationDictionaryDTO: Content {
    let personalizationToken: String
    let requiredPersonalizationInfo: RequiredPersonalizationInfo

    struct RequiredPersonalizationInfo: Content {
        let emailAddress: String?
        let familyName: String?
        let fullName: String?
        let givenName: String?
        let ISOCountryCode: String?
        let phoneNumber: String?
        let postalCode: String?
    }
}