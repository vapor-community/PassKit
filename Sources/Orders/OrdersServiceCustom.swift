//
//  OrdersServiceCustom.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

import Vapor
import APNS
import VaporAPNS
import APNSCore
import Fluent
import NIOSSL
import PassKit
import ZIPFoundation
@_spi(CMS) import X509

/// Class to handle ``OrdersService``.
///
/// The generics should be passed in this order:
/// - Order Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public final class OrdersServiceCustom<O, D, R: OrdersRegistrationModel, E: ErrorLogModel>: Sendable where O == R.OrderType, D == R.DeviceType {
    private unowned let app: Application
    private unowned let delegate: any OrdersDelegate
    private let logger: Logger?
    
    /// Initializes the service and registers all the routes required for Apple Wallet to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to use in route handlers and APNs.
    ///   - delegate: The ``OrdersDelegate`` to use for order generation.
    ///   - pushRoutesMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    ///   - logger: The `Logger` to use.
    public init(
        app: Application,
        delegate: any OrdersDelegate,
        pushRoutesMiddleware: (any Middleware)? = nil,
        logger: Logger? = nil
    ) throws {
        self.app = app
        self.delegate = delegate
        self.logger = logger
        
        let privateKeyPath = URL(fileURLWithPath: delegate.pemPrivateKey, relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw OrdersError.pemPrivateKeyMissing
        }
        let pemPath = URL(fileURLWithPath: delegate.pemCertificate, relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        guard FileManager.default.fileExists(atPath: pemPath) else {
            throw OrdersError.pemCertificateMissing
        }
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

        let v1 = app.grouped("api", "orders", "v1")
        v1.get("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", use: { try await self.ordersForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })

        let v1auth = v1.grouped(AppleOrderMiddleware<O>())
        v1auth.post("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.registerDevice(req: $0) })
        v1auth.get("orders", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.latestVersionOfOrder(req: $0) })
        v1auth.delete("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.unregisterDevice(req: $0) })
        
        if let pushRoutesMiddleware {
            let pushAuth = v1.grouped(pushRoutesMiddleware)
            pushAuth.post("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.pushUpdatesForOrder(req: $0) })
            pushAuth.get("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.tokensForOrderUpdate(req: $0) })
        }
    }
}

// MARK: - API Routes
extension OrdersServiceCustom {
    func latestVersionOfOrder(req: Request) async throws -> Response {
        logger?.debug("Called latestVersionOfOrder")
        
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

// MARK: - Push Notifications
extension OrdersServiceCustom {
    /// Sends push notifications for a given order.
    ///
    /// - Parameters:
    ///   - id: The `UUID` of the order to send the notifications for.
    ///   - orderTypeIdentifier: The type identifier of the order.
    ///   - db: The `Database` to use.
    public func sendPushNotificationsForOrder(id: UUID, of orderTypeIdentifier: String, on db: any Database) async throws {
        let registrations = try await Self.registrationsForOrder(id: id, of: orderTypeIdentifier, on: db)
        for reg in registrations {
            let backgroundNotification = APNSBackgroundNotification(
                expiration: .immediately,
                topic: reg.order.orderTypeIdentifier,
                payload: PassKit.Payload()
            )
            do {
                try await app.apns.client(.init(string: "orders")).sendBackgroundNotification(
                    backgroundNotification,
                    deviceToken: reg.device.pushToken
                )
            } catch let error as APNSCore.APNSError where error.reason == .badDeviceToken {
                try await reg.device.delete(on: db)
                try await reg.delete(on: db)
            }
        }
    }

    /// Sends push notifications for a given order.
    /// 
    /// - Parameters:
    ///   - order: The order to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for order: O, on db: any Database) async throws {
        try await sendPushNotificationsForOrder(id: order.requireID(), of: order.orderTypeIdentifier, on: db)
    }
    
    /// Sends push notifications for a given order.
    /// 
    /// - Parameters:
    ///   - order: The order (as the `ParentProperty`) to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for order: ParentProperty<R, O>, on db: any Database) async throws {
        let value: O
        if let eagerLoaded = order.value {
            value = eagerLoaded
        } else {
            value = try await order.get(on: db)
        }
        try await sendPushNotifications(for: value, on: db)
    }

    static func registrationsForOrder(id: UUID, of orderTypeIdentifier: String, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property wrapper,
        // but there's not really any value to forcing that on them when we can just do the query ourselves like this.
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
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws -> Data {
        var manifest: [String: String] = [:]

        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath())
        try paths.forEach { relativePath in
            let file = URL(fileURLWithPath: relativePath, relativeTo: root)
            guard !file.hasDirectoryPath else { return }
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data)
            manifest[relativePath] = hash.map { "0\(String($0, radix: 16))".suffix(2) }.joined()
        }

        let data = try encoder.encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"))
        return data
    }

    private func generateSignatureFile(for manifest: Data, in root: URL) throws {
        // If the caller's delegate generated a file we don't have to do it.
        if delegate.generateSignatureFile(in: root) { return }

        // Swift Crypto doesn't support encrypted PEM private keys, so we have to use OpenSSL for that.
        if let password = delegate.pemPrivateKeyPassword {
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
                "-outform", "DER",
                "-passin", "pass:\(password)"
            ]

            try proc.run()
            proc.waitUntilExit()
            return
        }
        
        let signature = try CMS.sign(
            manifest,
            signatureAlgorithm: .sha256WithRSAEncryption,
            additionalIntermediateCertificates: [
                Certificate(
                    pemEncoded: String(
                        contentsOf: delegate.sslSigningFilesDirectory
                            .appending(path: delegate.wwdrCertificate)
                    )
                )
            ],
            certificate: Certificate(
                pemEncoded: String(
                    contentsOf: delegate.sslSigningFilesDirectory
                        .appending(path: delegate.pemCertificate)
                )
            ),
            privateKey: .init(
                pemEncoded: String(
                    contentsOf: delegate.sslSigningFilesDirectory
                        .appending(path: delegate.pemPrivateKey)
                )
            ),
            signingTime: Date()
        )
        
        try Data(signature).write(to: root.appendingPathComponent("signature"))
    }

    /// Generates the order content bundle for a given order.
    ///
    /// - Parameters:
    ///   - order: The order to generate the content for.
    ///   - db: The `Database` to use.
    /// - Returns: The generated order content as `Data`.
    public func generateOrderContent(for order: O, on db: any Database) async throws -> Data {
        let src = try await delegate.template(for: order, db: db)
        guard (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else {
            throw OrdersError.templateNotDirectory
        }

        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.copyItem(at: src, to: root)
        defer { _ = try? FileManager.default.removeItem(at: root) }

        let encoder = JSONEncoder()
        try await self.delegate.encode(order: order, db: db, encoder: encoder)
            .write(to: root.appendingPathComponent("order.json"))
        
        try self.generateSignatureFile(
            for: Self.generateManifestFile(using: encoder, in: root),
            in: root
        )
        
        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).order")
        try FileManager.default.zipItem(at: root, to: zipFile, shouldKeepParent: false)
        defer { _ = try? FileManager.default.removeItem(at: zipFile) }
        
        return try Data(contentsOf: zipFile)
    }
}
