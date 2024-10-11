//
//  OrdersService.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

import FluentKit
import Vapor

/// The main class that handles Wallet orders.
public final class OrdersService: Sendable {
    private let service: OrdersServiceCustom<Order, OrdersDevice, OrdersRegistration, OrdersErrorLog>

    /// Initializes the service and registers all the routes required for Apple Wallet to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to use in route handlers and APNs.
    ///   - delegate: The ``OrdersDelegate`` to use for order generation.
    ///   - pushRoutesMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    ///   - logger: The `Logger` to use.
    public init(
        app: Application, delegate: any OrdersDelegate,
        pushRoutesMiddleware: (any Middleware)? = nil, logger: Logger? = nil
    ) throws {
        service = try .init(
            app: app, delegate: delegate, pushRoutesMiddleware: pushRoutesMiddleware, logger: logger
        )
    }

    /// Generates the order content bundle for a given order.
    ///
    /// - Parameters:
    ///   - order: The order to generate the content for.
    ///   - db: The `Database` to use.
    /// - Returns: The generated order content.
    public func generateOrderContent(for order: Order, on db: any Database) async throws -> Data {
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

    /// Sends push notifications for a given order.
    ///
    /// - Parameters:
    ///   - id: The `UUID` of the order to send the notifications for.
    ///   - orderTypeIdentifier: The type identifier of the order.
    ///   - db: The `Database` to use.
    public func sendPushNotificationsForOrder(
        id: UUID, of orderTypeIdentifier: String, on db: any Database
    ) async throws {
        try await service.sendPushNotificationsForOrder(id: id, of: orderTypeIdentifier, on: db)
    }

    /// Sends push notifications for a given order.
    ///
    /// - Parameters:
    ///   - order: The order to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for order: Order, on db: any Database) async throws {
        try await service.sendPushNotifications(for: order, on: db)
    }
}
