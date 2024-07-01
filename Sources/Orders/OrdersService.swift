//
//  OrdersService.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

import Vapor
import FluentKit

/// The main class that handles Wallet orders.
public final class OrdersService: Sendable {
    private let service: OrdersServiceCustom<Order, OrdersDevice, OrdersRegistration, OrdersErrorLog>
    
    public init(app: Application, delegate: any OrdersDelegate, logger: Logger? = nil) {
        service = .init(app: app, delegate: delegate, logger: logger)
    }

    /// Generates the order content bundle for a given order.
    ///
    /// - Parameters:
    ///   - order: The order to generate the content for.
    ///   - db: The `Database` to use.
    /// - Returns: The generated order content.
    public func generatePassContent(for order: Order, on db: any Database) async throws -> Data {
        try await service.generateOrderContent(for: order, on: db)
    }

    /// Adds the migrations for Wallet orders models.
    ///
    /// - Parameter migrations: The `Migrations` object to add the migrations to.
    public static func register(migrations: Migrations) {
        migrations.add(Order())
        migrations.add(OrdersDevice())
        migrations.add(OrdersRegistration())
        migrations.add(OrdersErrorLog())
    }
}