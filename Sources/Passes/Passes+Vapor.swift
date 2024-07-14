//
//  Passes+Vapor.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 14/07/24.
//

import Vapor
import Fluent
import PassKit

extension PassesService {
    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to setup the routes.
    ///   - pushMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    public func registerRoutes(app: Application, pushMiddleware: (any Middleware)? = nil) {
        service.registerRoutes(app: app, pushMiddleware: pushMiddleware)
    }
}

extension PassesServiceCustom {
    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to setup the routes.
    ///   - pushMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    public func registerRoutes(app: Application, pushMiddleware: (any Middleware)? = nil) {
        let v1 = app.grouped("api", "passes", "v1")
        v1.get("devices", ":deviceLibraryIdentifier", "registrations", ":passTypeIdentifier", use: { try await self.passesForDevice(req: $0) })
        v1.post("log", use: { try await self.logError(req: $0) })

        let v1auth = v1.grouped(ApplePassMiddleware<P>())
        v1auth.post("devices", ":deviceLibraryIdentifier", "registrations", ":passTypeIdentifier", ":passSerial", use: { try await self.registerDevice(req: $0) })
        v1auth.get("passes", ":passTypeIdentifier", ":passSerial", use: { try await self.latestVersionOfPass(req: $0) })
        v1auth.delete("devices", ":deviceLibraryIdentifier", "registrations", ":passTypeIdentifier", ":passSerial", use: { try await self.unregisterDevice(req: $0) })
        v1auth.post("passes", ":passTypeIdentifier", ":passSerial", "personalize", use: { try await self.personalizedPass(req: $0) })

        if let pushMiddleware {
            let pushAuth = v1.grouped(pushMiddleware)
            pushAuth.post("push", ":passTypeIdentifier", ":passSerial", use: {try await self.pushUpdatesForPass(req: $0) })
            pushAuth.get("push", ":passTypeIdentifier", ":passSerial", use: { try await self.tokensForPassUpdate(req: $0) })
        }
    }
}

// MARK: - API Routes
extension PassesServiceCustom {
    func registerDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called register device")
        
        let pushToken: String
        do {
            pushToken = try req.content.decode(RegistrationDTO.self).pushToken
        } catch {
            throw Abort(.badRequest)
        }
        
        guard let serial = req.parameters.get("passSerial", as: UUID.self) else {
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
        // If the registration already exists, docs say to return 200 OK
        if r != nil { return .ok }

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
        
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
        headers.add(name: .lastModified, value: String(pass.updatedAt?.timeIntervalSince1970 ?? 0))
        headers.add(name: .contentTransferEncoding, value: "binary")
        return try await Response(
            status: .ok,
            headers: headers,
            body: Response.Body(data: self.generatePassContent(for: pass, on: req.db))
        )
    }
    
    func unregisterDevice(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called unregisterDevice")

        guard let passId = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!
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

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/octet-stream")
        headers.add(name: .contentTransferEncoding, value: "binary")
        return try Response(
            status: .ok,
            headers: headers,
            body: Response.Body(data: Data(contentsOf: root.appendingPathComponent("signature")))
        )
    }
    
    // MARK: - Push Routes
    func pushUpdatesForPass(req: Request) async throws -> HTTPStatus {
        logger?.debug("Called pushUpdatesForPass")

        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!

        try await sendPushNotificationsForPass(id: id, of: passTypeIdentifier, on: req.db)
        return .noContent
    }
    
    func tokensForPassUpdate(req: Request) async throws -> [String] {
        logger?.debug("Called tokensForPassUpdate")

        guard let id = req.parameters.get("passSerial", as: UUID.self) else {
            throw Abort(.badRequest)
        }
        let passTypeIdentifier = req.parameters.get("passTypeIdentifier")!

        return try await Self.registrationsForPass(id: id, of: passTypeIdentifier, on: req.db)
            .map { $0.device.pushToken }
    }
}