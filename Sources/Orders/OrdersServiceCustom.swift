//
//  OrdersServiceCustom.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

import Foundation
import Crypto
import APNS
import APNSCore
import FluentKit
import NIOSSL
import PassKit

/// Class to handle ``OrdersService``.
///
/// The generics should be passed in this order:
/// - Order Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public final class OrdersServiceCustom<O, D, R: OrdersRegistrationModel, E: ErrorLogModel>: Sendable where O == R.OrderType, D == R.DeviceType {
    let delegate: any OrdersDelegate
    let logger: Logger?
    private let apnsClient: APNSClient<JSONDecoder, JSONEncoder>
    
    /// Initializes the service.
    ///
    /// - Parameters:
    ///   - delegate: The ``OrdersDelegate`` to use for order generation.
    ///   - logger: The `Logger` to use.
    public init(delegate: any OrdersDelegate, logger: Logger? = nil) throws {
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
    private static func generateManifestFile(using encoder: JSONEncoder, in root: URL) throws {
        var manifest: [String: String] = [:]

        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.unixPath())
        try paths.forEach { relativePath in
            let file = URL(fileURLWithPath: relativePath, relativeTo: root)
            guard !file.hasDirectoryPath else { return }
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data)
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

        try Self.generateManifestFile(using: encoder, in: root)
        try self.generateSignatureFile(in: root)

        let zipFile = tmp.appendingPathComponent("\(UUID().uuidString).zip")
        try self.zip(directory: root, to: zipFile)
        defer { _ = try? FileManager.default.removeItem(at: zipFile) }

        return try Data(contentsOf: zipFile)
    }
}
