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