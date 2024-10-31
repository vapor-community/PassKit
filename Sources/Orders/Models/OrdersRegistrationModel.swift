//
//  OrdersRegistrationModel.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import FluentKit
import PassKit

/// Represents the `Model` that stores orders registrations.
public protocol OrdersRegistrationModel: Model where IDValue == Int {
    associatedtype OrderType: OrderModel
    associatedtype DeviceType: DeviceModel

    /// The device for this registration.
    var device: DeviceType { get set }

    /// The order for this registration.
    var order: OrderType { get set }
}

extension OrdersRegistrationModel {
    var _$device: Parent<DeviceType> {
        guard let mirror = Mirror(reflecting: self).descendant("_device"),
            let device = mirror as? Parent<DeviceType>
        else {
            fatalError("device property must be declared using @Parent")
        }

        return device
    }

    var _$order: Parent<OrderType> {
        guard let mirror = Mirror(reflecting: self).descendant("_order"),
            let order = mirror as? Parent<OrderType>
        else {
            fatalError("order property must be declared using @Parent")
        }

        return order
    }

    static func `for`(deviceLibraryIdentifier: String, typeIdentifier: String, on db: any Database) -> QueryBuilder<Self> {
        Self.query(on: db)
            .join(parent: \._$order)
            .join(parent: \._$device)
            .with(\._$order)
            .with(\._$device)
            .filter(OrderType.self, \._$typeIdentifier == typeIdentifier)
            .filter(DeviceType.self, \._$deviceLibraryIdentifier == deviceLibraryIdentifier)
    }
}
