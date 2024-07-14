//
//  Orders+Vapor.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 14/07/24.
//

import Vapor
import Fluent
import PassKit

extension OrdersService {
    /// Registers all the routes required for Wallet orders to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to setup the routes.
    ///   - pushMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    public func registerRoutes(app: Application, pushMiddleware: (any Middleware)? = nil) {
        service.registerRoutes(app: app, pushMiddleware: pushMiddleware)
    }
}

extension OrdersServiceCustom {
    /// Registers all the routes required for Apple Wallet to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to setup the routes.
    ///   - pushMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    public func registerRoutes(app: Application, pushMiddleware: (any Middleware)? = nil) {
        let v1 = app.grouped("api", "orders", "v1")
        v1.get("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", use: { try await self.ordersForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })

        let v1auth = v1.grouped(AppleOrderMiddleware<O>())
        v1auth.post("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.registerDevice(req: $0) })
        v1auth.get("orders", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.latestVersionOfOrder(req: $0) })
        v1auth.delete("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.unregisterDevice(req: $0) })
        
        if let pushMiddleware {
            let pushAuth = v1.grouped(pushMiddleware)
            pushAuth.post("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.pushUpdatesForOrder(req: $0) })
            pushAuth.get("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.tokensForOrderUpdate(req: $0) })
        }
    }
}

// MARK: - API Routes
extension OrdersServiceCustom {
    func latestVersionOfOrder(req: Request) async throws -> Response {
        logger?.debug("Called latestVersionOfOrder")

        guard FileManager.default.fileExists(atPath: delegate.zipBinary.unixPath()) else {
            throw Abort(.internalServerError, suggestedFixes: ["Provide full path to zip command"])
        }
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = .withInternetDateTime
        var ifModifiedSince = Date.distantPast
        if let header = req.headers[.ifModifiedSince].first, let ims = dateFormatter.date(from: header) {
            ifModifiedSince = ims
        }

        guard let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier"),
            let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
                throw Abort(.badRequest)
        }
        guard let order = try await O.query(on: req.db)
            .filter(\._$id == id)
            .filter(\._$orderTypeIdentifier == orderTypeIdentifier)
            .first()
        else {
            throw Abort(.notFound)
        }

        guard ifModifiedSince < order.updatedAt ?? Date.distantPast else {
            throw Abort(.notModified)
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.order")
        headers.add(name: .lastModified, value: dateFormatter.string(from: order.updatedAt ?? Date.distantPast))
        headers.add(name: .contentTransferEncoding, value: "binary")
        return try await Response(
            status: .ok,
            headers: headers,
            body: Response.Body(data: self.generateOrderContent(for: order, on: req.db))
        )
    }

    func registerDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called register device")

        let pushToken: String
        do {
            pushToken = try req.content.decode(RegistrationDTO.self).pushToken
        } catch {
            throw Abort(.badRequest)
        }

        guard let orderIdentifier = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!
        guard let order = try await O.query(on: req.db)
            .filter(\._$id == orderIdentifier)
            .filter(\._$orderTypeIdentifier == orderTypeIdentifier)
            .first()
        else {
            throw Abort(.notFound)
        }

        let device = try await D.query(on: req.db)
            .filter(\._$deviceLibraryIdentifier == deviceIdentifier)
            .filter(\._$pushToken == pushToken)
            .first()
        if let device = device {
            return try await Self.createRegistration(device: device, order: order, db: req.db)
        } else {
            let newDevice = D(deviceLibraryIdentifier: deviceIdentifier, pushToken: pushToken)
            try await newDevice.create(on: req.db)
            return try await Self.createRegistration(device: newDevice, order: order, db: req.db)
        }
    }

    private static func createRegistration(device: D, order: O, db: any Database) async throws -> HTTPStatus {
        let r = try await R.for(deviceLibraryIdentifier: device.deviceLibraryIdentifier, orderTypeIdentifier: order.orderTypeIdentifier, on: db)
            .filter(O.self, \._$id == order.requireID())
            .first()
        // If the registration already exists, docs say to return 200 OK
        if r != nil { return .ok }

        let registration = R()
        registration._$order.id = try order.requireID()
        registration._$device.id = try device.requireID()
        try await registration.create(on: db)
        return .created
    }

    func ordersForDevice(req: Request) async throws -> OrdersForDeviceDTO {
        logger?.debug("Called ordersForDevice")

        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        var query = R.for(deviceLibraryIdentifier: deviceIdentifier, orderTypeIdentifier: orderTypeIdentifier, on: req.db)
        if let since: String = req.query["ordersModifiedSince"] {
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = .withInternetDateTime
            let when = dateFormatter.date(from: since) ?? Date.distantPast
            query = query.filter(O.self, \._$updatedAt > when)
        }

        let registrations = try await query.all()
        guard !registrations.isEmpty else {
            throw Abort(.noContent)
        }

        var orderIdentifiers: [String] = []
        var maxDate = Date.distantPast
        try registrations.forEach { r in
            let order = r.order
            try orderIdentifiers.append(order.requireID().uuidString)
            if let updatedAt = order.updatedAt, updatedAt > maxDate {
                maxDate = updatedAt
            }
        }

        return OrdersForDeviceDTO(with: orderIdentifiers, maxDate: maxDate)
    }

    func logError(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called logError")

        let body: ErrorLogDTO
        do {
            body = try req.content.decode(ErrorLogDTO.self)
        } catch {
            throw Abort(.badRequest)
        }

        guard body.logs.isEmpty == false else {
            throw Abort(.badRequest)
        }

        try await body.logs.map(E.init(message:)).create(on: req.db)
        return .ok
    }

    func unregisterDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called unregisterDevice")

        guard let orderIdentifier = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        guard let r = try await R.for(deviceLibraryIdentifier: deviceIdentifier, orderTypeIdentifier: orderTypeIdentifier, on: req.db)
            .filter(O.self, \._$id == orderIdentifier)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await r.delete(on: req.db)
        return .ok
    }

    // MARK: - Push Routes
    func pushUpdatesForOrder(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called pushUpdatesForOrder")

        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!

        try await sendPushNotificationsForOrder(id: id, of: orderTypeIdentifier, on: req.db)
        return .noContent
    }

    func tokensForOrderUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForOrderUpdate")

        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        
        return try await Self.registrationsForOrder(id: id, of: orderTypeIdentifier, on: req.db)
            .map { $0.device.pushToken }
    }
}