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
    ///   - signingFilesDirectory: The path of the directory where the signing files (`wwdrCertificate`, `pemCertificate`, `pemPrivateKey`) are located.
    ///   - wwdrCertificate: The name of Apple's WWDR.pem certificate as contained in `signingFilesDirectory` path. Defaults to `WWDR.pem`.
    ///   - pemCertificate: The name of the PEM Certificate for signing the pass as contained in `signingFilesDirectory` path. Defaults to `certificate.pem`.
    ///   - pemPrivateKey: The name of the PEM Certificate's private key for signing the pass as contained in `signingFilesDirectory` path. Defaults to `key.pem`.
    ///   - pemPrivateKeyPassword: The password to the private key file. If the key is not encrypted it must be `nil`. Defaults to `nil`.
    ///   - sslBinary: The location of the `openssl` command as a file path.
    ///   - pushRoutesMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    ///   - logger: The `Logger` to use.
    public init(
        app: Application,
        delegate: any OrdersDelegate,
        signingFilesDirectory: String,
        wwdrCertificate: String = "WWDR.pem",
        pemCertificate: String = "certificate.pem",
        pemPrivateKey: String = "key.pem",
        pemPrivateKeyPassword: String? = nil,
        sslBinary: String = "/usr/bin/openssl",
        pushRoutesMiddleware: (any Middleware)? = nil,
        logger: Logger? = nil
    ) throws {
        self.service = try .init(
            app: app,
            delegate: delegate,
            signingFilesDirectory: signingFilesDirectory,
            wwdrCertificate: wwdrCertificate,
            pemCertificate: pemCertificate,
            pemPrivateKey: pemPrivateKey,
            pemPrivateKeyPassword: pemPrivateKeyPassword,
            sslBinary: sslBinary,
            pushRoutesMiddleware: pushRoutesMiddleware,
            logger: logger
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
    ///   - typeIdentifier: The type identifier of the order.
    ///   - db: The `Database` to use.
    public func sendPushNotificationsForOrder(id: UUID, of typeIdentifier: String, on db: any Database) async throws {
        try await service.sendPushNotificationsForOrder(id: id, of: typeIdentifier, on: db)
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
