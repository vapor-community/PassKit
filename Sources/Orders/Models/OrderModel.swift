import FluentKit
import Foundation

/// Represents the `Model` that stores Waller orders.
///
/// Uses a UUID so people can't easily guess order IDs.
public protocol OrderModel: Model where IDValue == UUID {
    /// An identifier for the order type associated with the order.
    var typeIdentifier: String { get set }

    /// The date and time when the customer created the order.
    var createdAt: Date? { get set }

    /// The date and time when the order was last updated.
    var updatedAt: Date? { get set }

    /// The authentication token supplied to your web service.
    var authenticationToken: String { get set }

    /// The designated initializer.
    /// - Parameters:
    ///   - typeIdentifier: The order type identifier that’s registered with Apple.
    ///   - authenticationToken: The authentication token to use with the web service in the `webServiceURL` key.
    init(typeIdentifier: String, authenticationToken: String)
}

extension OrderModel {
    var _$id: ID<UUID> {
        guard let mirror = Mirror(reflecting: self).descendant("_id"),
            let id = mirror as? ID<UUID>
        else {
            fatalError("id property must be declared using @ID")
        }

        return id
    }

    var _$typeIdentifier: Field<String> {
        guard let mirror = Mirror(reflecting: self).descendant("_typeIdentifier"),
            let typeIdentifier = mirror as? Field<String>
        else {
            fatalError("typeIdentifier property must be declared using @Field")
        }

        return typeIdentifier
    }

    var _$updatedAt: Timestamp<DefaultTimestampFormat> {
        guard let mirror = Mirror(reflecting: self).descendant("_updatedAt"),
            let updatedAt = mirror as? Timestamp<DefaultTimestampFormat>
        else {
            fatalError("updatedAt property must be declared using @Timestamp(on: .update)")
        }

        return updatedAt
    }

    var _$authenticationToken: Field<String> {
        guard let mirror = Mirror(reflecting: self).descendant("_authenticationToken"),
            let authenticationToken = mirror as? Field<String>
        else {
            fatalError("authenticationToken property must be declared using @Field")
        }

        return authenticationToken
    }
}
