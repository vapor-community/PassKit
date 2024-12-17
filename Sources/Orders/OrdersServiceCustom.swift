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
/// - Order Data Model
/// - Order Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public final class OrdersServiceCustom<OD: OrderDataModel, O, D, R: OrdersRegistrationModel, E: ErrorLogModel>: Sendable
where O == OD.OrderType, O == R.OrderType, D == R.DeviceType {
    private unowned let app: Application
    private let logger: Logger?

    private let pemWWDRCertificate: String
    private let pemCertificate: String
    private let pemPrivateKey: String
    private let pemPrivateKeyPassword: String?
    private let openSSLURL: URL

    private let encoder = JSONEncoder()

    /// Initializes the service and registers all the routes required for Apple Wallet to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to use in route handlers and APNs.
    ///   - pushRoutesMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    ///   - logger: The `Logger` to use.
    ///   - pemWWDRCertificate: Apple's WWDR.pem certificate in PEM format.
    ///   - pemCertificate: The PEM Certificate for signing orders.
    ///   - pemPrivateKey: The PEM Certificate's private key for signing orders.
    ///   - pemPrivateKeyPassword: The password to the private key. If the key is not encrypted it must be `nil`. Defaults to `nil`.
    ///   - openSSLPath: The location of the `openssl` command as a file path.
    public init(
        app: Application,
        pushRoutesMiddleware: (any Middleware)? = nil,
        logger: Logger? = nil,
        pemWWDRCertificate: String,
        pemCertificate: String,
        pemPrivateKey: String,
        pemPrivateKeyPassword: String? = nil,
        openSSLPath: String = "/usr/bin/openssl"
    ) throws {
        self.app = app
        self.logger = logger

        self.pemWWDRCertificate = pemWWDRCertificate
        self.pemCertificate = pemCertificate
        self.pemPrivateKey = pemPrivateKey
        self.pemPrivateKeyPassword = pemPrivateKeyPassword
        self.openSSLURL = URL(fileURLWithPath: openSSLPath)

        let privateKeyBytes = pemPrivateKey.data(using: .utf8)!.map { UInt8($0) }
        let certificateBytes = pemCertificate.data(using: .utf8)!.map { UInt8($0) }
        let apnsConfig: APNSClientConfiguration
        if let pemPrivateKeyPassword {
            apnsConfig = APNSClientConfiguration(
                authenticationMethod: try .tls(
                    privateKey: .privateKey(
                        NIOSSLPrivateKey(bytes: privateKeyBytes, format: .pem) { passphraseCallback in
                            passphraseCallback(pemPrivateKeyPassword.utf8)
                        }
                    ),
                    certificateChain: NIOSSLCertificate.fromPEMBytes(certificateBytes).map { .certificate($0) }
                ),
                environment: .production
            )
        } else {
            apnsConfig = APNSClientConfiguration(
                authenticationMethod: try .tls(
                    privateKey: .privateKey(NIOSSLPrivateKey(bytes: privateKeyBytes, format: .pem)),
                    certificateChain: NIOSSLCertificate.fromPEMBytes(certificateBytes).map { .certificate($0) }
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

        let orderTypeIdentifier = PathComponent(stringLiteral: OD.typeIdentifier)
        let v1 = app.grouped("api", "orders", "v1")
        v1.get("devices", ":deviceIdentifier", "registrations", orderTypeIdentifier, use: { try await self.ordersForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })

        let v1auth = v1.grouped(AppleOrderMiddleware<O>())
        v1auth.post(
            "devices", ":deviceIdentifier", "registrations", orderTypeIdentifier, ":orderIdentifier",
            use: { try await self.registerDevice(req: $0) }
        )
        v1auth.get("orders", orderTypeIdentifier, ":orderIdentifier", use: { try await self.latestVersionOfOrder(req: $0) })
        v1auth.delete(
            "devices", ":deviceIdentifier", "registrations", orderTypeIdentifier, ":orderIdentifier",
            use: { try await self.unregisterDevice(req: $0) }
        )

        if let pushRoutesMiddleware {
            let pushAuth = v1.grouped(pushRoutesMiddleware)
            pushAuth.post("push", orderTypeIdentifier, ":orderIdentifier", use: { try await self.pushUpdatesForOrder(req: $0) })
            pushAuth.get("push", orderTypeIdentifier, ":orderIdentifier", use: { try await self.tokensForOrderUpdate(req: $0) })
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

        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        guard
            let order = try await O.query(on: req.db)
                .filter(\._$id == id)
                .filter(\._$typeIdentifier == OD.typeIdentifier)
                .first()
        else {
            throw Abort(.notFound)
        }

        guard ifModifiedSince < order.updatedAt?.timeIntervalSince1970 ?? 0 else {
            throw Abort(.notModified)
        }

        guard
            let orderData = try await OD.query(on: req.db)
                .filter(\._$order.$id == id)
                .first()
        else {
            throw Abort(.notFound)
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.order")
        headers.lastModified = HTTPHeaders.LastModified(order.updatedAt ?? Date.distantPast)
        headers.add(name: .contentTransferEncoding, value: "binary")
        return try await Response(
            status: .ok,
            headers: headers,
            body: Response.Body(data: self.build(order: orderData, on: req.db))
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
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!
        guard
            let order = try await O.query(on: req.db)
                .filter(\._$id == orderIdentifier)
                .filter(\._$typeIdentifier == OD.typeIdentifier)
                .first()
        else {
            throw Abort(.notFound)
        }

        let device = try await D.query(on: req.db)
            .filter(\._$libraryIdentifier == deviceIdentifier)
            .filter(\._$pushToken == pushToken)
            .first()
        if let device = device {
            return try await Self.createRegistration(device: device, order: order, db: req.db)
        } else {
            let newDevice = D(libraryIdentifier: deviceIdentifier, pushToken: pushToken)
            try await newDevice.create(on: req.db)
            return try await Self.createRegistration(device: newDevice, order: order, db: req.db)
        }
    }

    private static func createRegistration(
        device: D, order: O, db: any Database
    ) async throws -> HTTPStatus {
        let r = try await R.for(
            deviceLibraryIdentifier: device.libraryIdentifier,
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

        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        var query = R.for(
            deviceLibraryIdentifier: deviceIdentifier,
            typeIdentifier: OD.typeIdentifier,
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
        let deviceIdentifier = req.parameters.get("deviceIdentifier")!

        guard
            let r = try await R.for(
                deviceLibraryIdentifier: deviceIdentifier,
                typeIdentifier: OD.typeIdentifier,
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

        guard
            let order = try await O.query(on: req.db)
                .filter(\._$id == id)
                .filter(\._$typeIdentifier == OD.typeIdentifier)
                .first()
        else {
            throw Abort(.notFound)
        }

        try await sendPushNotifications(for: order, on: req.db)
        return .noContent
    }

    fileprivate func tokensForOrderUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForOrderUpdate")

        guard let id = req.parameters.get("orderIdentifier", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        guard
            let order = try await O.query(on: req.db)
                .filter(\._$id == id)
                .filter(\._$typeIdentifier == OD.typeIdentifier)
                .first()
        else {
            throw Abort(.notFound)
        }

        return try await Self.registrations(for: order, on: req.db).map { $0.device.pushToken }
    }
}

// MARK: - Push Notifications
extension OrdersServiceCustom {
    /// Sends push notifications for a given order.
    ///
    /// - Parameters:
    ///   - orderData: The order to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for orderData: OD, on db: any Database) async throws {
        try await sendPushNotifications(for: orderData._$order.get(on: db), on: db)
    }

    private func sendPushNotifications(for order: O, on db: any Database) async throws {
        let registrations = try await Self.registrations(for: order, on: db)
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

    private static func registrations(for order: O, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property wrapper,
        // but there's not really any value to forcing that on them when we can just do the query ourselves like this.
        try await R.query(on: db)
            .join(parent: \._$order)
            .join(parent: \._$device)
            .with(\._$order)
            .with(\._$device)
            .filter(O.self, \._$typeIdentifier == OD.typeIdentifier)
            .filter(O.self, \._$id == order.requireID())
            .all()
    }
}

// MARK: - order file generation
extension OrdersServiceCustom {
    private func manifest(for directory: URL) throws -> Data {
        var manifest: [String: String] = [:]

        let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        for relativePath in paths {
            let file = URL(fileURLWithPath: relativePath, relativeTo: directory)
            guard !file.hasDirectoryPath else {
                continue
            }

            let hash = try SHA256.hash(data: Data(contentsOf: file))
            manifest[relativePath] = hash.map { "0\(String($0, radix: 16))".suffix(2) }.joined()
        }

        return try encoder.encode(manifest)
    }

    private func signature(for manifest: Data) throws -> Data {
        // Swift Crypto doesn't support encrypted PEM private keys, so we have to use OpenSSL for that.
        if let pemPrivateKeyPassword {
            guard FileManager.default.fileExists(atPath: self.openSSLURL.path) else {
                throw WalletError.noOpenSSLExecutable
            }

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try manifest.write(to: dir.appendingPathComponent("manifest.json"))
            try self.pemWWDRCertificate.write(to: dir.appendingPathComponent("wwdr.pem"), atomically: true, encoding: .utf8)
            try self.pemCertificate.write(to: dir.appendingPathComponent("certificate.pem"), atomically: true, encoding: .utf8)
            try self.pemPrivateKey.write(to: dir.appendingPathComponent("private.pem"), atomically: true, encoding: .utf8)

            let process = Process()
            process.currentDirectoryURL = dir
            process.executableURL = self.openSSLURL
            process.arguments = [
                "smime", "-binary", "-sign",
                "-certfile", dir.appendingPathComponent("wwdr.pem").path,
                "-signer", dir.appendingPathComponent("certificate.pem").path,
                "-inkey", dir.appendingPathComponent("private.pem").path,
                "-in", dir.appendingPathComponent("manifest.json").path,
                "-out", dir.appendingPathComponent("signature").path,
                "-outform", "DER",
                "-passin", "pass:\(pemPrivateKeyPassword)",
            ]
            try process.run()
            process.waitUntilExit()

            return try Data(contentsOf: dir.appendingPathComponent("signature"))
        } else {
            let signature = try CMS.sign(
                manifest,
                signatureAlgorithm: .sha256WithRSAEncryption,
                additionalIntermediateCertificates: [
                    Certificate(pemEncoded: self.pemWWDRCertificate)
                ],
                certificate: Certificate(pemEncoded: self.pemCertificate),
                privateKey: .init(pemEncoded: self.pemPrivateKey),
                signingTime: Date()
            )
            return Data(signature)
        }
    }

    /// Generates the order content bundle for a given order.
    ///
    /// - Parameters:
    ///   - order: The order to generate the content for.
    ///   - db: The `Database` to use.
    ///
    /// - Returns: The generated order content as `Data`.
    public func build(order: OD, on db: any Database) async throws -> Data {
        let filesDirectory = try await URL(fileURLWithPath: order.template(on: db), isDirectory: true)
        guard
            (try? filesDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        else {
            throw WalletError.noSourceFiles
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: filesDirectory, to: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var files: [ArchiveFile] = []

        let orderJSON = try await self.encoder.encode(order.orderJSON(on: db))
        try orderJSON.write(to: tempDir.appendingPathComponent("order.json"))
        files.append(ArchiveFile(filename: "order.json", data: orderJSON))

        let manifest = try self.manifest(for: tempDir)
        files.append(ArchiveFile(filename: "manifest.json", data: manifest))
        try files.append(ArchiveFile(filename: "signature", data: self.signature(for: manifest)))

        let paths = try FileManager.default.subpathsOfDirectory(atPath: filesDirectory.path)
        for relativePath in paths {
            let file = URL(fileURLWithPath: relativePath, relativeTo: tempDir)
            guard !file.hasDirectoryPath else {
                continue
            }

            try files.append(ArchiveFile(filename: relativePath, data: Data(contentsOf: file)))
        }

        let zipFile = tempDir.appendingPathComponent("\(UUID().uuidString).order")
        try Zip.zipData(archiveFiles: files, zipFilePath: zipFile)
        return try Data(contentsOf: zipFile)
    }
}
