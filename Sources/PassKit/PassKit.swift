/// Copyright 2020 Gargoyle Software, LLC
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import Vapor
import APNS
import VaporAPNS
import APNSCore
import Fluent
import NIOSSL

public class PassKit {
    private let kit: PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>
    
    public init(app: Application, delegate: any PassKitDelegate, logger: Logger? = nil) {
        kit = .init(app: app, delegate: delegate, logger: logger)
    }
    
    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - authorizationCode: The `authenticationToken` which you are going to use in the `pass.json` file.
    public func registerRoutes(authorizationCode: String? = nil) {
        kit.registerRoutes(authorizationCode: authorizationCode)
    }
    
    public func registerPushRoutes(middleware: any Middleware) throws {
        try kit.registerPushRoutes(middleware: middleware)
    }

    public func generatePassContent(for pass: PKPass, on db: any Database) -> EventLoopFuture<Data> {
        kit.generatePassContent(for: pass, on: db)
    }
    
    public static func register(migrations: Migrations) {
        migrations.add(PKPass())
        migrations.add(PKDevice())
        migrations.add(PKRegistration())
        migrations.add(PKErrorLog())
    }
    
    public static func sendPushNotificationsForPass(id: UUID, of type: String, on db: any Database, app: Application) async throws {
        try await PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>.sendPushNotificationsForPass(id: id, of: type, on: db, app: app)
    }
    
    public static func sendPushNotifications(for pass: PKPass, on db: any Database, app: Application) async throws {
        try await PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>.sendPushNotifications(for: pass, on: db, app: app)
    }
    
    public static func sendPushNotifications(for pass: ParentProperty<PKRegistration, PKPass>, on db: any Database, app: Application) async throws {
        try await PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>.sendPushNotifications(for: pass, on: db, app: app)
    }
}

/// Class to handle PassKit.
///
/// The generics should be passed in this order:
/// - Pass Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public class PassKitCustom<P, D, R: PassKitRegistration, E: PassKitErrorLog> where P == R.PassType, D == R.DeviceType {
    public unowned let delegate: any PassKitDelegate
    private unowned let app: Application
    
    private let processQueue = DispatchQueue(label: "com.vapor-community.PassKit", qos: .utility, attributes: .concurrent)
    private let v1: any RoutesBuilder
    private let logger: Logger?
    
    public init(app: Application, delegate: any PassKitDelegate, logger: Logger? = nil) {
        self.delegate = delegate
        self.logger = logger
        self.app = app
        
        v1 = app.grouped("api", "v1")
    }
    
    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - authorizationCode: The `authenticationToken` which you are going to use in the `pass.json` file.
    public func registerRoutes(authorizationCode: String? = nil) {
        v1.get("devices", ":deviceLibraryIdentifier", "registrations", ":type", use: passesForDevice)
        v1.post("log", use: logError)
        
        guard let code = authorizationCode ?? Environment.get("PASS_KIT_AUTHORIZATION") else {
            fatalError("Must pass in an authorization code")
        }
        
        let v1auth = v1.grouped(ApplePassMiddleware(authorizationCode: code))
        
        v1auth.post("devices", ":deviceLibraryIdentifier", "registrations", ":type", ":passSerial", use: registerDevice)
        v1auth.get("passes", ":type", ":passSerial", use: latestVersionOfPass)
        v1auth.delete("devices", ":deviceLibraryIdentifier", "registrations", ":type", ":passSerial", use: unregisterDevice)
    }
    
    /// Registers routes to send push notifications for updated passes
    ///
    /// ### Example ###
    /// ```
    /// try pk.registerPushRoutes(environment: .sandbox, middleware: PushAuthMiddleware())
    /// ```
    ///
    /// - Parameters:
    ///   - middleware: The `Middleware` which will control authentication for the routes.
    /// - Throws: An error of type `PassKitError`
    public func registerPushRoutes(middleware: any Middleware) throws {
        let privateKeyPath = URL(fileURLWithPath: delegate.pemPrivateKey, relativeTo:
            delegate.sslSigningFilesDirectory).unixPath()

        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw PassKitError.pemPrivateKeyMissing
        }

        let pemPath = URL(fileURLWithPath: delegate.pemCertificate, relativeTo: delegate.sslSigningFilesDirectory).unixPath()

        guard FileManager.default.fileExists(atPath: privateKeyPath) else {
            throw PassKitError.pemCertificateMissing
        }

        // PassKit *only* works with the production APNs. You can't pass in .sandbox here.
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
            as: .init(string: "passkit"),
            isDefault: false
        )
        
        let pushAuth = v1.grouped(middleware)
        
        pushAuth.post("push", ":type", ":passSerial", use: pushUpdatesForPass)
        pushAuth.get("push", ":type", ":passSerial", use: tokensForPassUpdate)
    }
    
    // MARK: - API Routes
    @Sendable func registerDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called register device")
        
        guard let serial = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        let pushToken: String
        do {
            let content = try req.content.decode(RegistrationDto.self)
            pushToken = content.pushToken
        } catch {
            throw Abort(.badRequest)
        }
        
        let type = req.parameters.get("type")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!
        
        guard let pass = try await P.query(on: req.db)
            .filter(\._$type == type)
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
            return try await Self.createRegistration(device: device, pass: pass, req: req)
        } else {
            let newDevice = D(deviceLibraryIdentifier: deviceLibraryIdentifier, pushToken: pushToken)
            try await newDevice.create(on: req.db)
            return try await Self.createRegistration(device: newDevice, pass: pass, req: req)
        }
    }
    
    @Sendable func passesForDevice(req: Request) async throws -> PassesForDeviceDto {
        logger?.debug("Called passesForDevice")
        
        let type = req.parameters.get("type")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!
        
        var query = R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: type, on: req.db)
        
        if let since: TimeInterval = req.query["passesUpdatedSince"] {
            let when = Date(timeIntervalSince1970: since)
            query = query.filter(P.self, \._$modified > when)
        }
        
        let registrations = try await query.all()
        guard !registrations.isEmpty else {
            throw Abort(.noContent)
        }
        
        var serialNumbers: [String] = []
        var maxDate = Date.distantPast
        
        registrations.forEach { r in
            let pass = r.pass
            
            serialNumbers.append(pass.id!.uuidString)
            if pass.modified > maxDate {
                maxDate = pass.modified
            }
        }
        
        return PassesForDeviceDto(with: serialNumbers, maxDate: maxDate)
    }
    
    @Sendable func latestVersionOfPass(req: Request) async throws -> Response {
        logger?.debug("Called latestVersionOfPass")
        
        guard FileManager.default.fileExists(atPath: delegate.zipBinary.unixPath()) else {
            throw Abort(.internalServerError, suggestedFixes: ["Provide full path to zip command"])
        }
        
        var ifModifiedSince: TimeInterval = 0
        
        if let header = req.headers[.ifModifiedSince].first, let ims = TimeInterval(header) {
            ifModifiedSince = ims
        }
        
        guard let type = req.parameters.get("type"),
            let id = req.parameters.get("passSerial", as: UUID.self) else {
                throw Abort(.badRequest)
        }
        
        guard let pass = try await P.query(on: req.db)
            .filter(\._$id == id)
            .filter(\._$type == type)
            .first()
        else {
            throw Abort(.notFound)
        }
        
        guard ifModifiedSince < pass.modified.timeIntervalSince1970 else {
            throw Abort(.notModified)
        }
        
        let data = try await self.generatePassContent(for: pass, on: req.db).get()
        let body = Response.Body(data: data)
        
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
        headers.add(name: .lastModified, value: String(pass.modified.timeIntervalSince1970))
        headers.add(name: .contentTransferEncoding, value: "binary")
        
        return Response(status: .ok, headers: headers, body: body)
    }
    
    @Sendable func unregisterDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called unregisterDevice")
        
        let type = req.parameters.get("type")!
        
        guard let passId = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!
        
        guard let r = try await R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: type, on: req.db)
            .filter(P.self, \._$id == passId)
            .first()
        else {
            throw Abort(.notFound)
        }
        try await r.delete(on: req.db)
        return .ok
    }
    
    @Sendable func logError(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called logError")
        
        let body: ErrorLogDto
        
        do {
            body = try req.content.decode(ErrorLogDto.self)
        } catch {
            throw Abort(.badRequest)
        }
        
        guard body.logs.isEmpty == false else {
            throw Abort(.badRequest)
        }
        
        return body.logs
            .map { E(message: $0).create(on: req.db) }
            .flatten(on: req.eventLoop)
            .map { .ok }
    }
    
    @Sendable func pushUpdatesForPass(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called pushUpdatesForPass")
        
        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        let type = req.parameters.get("type")!
        
        try await Self.sendPushNotificationsForPass(id: id, of: type, on: req.db, app: req.application)
        return .noContent
    }
    
    @Sendable func tokensForPassUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForPassUpdate")
        
        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        
        let type = req.parameters.get("type")!
        
        let registrations = try await Self.registrationsForPass(id: id, of: type, on: req.db)
        return registrations.map { $0.device.pushToken }
    }
    
    private static func createRegistration(device: D, pass: P, req: Request) async throws -> HTTPStatus {
        let r = try await R.for(deviceLibraryIdentifier: device.deviceLibraryIdentifier, passTypeIdentifier: pass.type, on: req.db)
            .filter(P.self, \._$id == pass.id!)
            .first()
        if r != nil {
            // If the registration already exists, docs say to return a 200
            return .ok
        }
        
        let registration = R()
        registration._$pass.id = pass.id!
        registration._$device.id = device.id!
        
        try await registration.create(on: req.db)
        return .created
    }
    
    // MARK: - Push Notifications
    public static func sendPushNotificationsForPass(id: UUID, of type: String, on db: any Database, app: Application) async throws {
        let registrations = try await Self.registrationsForPass(id: id, of: type, on: db)
        for reg in registrations {
            let backgroundNotification = APNSBackgroundNotification(expiration: .immediately, topic: reg.pass.type, payload: EmptyPayload())
            do {
                try await app.apns.client(.init(string: "passkit")).sendBackgroundNotification(
                    backgroundNotification,
                    deviceToken: reg.device.pushToken
                )
            } catch let error as APNSCore.APNSError where error.reason == .badDeviceToken {
                try await reg.device.delete(on: db)
                try await reg.delete(on: db)
            }
        }
    }

    public static func sendPushNotifications(for pass: P, on db: any Database, app: Application) async throws {
        guard let id = pass.id else {
            throw FluentError.idRequired
        }
        
        try await Self.sendPushNotificationsForPass(id: id, of: pass.type, on: db, app: app)
    }
    
    public static func sendPushNotifications(for pass: ParentProperty<R, P>, on db: any Database, app: Application) async throws {
        let value: P
        
        if let eagerLoaded = pass.value {
            value = eagerLoaded
        } else {
            value = try await pass.get(on: db)
        }
        
       try await sendPushNotifications(for: value, on: db, app: app)
    }
    
    private static func registrationsForPass(id: UUID, of type: String, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property
        // wrapper, but there's not really any value to forcing that on them when
        // we can just do the query ourselves like this.
        try await R.query(on: db)
            .join(parent: \._$pass)
            .join(parent: \._$device)
            .with(\._$pass)
            .with(\._$device)
            .filter(P.self, \._$type == type)
            .filter(P.self, \._$id == id)
            .all()
    }
    
    // MARK: - pkpass file generation
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
        var manifest: [String: String] = [:]
        
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath())
        try paths.forEach { relativePath in
            let file = URL(fileURLWithPath: relativePath, relativeTo: root)
            guard !file.hasDirectoryPath else {
                return
            }
            
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
            throw PassKitError.opensslBinaryMissing
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
            throw PassKitError.zipBinaryMissing
        }
        
        let proc = Process()
        proc.currentDirectoryURL = directory
        proc.executableURL = zipBinary
        
        proc.arguments = [ to.unixPath(), "-r", "-q", "." ]
        
        try proc.run()
        proc.waitUntilExit()
    }
    
    public func generatePassContent(for pass: P, on db: any Database) -> EventLoopFuture<Data> {
        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        let encoder = JSONEncoder()
        
        return delegate.template(for: pass, db: db)
            .flatMap { src in
                var isDir: ObjCBool = false

                guard src.hasDirectoryPath &&
                    FileManager.default.fileExists(atPath: src.unixPath(), isDirectory: &isDir) &&
                    isDir.boolValue else {
                        return db.eventLoop.makeFailedFuture(PassKitError.templateNotDirectory)
                }
                
                return self.delegate.encode(pass: pass, db: db, encoder: encoder)
                    .flatMap { encoded in
                        let result: EventLoopPromise<Data> = db.eventLoop.makePromise()
                        
                        self.processQueue.async {
                            do {
                                try FileManager.default.copyItem(at: src, to: root)
                            
                                defer {
                                    _ = try? FileManager.default.removeItem(at: root)
                                }
                                
                                try encoded.write(to: root.appendingPathComponent("pass.json"))
                                
                                try Self.generateManifestFile(using: encoder, in: root)
                                try self.generateSignatureFile(in: root)
                                                                
                                try self.zip(directory: root, to: zipFile)
                                
                                defer {
                                    _ = try? FileManager.default.removeItem(at: zipFile)
                                }
                                
                                let data = try Data(contentsOf: zipFile)
                                result.completeWith(.success(data))
                            } catch {
                                result.completeWith(.failure(error))
                            }
                        }
                        
                        return result.futureResult
                }
        }
    }
}
