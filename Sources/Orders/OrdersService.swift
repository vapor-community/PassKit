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
    
    /// Initializes the service.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to use in route handlers and APNs.
    ///   - delegate: The ``OrdersDelegate`` to use for order generation.
    ///   - logger: The `Logger` to use.
    public init(app: Application, delegate: any OrdersDelegate, logger: Logger? = nil) {
        service = .init(app: app, delegate: delegate, logger: logger)
    }

    /// Registers all the routes required for Wallet orders to work.
    public func registerRoutes() {
        service.registerRoutes()
    }

    /// Registers routes to send push notifications to updated orders.
    ///
    /// - Parameter middleware: The `Middleware` which will control authentication for the routes.
    public func registerPushRoutes(middleware: any Middleware) throws {
        try service.registerPushRoutes(middleware: middleware)
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
    ///   - app: The `Application` to use.
    public static func sendPushNotificationsForOrder(id: UUID, of orderTypeIdentifier: String, on db: any Database, app: Application) async throws {
        try await OrdersServiceCustom<Order, OrdersDevice, OrdersRegistration, OrdersErrorLog>.sendPushNotificationsForOrder(id: id, of: orderTypeIdentifier, on: db, app: app)
    }
    
    /// Sends push notifications for a given order.
    /// 
    /// - Parameters:
    ///   - order: The order to send the notifications for.
    ///   - db: The `Database` to use.
    ///   - app: The `Application` to use.
    public static func sendPushNotifications(for order: Order, on db: any Database, app: Application) async throws {
        try await OrdersServiceCustom<Order, OrdersDevice, OrdersRegistration, OrdersErrorLog>.sendPushNotifications(for: order, on: db, app: app)
    }
    
    /// Sends push notifications for a given order.
    /// 
    /// - Parameters:
    ///   - order: The order (as the `ParentProperty`) to send the notifications for.
    ///   - db: The `Database` to use.
    ///   - app: The `Application` to use.
    public static func sendPushNotifications(for order: ParentProperty<OrdersRegistration, Order>, on db: any Database, app: Application) async throws {
        try await OrdersServiceCustom<Order, OrdersDevice, OrdersRegistration, OrdersErrorLog>.sendPushNotifications(for: order, on: db, app: app)
    }
}
