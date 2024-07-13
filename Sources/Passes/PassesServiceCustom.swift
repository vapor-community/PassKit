//
//  PassesServiceCustom.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 29/06/24.
//

@preconcurrency import Vapor
import APNS
import VaporAPNS
@preconcurrency import APNSCore
import Fluent
import NIOSSL
import PassKit

/// Class to handle ``PassesService``.
///
/// The generics should be passed in this order:
/// - Pass Type
/// - User Personalization Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public final class PassesServiceCustom<P, U, D, R: PassesRegistrationModel, E: ErrorLogModel>: Sendable where P == R.PassType, D == R.DeviceType, U == P.UserPersonalizationType {
    /// The ``PassesDelegate`` to use for pass generation.
    public unowned let delegate: any PassesDelegate
    
    private let v1: any RoutesBuilder
    private let logger: Logger?
    
    /// Initializes the service.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to use in route handlers and APNs.
    ///   - delegate: The ``PassesDelegate`` to use for pass generation.
    ///   - logger: The `Logger` to use.
    public init(app: Application, delegate: any PassesDelegate, logger: Logger? = nil) throws {
        self.delegate = delegate
        self.logger = logger
        
        v1 = app.grouped("api", "passes", "v1")

        let privateKeyPath = URL(fileURLWithPath: delegate.pemPrivateKey, relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw PassesError.pemPrivateKeyMissing
        }
        let pemPath = URL(fileURLWithPath: delegate.pemCertificate, relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        guard FileManager.default.fileExists(atPath: pemPath) else {
            throw PassesError.pemCertificateMissing
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
            as: .init(string: "passes"),
            isDefault: false
        )
    }
    
    /// Registers all the routes required for PassKit to work.
    public func registerRoutes() {
        v1.get("devices", ":deviceLibraryIdentifier", "registrations", ":passTypeIdentifier", use: { try await self.passesForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })
        let v1auth = v1.grouped(ApplePassMiddleware<P>())
        v1auth.post("devices", ":deviceLibraryIdentifier", "registrations", ":passTypeIdentifier", ":passSerial", use: { try await self.registerDevice(req: $0) })
        v1auth.get("passes", ":passTypeIdentifier", ":passSerial", use: { try await self.latestVersionOfPass(req: $0) })
        v1auth.delete("devices", ":deviceLibraryIdentifier", "registrations", ":passTypeIdentifier", ":passSerial", use: { try await self.unregisterDevice(req: $0) })
        v1auth.post("passes", ":passTypeIdentifier", ":passSerial", "personalize", use: { try await self.personalizedPass(req: $0) })
    }
    
    /// Registers routes to send push notifications for updated passes
    ///
    /// ### Example ###
    /// ```swift
    /// passesService.registerPushRoutes(middleware: SecretMiddleware(secret: "foo"))
    /// ```
    ///
    /// - Parameter middleware: The `Middleware` which will control authentication for the routes.
    public func registerPushRoutes(middleware: any Middleware) {
        let pushAuth = v1.grouped(middleware)
        pushAuth.post("push", ":passTypeIdentifier", ":passSerial", use: { try await self.pushUpdatesForPass(req: $0) })
        pushAuth.get("push", ":passTypeIdentifier", ":passSerial", use: { try await self.tokensForPassUpdate(req: $0) })
    }
}
    
// MARK: - API Routes
extension PassesServiceCustom {
    func registerDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called register device")
        
        guard let serial = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        let pushToken: String
        do {
            let content = try req.content.decode(RegistrationDTO.self)
            pushToken = content.pushToken
        } catch {
            throw Abort(.badRequest)
        }
        
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!
        
        guard let pass = try await P.query(on: req.db)
            .filter(\._$passTypeIdentifier == passTypeIdentifier)
            .filter(\._$id == serial)
            .first()
        else {
            throw Abort(.notFound)
        }
        
        let device = try await D.query(on: req.db)
            .filter(\._$deviceLibraryIdentifier == deviceLibraryIdentifier)
            .filter(\._$pushToken == pushToken)
            .first()
        
        if let device = device {
            return try await Self.createRegistration(device: device, pass: pass, db: req.db)
        } else {
            let newDevice = D(deviceLibraryIdentifier: deviceLibraryIdentifier, pushToken: pushToken)
            try await newDevice.create(on: req.db)
            return try await Self.createRegistration(device: newDevice, pass: pass, db: req.db)
        }
    }
    
    private static func createRegistration(device: D, pass: P, db: any Database) async throws -> HTTPStatus {
        let r = try await R.for(deviceLibraryIdentifier: device.deviceLibraryIdentifier, passTypeIdentifier: pass.passTypeIdentifier, on: db)
            .filter(P.self, \._$id == pass.requireID())
            .first()
        if r != nil {
            // If the registration already exists, docs say to return a 200
            return .ok
        }
        let registration = R()
        registration._$pass.id = try pass.requireID()
        registration._$device.id = try device.requireID()
        try await registration.create(on: db)
        return .created
    }
    
    func passesForDevice(req: Request) async throws -> PassesForDeviceDTO {
        logger?.debug("Called passesForDevice")
        
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!
        
        var query = R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: passTypeIdentifier, on: req.db)
        if let since: TimeInterval = req.query["passesUpdatedSince"] {
            let when = Date(timeIntervalSince1970: since)
            query = query.filter(P.self, \._$updatedAt > when)
        }
        
        let registrations = try await query.all()
        guard !registrations.isEmpty else {
            throw Abort(.noContent)
        }
        
        var serialNumbers: [String] = []
        var maxDate = Date.distantPast
        try registrations.forEach { r in
            let pass = r.pass
            try serialNumbers.append(pass.requireID().uuidString)
            if let updatedAt = pass.updatedAt, updatedAt > maxDate {
                maxDate = updatedAt
            }
        }
        
        return PassesForDeviceDTO(with: serialNumbers, maxDate: maxDate)
    }
    
    func latestVersionOfPass(req: Request) async throws -> Response {
        logger?.debug("Called latestVersionOfPass")
        
        guard FileManager.default.fileExists(atPath: delegate.zipBinary.unixPath()) else {
            throw Abort(.internalServerError, suggestedFixes: ["Provide full path to zip command"])
        }
        
        var ifModifiedSince: TimeInterval = 0
        if let header = req.headers[.ifModifiedSince].first, let ims = TimeInterval(header) {
            ifModifiedSince = ims
        }
        
        guard let passTypeIdentifier = req.parameters.get("passTypeIdentifier"),
            let id = req.parameters.get("passSerial", as: UUID.self) else {
                throw Abort(.badRequest)
        }
        
        guard let pass = try await P.query(on: req.db)
            .filter(\._$id == id)
            .filter(\._$passTypeIdentifier == passTypeIdentifier)
            .first()
        else {
            throw Abort(.notFound)
        }
        
        guard ifModifiedSince < pass.updatedAt?.timeIntervalSince1970 ?? 0 else {
            throw Abort(.notModified)
        }
        
        let data = try await self.generatePassContent(for: pass, on: req.db)
        let body = Response.Body(data: data)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
        headers.add(name: .lastModified, value: String(pass.updatedAt?.timeIntervalSince1970 ?? 0))
        headers.add(name: .contentTransferEncoding, value: "binary")
        return Response(status: .ok, headers: headers, body: body)
    }
    
    func unregisterDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called unregisterDevice")
        
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!
        guard let passId = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!
        
        guard let r = try await R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: passTypeIdentifier, on: req.db)
            .filter(P.self, \._$id == passId)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await r.delete(on: req.db)
        return .ok
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

    func personalizedPass(req: Request) async throws -> Response {
        logger?.debug("Called personalizedPass")
        guard let passTypeIdentifier = req.parameters.get("passTypeIdentifier"),
            let id = req.parameters.get("passSerial", as: UUID.self) else {
                throw Abort(.badRequest)
        }
        guard let pass = try await P.query(on: req.db)
            .filter(\._$id == id)
            .filter(\._$passTypeIdentifier == passTypeIdentifier)
            .first()
        else {
            throw Abort(.notFound)
        }

        let userInfo = try req.content.decode(PersonalizationDictionaryDTO.self)

        let userPersonalization = U()
        userPersonalization.fullName = userInfo.requiredPersonalizationInfo.fullName
        userPersonalization.givenName = userInfo.requiredPersonalizationInfo.givenName
        userPersonalization.familyName = userInfo.requiredPersonalizationInfo.familyName
        userPersonalization.emailAddress = userInfo.requiredPersonalizationInfo.emailAddress
        userPersonalization.postalCode = userInfo.requiredPersonalizationInfo.postalCode
        userPersonalization.ISOCountryCode = userInfo.requiredPersonalizationInfo.ISOCountryCode
        userPersonalization.phoneNumber = userInfo.requiredPersonalizationInfo.phoneNumber
        try await userPersonalization.create(on: req.db)

        pass._$userPersonalization.id = try userPersonalization.requireID()
        try await pass.update(on: req.db)

        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { _ = try? FileManager.default.removeItem(at: root) }

        guard let token = userInfo.personalizationToken.data(using: .utf8) else {
            throw Abort(.internalServerError)
        }
        try token.write(to: root.appendingPathComponent("personalizationToken"))

        let sslBinary = delegate.sslBinary
        guard FileManager.default.fileExists(atPath: sslBinary.unixPath()) else {
            throw PassesError.opensslBinaryMissing
        }

        let proc = Process()
        proc.currentDirectoryURL = delegate.sslSigningFilesDirectory
        proc.executableURL = sslBinary
        proc.arguments = [
            "smime", "-binary", "-sign",
            "-certfile", delegate.wwdrCertificate,
            "-signer", delegate.pemCertificate,
            "-inkey", delegate.pemPrivateKey,
            "-in", root.appendingPathComponent("personalizationToken").unixPath(),
            "-out", root.appendingPathComponent("signature").unixPath(),
            "-outform", "DER"
        ]
        if let pwd = delegate.pemPrivateKeyPassword {
            proc.arguments!.append(contentsOf: ["-passin", "pass:\(pwd)"])
        }
        try proc.run()
        proc.waitUntilExit()

        let signature = try Data(contentsOf: root.appendingPathComponent("signature"))

        let body = Response.Body(data: signature)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/octet-stream")
        headers.add(name: .contentTransferEncoding, value: "binary")
        return Response(status: .ok, headers: headers, body: body)
    }
    
    // MARK: - Push Routes
    func pushUpdatesForPass(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called pushUpdatesForPass")
        guard let id = req.parameters.get("passSerial", as: UUID.self) else { throw Abort(.badRequest) }
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!
        try await Self.sendPushNotificationsForPass(id: id, of: passTypeIdentifier, on: req.db, app: req.application)
        return .noContent
    }
    
    func tokensForPassUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForPassUpdate")
        guard let id = req.parameters.get("passSerial", as: UUID.self) else { throw Abort(.badRequest) }
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!
        let registrations = try await Self.registrationsForPass(id: id, of: passTypeIdentifier, on: req.db)
        return registrations.map { $0.device.pushToken }
    }
}
    
// MARK: - Push Notifications
extension PassesServiceCustom {
    /// Sends push notifications for a given pass.
    ///
    /// - Parameters:
    ///   - id: The `UUID` of the pass to send the notifications for.
    ///   - passTypeIdentifier: The type identifier of the pass.
    ///   - db: The `Database` to use.
    ///   - app: The `Application` to use.
    public static func sendPushNotificationsForPass(id: UUID, of passTypeIdentifier: String, on db: any Database, app: Application) async throws {
        let registrations = try await Self.registrationsForPass(id: id, of: passTypeIdentifier, on: db)
        for reg in registrations {
            let backgroundNotification = APNSBackgroundNotification(expiration: .immediately, topic: reg.pass.passTypeIdentifier, payload: EmptyPayload())
            do {
                try await app.apns.client(.init(string: "passes")).sendBackgroundNotification(
                    backgroundNotification,
                    deviceToken: reg.device.pushToken
                )
            } catch let error as APNSCore.APNSError where error.reason == .badDeviceToken {
                try await reg.device.delete(on: db)
                try await reg.delete(on: db)
            }
        }
    }

    /// Sends push notifications for a given pass.
    /// 
    /// - Parameters:
    ///   - pass: The pass to send the notifications for.
    ///   - db: The `Database` to use.
    ///   - app: The `Application` to use.
    public static func sendPushNotifications(for pass: P, on db: any Database, app: Application) async throws {
        try await Self.sendPushNotificationsForPass(id: pass.requireID(), of: pass.passTypeIdentifier, on: db, app: app)
    }
    
    /// Sends push notifications for a given pass.
    /// 
    /// - Parameters:
    ///   - pass: The pass (as the `ParentProperty`) to send the notifications for.
    ///   - db: The `Database` to use.
    ///   - app: The `Application` to use.
    public static func sendPushNotifications(for pass: ParentProperty<R, P>, on db: any Database, app: Application) async throws {
        let value: P
        if let eagerLoaded = pass.value {
            value = eagerLoaded
        } else {
            value = try await pass.get(on: db)
        }
        try await sendPushNotifications(for: value, on: db, app: app)
    }
    
    private static func registrationsForPass(id: UUID, of passTypeIdentifier: String, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property
        // wrapper, but there's not really any value to forcing that on them when
        // we can just do the query ourselves like this.
        try await R.query(on: db)
            .join(parent: \._$pass)
            .join(parent: \._$device)
            .with(\._$pass)
            .with(\._$device)
            .filter(P.self, \._$passTypeIdentifier == passTypeIdentifier)
            .filter(P.self, \._$id == id)
            .all()
    }
}
    
// MARK: - pkpass file generation
extension PassesServiceCustom {
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
        var manifest: [String: String] = [:]
        
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath())
        try paths.forEach { relativePath in
            let file = URL(fileURLWithPath: relativePath, relativeTo: root)
            guard !file.hasDirectoryPath else { return }
            let data = try Data(contentsOf: file)
            let hash = Insecure.SHA1.hash(data: data)
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
            throw PassesError.opensslBinaryMissing
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
            throw PassesError.zipBinaryMissing
        }
        let proc = Process()
        proc.currentDirectoryURL = directory
        proc.executableURL = zipBinary
        proc.arguments = [ to.unixPath(), "-r", "-q", "." ]
        try proc.run()
        proc.waitUntilExit()
    }
    
    /// Generates the pass content bundle for a given pass.
    ///
    /// - Parameters:
    ///   - pass: The pass to generate the content for.
    ///   - db: The `Database` to use.
    /// - Returns: The generated pass content as `Data`.
    public func generatePassContent(for pass: P, on db: any Database) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let encoder = JSONEncoder()
        
        let src = try await delegate.template(for: pass, db: db)
        guard (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else {
            throw PassesError.templateNotDirectory
        }
        
        let encoded = try await self.delegate.encode(pass: pass, db: db, encoder: encoder)
        
        do {
            try FileManager.default.copyItem(at: src, to: root)
            defer { _ = try? FileManager.default.removeItem(at: root) }
            try encoded.write(to: root.appendingPathComponent("pass.json"))

            // Pass Personalization
            if let encodedPersonalization = try await self.delegate.encodePersonalization(for: pass, db: db, encoder: encoder) {
                try encodedPersonalization.write(to: root.appendingPathComponent("personalization.json"))
            }
            
            try Self.generateManifestFile(using: encoder, in: root)
            try self.generateSignatureFile(in: root)
            
            try self.zip(directory: root, to: zipFile)
            defer { _ = try? FileManager.default.removeItem(at: zipFile) } 
            return try Data(contentsOf: zipFile)
        } catch {
            throw error
        }
    }

    /// Generates a bundle of passes to enable your user to download multiple passes at once.
    ///
    /// > Note: You can have up to 10 passes or 150 MB for a bundle of passes.
    ///
    /// > Important: Bundles of passes are supported only in Safari. You can't send the bundle via AirDrop or other methods.
    ///
    /// - Parameters:
    ///   - passes: The passes to include in the bundle.
    ///   - db: The `Database` to use.
    /// - Returns: The bundle of passes as `Data`.
    public func generatePassesContent(for passes: [P], on db: any Database) async throws -> Data {
        guard passes.count > 1 && passes.count <= 10 else {
            throw PassesError.invalidNumberOfPasses
        }

        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        
        for (i, pass) in passes.enumerated() {
            try await self.generatePassContent(for: pass, on: db)
                .write(to: root.appendingPathComponent("pass\(i).pkpass"))
        }

        defer { _ = try? FileManager.default.removeItem(at: root) }

        try self.zip(directory: root, to: zipFile)
        defer { _ = try? FileManager.default.removeItem(at: zipFile) }
        return try Data(contentsOf: zipFile)
    }
}
