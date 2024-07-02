//
//  OrdersServiceCustom.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

@preconcurrency import Vapor
import APNS
import VaporAPNS
@preconcurrency import APNSCore
import Fluent
import NIOSSL
import PassKit

/// Class to handle `OrdersService`.
///
/// The generics should be passed in this order:
/// - Order Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public final class OrdersServiceCustom<O, D, R: OrdersRegistrationModel, E: ErrorLogModel>: Sendable where O == R.OrderType, D == R.DeviceType {
    public unowned let delegate: any OrdersDelegate
    private unowned let app: Application
    
    private let v1: any RoutesBuilder
    private let logger: Logger?
    
    public init(app: Application, delegate: any OrdersDelegate, logger: Logger? = nil) {
        self.delegate = delegate
        self.logger = logger
        self.app = app
        
        v1 = app.grouped("api", "orders", "v1")
    }

    /// Registers all the routes required for Apple Wallet to work.
    public func registerRoutes() {
        v1.get("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", use: { try await self.ordersForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })
        
        let v1auth = v1.grouped(AppleOrderMiddleware<O>())
        
        v1auth.post("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.registerDevice(req: $0) })
        v1auth.get("orders", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.latestVersionOfOrder(req: $0) })
        v1auth.delete("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.unregisterDevice(req: $0) })
    }

    /// Registers routes to send push notifications for updated orders.
    ///
    /// ### Example ###
    /// ```swift
    /// try ordersService.registerPushRoutes(middleware: SecretMiddleware(secret: "foo"))
    /// ```
    ///
    /// - Parameter middleware: The `Middleware` which will control authentication for the routes.
    /// - Throws: An error of type `OrdersError`
    public func registerPushRoutes(middleware: any Middleware) throws {
        let privateKeyPath = URL(
            fileURLWithPath: delegate.pemPrivateKey,
            relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        
        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw OrdersError.pemPrivateKeyMissing
        }

        let pemPath = URL(
            fileURLWithPath: delegate.pemCertificate,
            relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        
        guard FileManager.default.fileExists(atPath: pemPath) else {
            throw OrdersError.pemCertificateMissing
        }

        // Apple Wallet *only* works with the production APNs. You can't pass in `.sandbox` here.
        let apnsConfig: APNSClientConfiguration
        if let pwd = delegate.pemPrivateKeyPassword {
            apnsConfig = APNSClientConfiguration(
                authenticationMethod: try .tls(
                    privateKey: .privateKey(
                        NIOSSLPrivateKey(file: privateKeyPath, format: .pem) { closure in
                            closure(pwd.utf8)
                        }),
                    certificateChain: NIOSSLCertificate.fromPEMFile(pemPath).map { .certificate($0) }
                ),
                environment: .production
            )
        } else {
            apnsConfig = APNSClientConfiguration(
                authenticationMethod: try .tls(
                    privateKey: .file(privateKeyPath),
                    certificateChain: NIOSSLCertificate.fromPEMFile(pemPath).map { .certificate($0) }
                ),
                environment: .production
            )
        }
        app.apns.containers.use(
            apnsConfig,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .init(string: "orders"),
            isDefault: false
        )

        let pushAuth = v1.grouped(middleware)
        
        pushAuth.post("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.pushUpdatesForOrder(req: $0) })
        pushAuth.get("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.tokensForOrderUpdate(req: $0) })
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

        var ifModifiedSince = Date.now
        
        if let header = req.headers[.ifModifiedSince].first, let ims = dateFormatter.date(from: header){
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

        let data = try await self.generateOrderContent(for: order, on: req.db)
        let body = Response.Body(data: data)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.order")
        headers.add(name: .lastModified, value: dateFormatter.string(from: order.updatedAt ?? Date.distantPast))
        headers.add(name: .contentTransferEncoding, value: "binary")
        
        return Response(status: .ok, headers: headers, body: body)
    }

    func registerDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called register device")

        guard let orderIdentifier = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let pushToken: String
        do {
            let content = try req.content.decode(RegistrationDTO.self)
            pushToken = content.pushToken
        } catch {
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
            return try await Self.createRegistration(device: device, order: order, req: req)
        } else {
            let newDevice = D(deviceLibraryIdentifier: deviceIdentifier, pushToken: pushToken)
            try await newDevice.create(on: req.db)
            return try await Self.createRegistration(device: newDevice, order: order, req: req)
        }
    }

    private static func createRegistration(device: D, order: O, req: Request) async throws -> HTTPStatus {
        let r = try await R.for(
            deviceLibraryIdentifier: device.deviceLibraryIdentifier,
            orderTypeIdentifier: order.orderTypeIdentifier,
            on: req.db
        ).filter(O.self, \._$id == order.id!).first()

        if r != nil {
            // If the registration already exists, docs say to return a 200
            return .ok
        }

        let registration = R()
        registration._$order.id = order.id!
        registration._$device.id = device.id!

        try await registration.create(on: req.db)
        return .created
    }

    func ordersForDevice(req: Request) async throws -> OrdersForDeviceDTO {
        logger?.debug("Called ordersForDevice")

        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        var query = R.for(
            deviceLibraryIdentifier: deviceIdentifier,
            orderTypeIdentifier: orderTypeIdentifier,
            on: req.db)
        
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

        registrations.forEach { r in
            let order = r.order
            
            orderIdentifiers.append(order.id!.uuidString)
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

        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!

        guard let orderIdentifier = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        guard let r = try await R.for(
            deviceLibraryIdentifier: deviceIdentifier,
            orderTypeIdentifier: orderTypeIdentifier,
            on: req.db
        ).filter(O.self, \._$id == orderIdentifier).first()
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

        try await Self.sendPushNotificationsForOrder(id: id, of: orderTypeIdentifier, on: req.db, app: req.application)
        return .noContent
    }

    func tokensForOrderUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForOrderUpdate")
        
        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        
        let registrations = try await Self.registrationsForOrder(id: id, of: orderTypeIdentifier, on: req.db)
        return registrations.map { $0.device.pushToken }
    }
}

// MARK: - Push Notifications
extension OrdersServiceCustom {
    public static func sendPushNotificationsForOrder(id: UUID, of orderTypeIdentifier: String, on db: any Database, app: Application) async throws {
        let registrations = try await Self.registrationsForOrder(id: id, of: orderTypeIdentifier, on: db)
        for reg in registrations {
            let backgroundNotification = APNSBackgroundNotification(
                expiration: .immediately,
                topic: reg.order.orderTypeIdentifier,
                payload: EmptyPayload()
            )

            do {
                try await app.apns.client(.init(string: "orders"))
                    .sendBackgroundNotification(
                        backgroundNotification,
                        deviceToken: reg.device.pushToken
                    )
            } catch let error as APNSCore.APNSError where error.reason == .badDeviceToken {
                try await reg.device.delete(on: db)
                try await reg.delete(on: db)
            }
        }
    }

    public static func sendPushNotifications(for order: O, on db: any Database, app: Application) async throws {
        guard let id = order.id else {
            throw FluentError.idRequired
        }
        
        try await Self.sendPushNotificationsForOrder(id: id, of: order.orderTypeIdentifier, on: db, app: app)
    }
    
    public static func sendPushNotifications(for order: ParentProperty<R, O>, on db: any Database, app: Application) async throws {
        let value: O
        
        if let eagerLoaded = order.value {
            value = eagerLoaded
        } else {
            value = try await order.get(on: db)
        }
        
       try await sendPushNotifications(for: value, on: db, app: app)
    }

    private static func registrationsForOrder(id: UUID, of orderTypeIdentifier: String, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property
        // wrapper, but there's not really any value to forcing that on them when
        // we can just do the query ourselves like this.
        try await R.query(on: db)
            .join(parent: \._$order)
            .join(parent: \._$device)
            .with(\._$order)
            .with(\._$device)
            .filter(O.self, \._$orderTypeIdentifier == orderTypeIdentifier)
            .filter(O.self, \._$id == id)
            .all()
    }
}

// MARK: - order file generation
extension OrdersServiceCustom {
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
        var manifest: [String: String] = [:]
        
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath())
        try paths.forEach { relativePath in
            let file = URL(fileURLWithPath: relativePath, relativeTo: root)
            guard !file.hasDirectoryPath else {
                return
            }
            
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data)
            manifest[relativePath] = hash.map { "0\(String($0, radix: 16))".suffix(2) }.joined()
        }
        
        let encoded = try encoder.encode(manifest)
        try encoded.write(to: root.appendingPathComponent("manifest.json"))
    }

    private func generateSignatureFile(in root: URL) throws {
        if delegate.generateSignatureFile(in: root) {
            // If the caller's delegate generated a file we don't have to do it.
            return
        }

        let sslBinary = delegate.sslBinary

        guard FileManager.default.fileExists(atPath: sslBinary.unixPath()) else {
            throw OrdersError.opensslBinaryMissing
        }

        let proc = Process()
        proc.currentDirectoryURL = delegate.sslSigningFilesDirectory
        proc.executableURL = sslBinary
        
        proc.arguments = [
            "smime", "-binary", "-sign",
            "-certfile", delegate.wwdrCertificate,
            "-signer", delegate.pemCertificate,
            "-inkey", delegate.pemPrivateKey,
            "-in", root.appendingPathComponent("manifest.json").unixPath(),
            "-out", root.appendingPathComponent("signature").unixPath(),
            "-outform", "DER"
        ]
        
        if let pwd = delegate.pemPrivateKeyPassword {
            proc.arguments!.append(contentsOf: ["-passin", "pass:\(pwd)"])
        }
        
        try proc.run()
        
        proc.waitUntilExit()
    }

    private func zip(directory: URL, to: URL) throws {
        let zipBinary = delegate.zipBinary
        guard FileManager.default.fileExists(atPath: zipBinary.unixPath()) else {
            throw OrdersError.zipBinaryMissing
        }
        
        let proc = Process()
        proc.currentDirectoryURL = directory
        proc.executableURL = zipBinary
        
        proc.arguments = [ to.unixPath(), "-r", "-q", "." ]
        
        try proc.run()
        proc.waitUntilExit()
    }

    public func generateOrderContent(for order: O, on db: any Database) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let encoder = JSONEncoder()
        
        let src = try await delegate.template(for: order, db: db)
        guard (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else {
            throw OrdersError.templateNotDirectory
        }
        
        let encoded = try await self.delegate.encode(order: order, db: db, encoder: encoder)
        
        do {
            try FileManager.default.copyItem(at: src, to: root)
            
            defer {
                _ = try? FileManager.default.removeItem(at: root)
            }
            
            try encoded.write(to: root.appendingPathComponent("order.json"))
            
            try Self.generateManifestFile(using: encoder, in: root)
            try self.generateSignatureFile(in: root)
            
            try self.zip(directory: root, to: zipFile)
            
            defer {
                _ = try? FileManager.default.removeItem(at: zipFile)
            }
            
            return try Data(contentsOf: zipFile)
        } catch {
            throw error
        }
    }
}
