//
//  OrderDataModel.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import FluentKit

/// Represents the `Model` that stores custom app data associated to Wallet orders.
public protocol OrderDataModel: Model {
    associatedtype OrderType: OrderModel

    /// The foreign key to the order table
    var order: OrderType { get set }
}

internal extension OrderDataModel {
    var _$order: Parent<OrderType> {
        guard let mirror = Mirror(reflecting: self).descendant("_order"),
            let order = mirror as? Parent<OrderType> else {
                fatalError("order property must be declared using @Parent")
        }

        return order
    }
}