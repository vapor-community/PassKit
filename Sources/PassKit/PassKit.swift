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
import ZIPFoundation
import APNS
import Fluent

public class PassKit {
    private let kit: PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>

    public init(app: Application, delegate: PassKitDelegate, logger: Logger? = nil) {
        kit = .init(app: app, delegate: delegate, logger: logger)
    }

    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Application` passed to `routes(_:)`
    ///   - delegate: The `PassKitDelegate` to use.
    ///   - authorizationCode: The `authenticationToken` which you are going to use in the `pass.json` file.
    public func registerRoutes(authorizationCode: String? = nil) {
        kit.registerRoutes(authorizationCode: authorizationCode)
    }

    public func registerPushRoutes(middleware: Middleware) throws {
        try kit.registerPushRoutes(middleware: middleware)
    }

    public static func register(migrations: Migrations) {
        migrations.add(PKPass())
        migrations.add(PKDevice())
        migrations.add(PKRegistration())
        migrations.add(PKErrorLog())
    }

    public static func sendPushNotificationsForPass(id: UUID, of type: String, on db: Database, app: Application) -> EventLoopFuture<Void> {
        PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>.sendPushNotificationsForPass(id: id, of: type, on: db, app: app)
    }

    public static func sendPushNotifications(for pass: PKPass, on db: Database, app: Application) -> EventLoopFuture<Void> {
        PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>.sendPushNotifications(for: pass, on: db, app: app)
    }

    public static func sendPushNotifications(for pass: Parent<PKPass>, on db: Database, app: Application) -> EventLoopFuture<Void> {
        PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>.sendPushNotifications(for: pass, on: db, app: app)
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
    public unowned let delegate: PassKitDelegate
    private unowned let app: Application

    private let v1: RoutesBuilder
    private let logger: Logger?

    public init(app: Application, delegate: PassKitDelegate, logger: Logger? = nil) {
        self.delegate = delegate
        self.logger = logger
        self.app = app

        v1 = app.grouped("api", "v1")
    }

    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Application` passed to `routes(_:)`
    ///   - delegate: The `PassKitDelegate` to use.
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
    public func registerPushRoutes(middleware: Middleware) throws {
        let privateKeyPath = URL(fileURLWithPath: delegate.pemPrivateKey, relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        let pemPath = URL(fileURLWithPath: delegate.pemCertificate, relativeTo: delegate.sslSigningFilesDirectory).unixPath()

        // PassKit *only* works with the production APNs.  You can't pass in .sandbox here.
        if app.apns.configuration == nil {
            if let pwd = delegate.pemPrivateKeyPassword {
                app.apns.configuration = try .init(privateKeyPath: privateKeyPath, pemPath: pemPath, topic: "", environment: .production, logger: logger) {
                    $0(pwd.utf8)
                }
            } else {
                app.apns.configuration = try .init(privateKeyPath: privateKeyPath, pemPath: pemPath, topic: "", environment: .production, logger: logger)
            }
        }

        let pushAuth = v1.grouped(middleware)

        pushAuth.post("push", ":type", ":passSerial", use: pushUpdatesForPass)
        pushAuth.get("push", ":type", ":passSerial", use: tokensForPassUpdate)
    }

    // MARK: - API Routes
    func registerDevice(req: Request) throws -> EventLoopFuture<HTTPStatus> {
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

        return P.query(on: req.db)
            .filter(\._$type == type)
            .filter(\._$id == serial)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { pass in
                D.query(on: req.db)
                    .filter(\._$deviceLibraryIdentifier == deviceLibraryIdentifier)
                    .filter(\._$pushToken == pushToken)
                    .first()
                    .flatMap { device in
                        if let device = device {
                            return Self.createRegistration(device: device, pass: pass, req: req)
                        } else {
                            let newDevice = D(deviceLibraryIdentifier: deviceLibraryIdentifier, pushToken: pushToken)

                            return newDevice
                                .create(on: req.db)
                                .flatMap { _ in Self.createRegistration(device: newDevice, pass: pass, req: req) }
                        }
                }
        }
    }

    func passesForDevice(req: Request) throws -> EventLoopFuture<PassesForDeviceDto> {
        logger?.debug("Called passesForDevice")

        let type = req.parameters.get("type")!
        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!

        var query = R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: type, on: req.db)

        if let since: TimeInterval = req.query["passesUpdatedSince"] {
            let when = Date(timeIntervalSince1970: since)
            query = query.filter(P.self, \._$modified > when)
        }

        return query
            .all()
            .flatMapThrowing { registrations in
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
    }

    func latestVersionOfPass(req: Request) throws -> EventLoopFuture<Response> {
        logger?.debug("Called latestVersionOfPass")

        var ifModifiedSince: TimeInterval = 0

        if let header = req.headers[.ifModifiedSince].first, let ims = TimeInterval(header) {
            ifModifiedSince = ims
        }

        guard let type = req.parameters.get("type"),
            let id = req.parameters.get("passSerial", as: UUID.self) else {
                throw Abort(.badRequest)
        }

        return P.query(on: req.db)
            .filter(\._$id == id)
            .filter(\._$type == type)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { pass in
                guard ifModifiedSince < pass.modified.timeIntervalSince1970 else {
                    return req.eventLoop.makeFailedFuture(Abort(.notModified))
                }

                return self.generatePassContent(for: pass, on: req.db)
                    .map { data in
                        let body = Response.Body(data: data)

                        var headers = HTTPHeaders()
                        headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
                        headers.add(name: .lastModified, value: String(pass.modified.timeIntervalSince1970))
                        headers.add(name: .contentTransferEncoding, value: "binary")

                        return Response(status: .ok, headers: headers, body: body)
                }
        }
    }

    func unregisterDevice(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called unregisterDevice")

        let type = req.parameters.get("type")!

        guard let passId = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let deviceLibraryIdentifier = req.parameters.get("deviceLibraryIdentifier")!

        return R.for(deviceLibraryIdentifier: deviceLibraryIdentifier, passTypeIdentifier: type, on: req.db)
            .filter(P.self, \._$id == passId)
            .first()
            .unwrap(or: Abort(.notFound))
            .flatMap { $0.delete(on: req.db).map { .ok } }
    }

    func logError(req: Request) throws -> EventLoopFuture<HTTPStatus> {
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

    func pushUpdatesForPass(req: Request) throws -> EventLoopFuture<HTTPStatus> {
        logger?.debug("Called pushUpdatesForPass")

        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let type = req.parameters.get("type")!

        return Self.sendPushNotificationsForPass(id: id, of: type, on: req.db, app: req.application)
            .map { _ in .noContent }
    }

    func tokensForPassUpdate(req: Request) throws -> EventLoopFuture<[String]> {
        logger?.debug("Called tokensForPassUpdate")

        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }

        let type = req.parameters.get("type")!

        return Self.registrationsForPass(id: id, of: type, on: req.db).map { $0.map { $0.device.pushToken } }
    }

    private static func createRegistration(device: D, pass: P, req: Request) -> EventLoopFuture<HTTPStatus> {
        R.for(deviceLibraryIdentifier: device.deviceLibraryIdentifier, passTypeIdentifier: pass.type, on: req.db)
            .filter(P.self, \._$id == pass.id!)
            .first()
            .flatMap { r in
                if r != nil {
                    // If the registration already exists, docs say to return a 200
                    return req.eventLoop.makeSucceededFuture(.ok)
                }

                let registration = R()
                registration._$pass.id = pass.id!
                registration._$device.id = device.id!

                return registration.create(on: req.db)
                    .map { .created }
        }
    }

    // MARK: - Push Notifications
    public static func sendPushNotificationsForPass(id: UUID, of type: String, on db: Database, app: Application) -> EventLoopFuture<Void> {
        Self.registrationsForPass(id: id, of: type, on: db)
            .flatMap {
                $0.map { reg in
                    let payload = "{}".data(using: .utf8)!
                    var rawBytes = ByteBufferAllocator().buffer(capacity: payload.count)
                    rawBytes.writeBytes(payload)

                    return app.apns.send(rawBytes: rawBytes, pushType: .background, to: reg.device.pushToken, topic: reg.pass.type)
                        .flatMapError {
                            // Unless APNs said it was a bad device token, just ignore the error.
                            guard case let APNSwiftError.ResponseError.badRequest(response) = $0, response == .badDeviceToken else {
                                return db.eventLoop.future()
                            }

                            // Be sure the device deletes before the registration is deleted.
                            // If you let them run in parallel issues might arise depending on
                            // the hooks people have set for when a registration deletes, as it
                            // might try to delete the same device again.
                            return reg.device.delete(on: db)
                                .flatMapError { _ in db.eventLoop.future() }
                                .flatMap { reg.delete(on: db) }
                    }
                }
                .flatten(on: db.eventLoop)
        }
    }

    public static func sendPushNotifications(for pass: P, on db: Database, app: Application) -> EventLoopFuture<Void> {
        guard let id = pass.id else {
            return db.eventLoop.makeFailedFuture(FluentError.idRequired)
        }

        return Self.sendPushNotificationsForPass(id: id, of: pass.type, on: db, app: app)
    }

    public static func sendPushNotifications(for pass: Parent<P>, on db: Database, app: Application) -> EventLoopFuture<Void> {
        let future: EventLoopFuture<P>

        if let eagerLoaded = pass.eagerLoaded {
            future = db.eventLoop.makeSucceededFuture(eagerLoaded)
        } else {
            future = pass.get(on: db)
        }

        return future.flatMap { sendPushNotifications(for: $0, on: db, app: app) }
    }

    private static func registrationsForPass(id: UUID, of type: String, on db: Database) -> EventLoopFuture<[R]> {
        // This could be done by enforcing the caller to have a Siblings property
        // wrapper, but there's not really any value to forcing that on them when
        // we can just do the query ourselves like this.
        R.query(on: db)
            .join(\._$pass)
            .join(\._$device)
            .with(\._$pass)
            .with(\._$device)
            .filter(P.self, \._$type == type)
            .filter(P.self, \._$id == id)
            .all()
    }

    // MARK: - pkpass file generation
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
        var manifest: [String: String] = [:]

        let fm = FileManager()

        #if os(macOS)
        let noDotFiles = NoDotFiles()
        fm.delegate = noDotFiles
        #endif
        
        let paths = try fm.subpathsOfDirectory(atPath: root.unixPath())
        try paths
            .forEach { relativePath in
                let file = URL(fileURLWithPath: relativePath, relativeTo: root)
                guard !file.hasDirectoryPath else {
                    return
                }

                let data = try Data(contentsOf: file)
                let hash = Insecure.SHA1.hash(data: data)
                manifest[relativePath] = hash.description
        }

        let encoded = try encoder.encode(manifest)
        try encoded.write(to: root.appendingPathComponent("manifest.json"))
    }

    private func generateSignatureFile(in root: URL) throws {
        if delegate.generateSignatureFile(in: root) {
            // If the caller's delegate generated a file we don't have to do it.
            return
        }

        // TODO: Is there any way to write this with native libraries instead of spawning a blocking process?
        let proc = Process()
        proc.currentDirectoryURL = delegate.sslSigningFilesDirectory
        proc.executableURL = delegate.sslBinary

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

    private func generatePassContent(for pass: P, on db: Database) -> EventLoopFuture<Data> {
        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipFile = tmp.appendingPathComponent(UUID().uuidString)
        let encoder = JSONEncoder()

        return delegate.template(for: pass, db: db)
            .flatMap { src in
                return self.delegate.encode(pass: pass, db: db, encoder: encoder)
                    .flatMap { encoded in
                        do {
                            // Remember that FileManager isn't thread safe, so don't create it outside and use it here!
                            let fileManager = FileManager()
                            
                            #if os(macOS)
                            let noDotFiles = NoDotFiles()
                            fileManager.delegate = noDotFiles
                            #endif
                            
                            if src.hasDirectoryPath {
                                try fileManager.copyItem(at: src, to: root)
                            } else {
                                try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
                                try fileManager.unzipItem(at: src, to: root)
                            }

                            defer {
                                _ = try? fileManager.removeItem(at: root)
                            }

                            try encoded.write(to: root.appendingPathComponent("pass.json"))

                            try Self.generateManifestFile(using: encoder, in: root)
                            try self.generateSignatureFile(in: root)

                            try fileManager.zipItem(at: root, to: zipFile, shouldKeepParent: false)

                            defer {
                                _ = try? fileManager.removeItem(at: zipFile)
                            }

                            let data = try Data(contentsOf: zipFile)
                            return db.eventLoop.makeSucceededFuture(data)
                        } catch {
                            return db.eventLoop.makeFailedFuture(error)
                        }
                }
        }
    }
}
