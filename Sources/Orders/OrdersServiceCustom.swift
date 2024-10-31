//
//  OrdersServiceCustom.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

import APNS
import APNSCore
import Fluent
import NIOSSL
import PassKit
import Vapor
import VaporAPNS
@_spi(CMS) import X509
import Zip

/// Class to handle ``OrdersService``.
///
/// The generics should be passed in this order:
/// - Order Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public final class OrdersServiceCustom<O, D, R: OrdersRegistrationModel, E: ErrorLogModel>: Sendable
where O == R.OrderType, D == R.DeviceType {
    private unowned let app: Application
    private unowned let delegate: any OrdersDelegate
    private let signingFilesDirectory: URL
    private let wwdrCertificate: String
    private let pemCertificate: String
    private let pemPrivateKey: String
    private let pemPrivateKeyPassword: String?
    private let sslBinary: URL
    private let logger: Logger?
    private let encoder = JSONEncoder()

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
        self.app = app
        self.delegate = delegate
        self.signingFilesDirectory = URL(fileURLWithPath: signingFilesDirectory, isDirectory: true)
        self.wwdrCertificate = wwdrCertificate
        self.pemCertificate = pemCertificate
        self.pemPrivateKey = pemPrivateKey
        self.pemPrivateKeyPassword = pemPrivateKeyPassword
        self.sslBinary = URL(fileURLWithPath: sslBinary)
        self.logger = logger

        let privateKeyPath = URL(fileURLWithPath: pemPrivateKey, relativeTo: self.signingFilesDirectory).path
        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw OrdersError.pemPrivateKeyMissing
        }
        let pemPath = URL(fileURLWithPath: pemCertificate, relativeTo: self.signingFilesDirectory).path
        guard FileManager.default.fileExists(atPath: pemPath) else {
            throw OrdersError.pemCertificateMissing
        }
        let apnsConfig: APNSClientConfiguration
        if let password = pemPrivateKeyPassword {
            apnsConfig = APNSClientConfiguration(
                authenticationMethod: try .tls(
                    privateKey: .privateKey(
                        NIOSSLPrivateKey(file: privateKeyPath, format: .pem) { passphraseCallback in
                            passphraseCallback(password.utf8)
                        }),
                    certificateChain: NIOSSLCertificate.fromPEMFile(pemPath).map {
                        .certificate($0)
                    }
                ),
                environment: .production
            )
        } else {
            apnsConfig = APNSClientConfiguration(
                authenticationMethod: try .tls(
                    privateKey: .privateKey(NIOSSLPrivateKey(file: privateKeyPath, format: .pem)),
                    certificateChain: NIOSSLCertificate.fromPEMFile(pemPath).map {
                        .certificate($0)
                    }
                ),
                environment: .production
            )
        }
        app.apns.containers.use(
            apnsConfig,
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: self.encoder,
            as: .init(string: "orders"),
            isDefault: false
        )

        let v1 = app.grouped("api", "orders", "v1")
        v1.get("devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", use: { try await self.ordersForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })

        let v1auth = v1.grouped(AppleOrderMiddleware<O>())
        v1auth.post(
            "devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier",
            use: { try await self.registerDevice(req: $0) }
        )
        v1auth.get("orders", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.latestVersionOfOrder(req: $0) })
        v1auth.delete(
            "devices", ":deviceIdentifier", "registrations", ":orderTypeIdentifier", ":orderIdentifier",
            use: { try await self.unregisterDevice(req: $0) }
        )

        if let pushRoutesMiddleware {
            let pushAuth = v1.grouped(pushRoutesMiddleware)
            pushAuth.post("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.pushUpdatesForOrder(req: $0) })
            pushAuth.get("push", ":orderTypeIdentifier", ":orderIdentifier", use: { try await self.tokensForOrderUpdate(req: $0) })
        }
    }
}

// MARK: - API Routes
extension OrdersServiceCustom {
    fileprivate func latestVersionOfOrder(req: Request) async throws -> Response {
        logger?.debug("Called latestVersionOfOrder")

        var ifModifiedSince: TimeInterval = 0
        if let header = req.headers[.ifModifiedSince].first, let ims = TimeInterval(header) {
            ifModifiedSince = ims
        }

        guard let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier"),
            let id = req.parameters.get("orderIdentifier", as: UUID.self)
        else {
            throw Abort(.badRequest)
        }
        guard
            let order = try await O.query(on: req.db)
                .filter(\._$id == id)
                .filter(\._$typeIdentifier == orderTypeIdentifier)
                .first()
        else {
            throw Abort(.notFound)
        }

        guard ifModifiedSince < order.updatedAt?.timeIntervalSince1970 ?? 0 else {
            throw Abort(.notModified)
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.order")
        headers.lastModified = HTTPHeaders.LastModified(order.updatedAt ?? Date.distantPast)
        headers.add(name: .contentTransferEncoding, value: "binary")
        return try await Response(
            status: .ok,
            headers: headers,
            body: Response.Body(data: self.generateOrderContent(for: order, on: req.db))
        )
    }

    fileprivate func registerDevice(req: Request) async throws -> HTTPStatus {
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
        guard
            let order = try await O.query(on: req.db)
                .filter(\._$id == orderIdentifier)
                .filter(\._$typeIdentifier == orderTypeIdentifier)
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

    private static func createRegistration(
        device: D, order: O, db: any Database
    ) async throws -> HTTPStatus {
        let r = try await R.for(
            deviceLibraryIdentifier: device.deviceLibraryIdentifier,
            typeIdentifier: order.typeIdentifier,
            on: db
        )
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

    fileprivate func ordersForDevice(req: Request) async throws -> OrdersForDeviceDTO {
        logger?.debug("Called ordersForDevice")

        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        var query = R.for(
            deviceLibraryIdentifier: deviceIdentifier,
            typeIdentifier: orderTypeIdentifier,
            on: req.db
        )
        if let since: TimeInterval = req.query["ordersModifiedSince"] {
            let when = Date(timeIntervalSince1970: since)
            query = query.filter(O.self, \._$updatedAt > when)
        }

        let registrations = try await query.all()
        guard !registrations.isEmpty else {
            throw Abort(.noContent)
        }

        var orderIdentifiers: [String] = []
        var maxDate = Date.distantPast
        for registration in registrations {
            let order = registration.order
            try orderIdentifiers.append(order.requireID().uuidString)
            if let updatedAt = order.updatedAt, updatedAt > maxDate {
                maxDate = updatedAt
            }
        }

        return OrdersForDeviceDTO(with: orderIdentifiers, maxDate: maxDate)
    }

    fileprivate func logError(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called logError")

        let body: ErrorLogDTO
        do {
            body = try req.content.decode(ErrorLogDTO.self)
        } catch {
            throw Abort(.badRequest)
        }

        guard !body.logs.isEmpty else {
            throw Abort(.badRequest)
        }

        try await body.logs.map(E.init(message:)).create(on: req.db)
        return .ok
    }

    fileprivate func unregisterDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called unregisterDevice")

        guard let orderIdentifier = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        guard
            let r = try await R.for(
                deviceLibraryIdentifier: deviceIdentifier,
                typeIdentifier: orderTypeIdentifier,
                on: req.db
            )
            .filter(O.self, \._$id == orderIdentifier)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await r.delete(on: req.db)
        return .ok
    }

    // MARK: - Push Routes
    fileprivate func pushUpdatesForOrder(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called pushUpdatesForOrder")

        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!

        try await sendPushNotificationsForOrder(id: id, of: orderTypeIdentifier, on: req.db)
        return .noContent
    }

    fileprivate func tokensForOrderUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForOrderUpdate")

        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let orderTypeIdentifier = req.parameters.get("orderTypeIdentifier")!

        return try await Self.registrationsForOrder(id: id, of: orderTypeIdentifier, on: req.db).map { $0.device.pushToken }
    }
}

// MARK: - Push Notifications
extension OrdersServiceCustom {
    /// Sends push notifications for a given order.
    ///
    /// - Parameters:
    ///   - id: The `UUID` of the order to send the notifications for.
    ///   - typeIdentifier: The type identifier of the order.
    ///   - db: The `Database` to use.
    public func sendPushNotificationsForOrder(id: UUID, of typeIdentifier: String, on db: any Database) async throws {
        let registrations = try await Self.registrationsForOrder(id: id, of: typeIdentifier, on: db)
        for reg in registrations {
            let backgroundNotification = APNSBackgroundNotification(
                expiration: .immediately,
                topic: reg.order.typeIdentifier,
                payload: EmptyPayload()
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
        try await sendPushNotificationsForOrder(id: order.requireID(), of: order.typeIdentifier, on: db)
    }

    private static func registrationsForOrder(id: UUID, of typeIdentifier: String, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property wrapper,
        // but there's not really any value to forcing that on them when we can just do the query ourselves like this.
        try await R.query(on: db)
            .join(parent: \._$order)
            .join(parent: \._$device)
            .with(\._$order)
            .with(\._$device)
            .filter(O.self, \._$typeIdentifier == typeIdentifier)
            .filter(O.self, \._$id == id)
            .all()
    }
}

// MARK: - order file generation
extension OrdersServiceCustom {
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws -> Data {
        var manifest: [String: String] = [:]
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        for relativePath in paths {
            let file = URL(fileURLWithPath: relativePath, relativeTo: root)
            guard !file.hasDirectoryPath else { continue }
            manifest[relativePath] = try SHA256.hash(data: Data(contentsOf: file)).hex
        }
        // Write the manifest file to the root directory
        // and return the data for using it in signing.
        let data = try encoder.encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"))
        return data
    }

    private func generateSignatureFile(for manifest: Data, in root: URL) throws {
        // If the caller's delegate generated a file we don't have to do it.
        if delegate.generateSignatureFile(in: root) { return }

        // Swift Crypto doesn't support encrypted PEM private keys, so we have to use OpenSSL for that.
        if let password = self.pemPrivateKeyPassword {
            let sslBinary = self.sslBinary
            guard FileManager.default.fileExists(atPath: sslBinary.path) else {
                throw OrdersError.opensslBinaryMissing
            }

            let proc = Process()
            proc.currentDirectoryURL = self.signingFilesDirectory
            proc.executableURL = sslBinary
            proc.arguments = [
                "smime", "-binary", "-sign",
                "-certfile", self.wwdrCertificate,
                "-signer", self.pemCertificate,
                "-inkey", self.pemPrivateKey,
                "-in", root.appendingPathComponent("manifest.json").path,
                "-out", root.appendingPathComponent("signature").path,
                "-outform", "DER",
                "-passin", "pass:\(password)",
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
                        contentsOf: self.signingFilesDirectory
                            .appendingPathComponent(self.wwdrCertificate)
                    )
                )
            ],
            certificate: Certificate(
                pemEncoded: String(
                    contentsOf: self.signingFilesDirectory
                        .appendingPathComponent(self.pemCertificate)
                )
            ),
            privateKey: .init(
                pemEncoded: String(
                    contentsOf: self.signingFilesDirectory
                        .appendingPathComponent(self.pemPrivateKey)
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
        let templateDirectory = try await URL(fileURLWithPath: delegate.template(for: order, db: db), isDirectory: true)
        guard
            (try? templateDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        else {
            throw OrdersError.templateNotDirectory
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: templateDirectory, to: root)
        defer { _ = try? FileManager.default.removeItem(at: root) }

        try await self.delegate.encode(order: order, db: db, encoder: self.encoder)
            .write(to: root.appendingPathComponent("order.json"))

        try self.generateSignatureFile(for: Self.generateManifestFile(using: self.encoder, in: root), in: root)

        var files = try FileManager.default.contentsOfDirectory(at: templateDirectory, includingPropertiesForKeys: nil)
        files.append(URL(fileURLWithPath: "order.json", relativeTo: root))
        files.append(URL(fileURLWithPath: "manifest.json", relativeTo: root))
        files.append(URL(fileURLWithPath: "signature", relativeTo: root))
        return try Data(contentsOf: Zip.quickZipFiles(files, fileName: UUID().uuidString))
    }
}
