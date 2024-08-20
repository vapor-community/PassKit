//
//  OrderModel.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import Foundation
import FluentKit

/// Represents the `Model` that stores Waller orders.
///
/// Uses a UUID so people can't easily guess order IDs.
public protocol OrderModel: Model where IDValue == UUID {
    /// An identifier for the order type associated with the order.
    var orderTypeIdentifier: String { get set }

    /// The date and time when the customer created the order.
    var createdAt: Date? { get set }
    
    /// The date and time when the order was last updated.
    var updatedAt: Date? { get set }

    /// The authentication token supplied to your web service.
    var authenticationToken: String { get set }
}

internal extension OrderModel {
    var _$id: ID<UUID> {
        guard let mirror = Mirror(reflecting: self).descendant("_id"),
            let id = mirror as? ID<UUID> else {
                fatalError("id property must be declared using @ID")
        }
        
        return id
    }
    
    var _$orderTypeIdentifier: Field<String> {
        guard let mirror = Mirror(reflecting: self).descendant("_orderTypeIdentifier"),
            let orderTypeIdentifier = mirror as? Field<String> else {
                fatalError("orderTypeIdentifier property must be declared using @Field")
        }
        
        return orderTypeIdentifier
    }
    
    var _$updatedAt: Timestamp<DefaultTimestampFormat> {
        guard let mirror = Mirror(reflecting: self).descendant("_updatedAt"),
            let updatedAt = mirror as? Timestamp<DefaultTimestampFormat> else {
                fatalError("updatedAt property must be declared using @Timestamp(on: .update)")
        }
        
        return updatedAt
    }

    var _$authenticationToken: Field<String> {
        guard let mirror = Mirror(reflecting: self).descendant("_authenticationToken"),
            let authenticationToken = mirror as? Field<String> else {
                fatalError("authenticationToken property must be declared using @Field")
        }
        
        return authenticationToken
    }
}
