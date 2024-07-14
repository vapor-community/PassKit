//
//  PassesServiceCustom.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 29/06/24.
//

import Foundation
import Crypto
import APNS
import APNSCore
import FluentKit
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
    let delegate: any PassesDelegate
    let logger: Logger?
    private let apnsClient: APNSClient<JSONDecoder, JSONEncoder>
    
    /// Initializes the service.
    ///
    /// - Parameters:
    ///   - delegate: The ``PassesDelegate`` to use for pass generation.
    ///   - logger: The `Logger` to use.
    public init(delegate: any PassesDelegate, logger: Logger? = nil) throws {
        self.delegate = delegate
        self.logger = logger

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
        apnsClient = APNSClient(
            configuration: apnsConfig,
            eventLoopGroupProvider: .createNew,
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder()
        )
    }
    
    deinit {
        apnsClient.shutdown { _ in
            self.logger?.error("Failed to shutdown APNSClient")
        }
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
    public func sendPushNotificationsForPass(id: UUID, of passTypeIdentifier: String, on db: any Database) async throws {
        let registrations = try await Self.registrationsForPass(id: id, of: passTypeIdentifier, on: db)
        for reg in registrations {
            let backgroundNotification = APNSBackgroundNotification(
                expiration: .immediately,
                topic: reg.pass.passTypeIdentifier,
                payload: PassKit.Payload()
            )
            do {
                try await apnsClient.sendBackgroundNotification(
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
    public func sendPushNotifications(for pass: P, on db: any Database) async throws {
        try await sendPushNotificationsForPass(id: pass.requireID(), of: pass.passTypeIdentifier, on: db)
    }
    
    /// Sends push notifications for a given pass.
    /// 
    /// - Parameters:
    ///   - pass: The pass (as the `ParentProperty`) to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for pass: ParentProperty<R, P>, on db: any Database) async throws {
        let value: P
        if let eagerLoaded = pass.value {
            value = eagerLoaded
        } else {
            value = try await pass.get(on: db)
        }
        try await sendPushNotifications(for: value, on: db)
    }
    
    static func registrationsForPass(id: UUID, of passTypeIdentifier: String, on db: any Database) async throws -> [R] {
        // This could be done by enforcing the caller to have a Siblings property wrapper,
        // but there's not really any value to forcing that on them when we can just do the query ourselves like this.
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
        
        try encoder.encode(manifest)
            .write(to: root.appendingPathComponent("manifest.json"))
    }
    
    private func generateSignatureFile(in root: URL) throws {
        // If the caller's delegate generated a file we don't have to do it.
        if delegate.generateSignatureFile(in: root) { return }

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
        let src = try await delegate.template(for: pass, db: db)
        guard (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false else {
            throw PassesError.templateNotDirectory
        }

        let tmp = FileManager.default.temporaryDirectory
        let root = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.copyItem(at: src, to: root)
        defer { _ = try? FileManager.default.removeItem(at: root) }
        
        let encoder = JSONEncoder()
        try await self.delegate.encode(pass: pass, db: db, encoder: encoder)
            .write(to: root.appendingPathComponent("pass.json"))

        // Pass Personalization
        if let encodedPersonalization = try await self.delegate.encodePersonalization(for: pass, db: db, encoder: encoder) {
            try encodedPersonalization.write(to: root.appendingPathComponent("personalization.json"))
        }
        
        try Self.generateManifestFile(using: encoder, in: root)
        try self.generateSignatureFile(in: root)

        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        try self.zip(directory: root, to: zipFile)
        defer { _ = try? FileManager.default.removeItem(at: zipFile) }

        return try Data(contentsOf: zipFile)
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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { _ = try? FileManager.default.removeItem(at: root) }
        
        for (i, pass) in passes.enumerated() {
            try await self.generatePassContent(for: pass, on: db)
                .write(to: root.appendingPathComponent("pass\(i).pkpass"))
        }

        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        try self.zip(directory: root, to: zipFile)
        defer { _ = try? FileManager.default.removeItem(at: zipFile) }

        return try Data(contentsOf: zipFile)
    }
}
