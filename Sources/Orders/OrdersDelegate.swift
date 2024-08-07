//
//  OrdersDelegate.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 01/07/24.
//

import Foundation
import FluentKit

/// The delegate which is responsible for generating the order files.
public protocol OrdersDelegate: AnyObject, Sendable {
    /// Should return a `URL` which points to the template data for the order.
    ///
    /// The URL should point to a directory containing all the images and localizations for the generated `.order` archive but should *not* contain any of these items:
    ///  - `manifest.json`
    ///  - `order.json`
    ///  - `signature`
    ///
    /// - Parameters:
    ///   - for: The order data from the SQL server.
    ///   - db: The SQL database to query against.
    ///
    /// - Returns: A `URL` which points to the template data for the order.
    ///
    /// > Important: Be sure to use the `URL(fileURLWithPath:isDirectory:)` constructor.
    func template<O: OrderModel>(for: O, db: any Database) async throws -> URL

    /// Generates the SSL `signature` file.
    ///
    /// If you need to implement custom S/Mime signing you can use this
    /// method to do so. You must generate a detached DER signature of the `manifest.json` file.
    ///
    /// - Parameter root: The location of the `manifest.json` and where to write the `signature` to.
    /// - Returns: Return `true` if you generated a custom `signature`, otherwise `false`.
    func generateSignatureFile(in root: URL) -> Bool

    /// Encode the order into JSON.
    ///
    /// This method should generate the entire order JSON. You are provided with
    /// the order data from the SQL database and you should return a properly
    /// formatted order file encoding.
    ///
    /// - Parameters:
    ///   - order: The order data from the SQL server
    ///   - db: The SQL database to query against.
    ///   - encoder: The `JSONEncoder` which you should use.
    /// - Returns: The encoded order JSON data.
    ///
    /// > Tip: See the [`Order`](https://developer.apple.com/documentation/walletorders/order) object to understand the keys.
    func encode<O: OrderModel>(order: O, db: any Database, encoder: JSONEncoder) async throws -> Data

    /// Should return a `URL` which points to the template data for the order.
    ///
    /// The URL should point to a directory containing the files specified by these keys:
    /// - `wwdrCertificate`
    /// - `pemCertificate`
    /// - `pemPrivateKey`
    ///
    /// > Important: Be sure to use the `URL(fileURLWithPath:isDirectory:)` initializer!
    var sslSigningFilesDirectory: URL { get }

    /// The location of the `openssl` command as a file URL.
    ///
    /// > Important: Be sure to use the `URL(fileURLWithPath:)` constructor.
    var sslBinary: URL { get }

    /// The full path to the `zip` command as a file URL.
    /// 
    /// > Important: Be sure to use the `URL(fileURLWithPath:)` constructor.
    var zipBinary: URL { get }
    
    /// The name of Apple's WWDR.pem certificate as contained in `sslSigningFiles` path.
    ///
    /// Defaults to `WWDR.pem`
    var wwdrCertificate: String { get }

    /// The name of the PEM Certificate for signing the order as contained in `sslSigningFiles` path.
    ///
    /// Defaults to `ordercertificate.pem`
    var pemCertificate: String { get }

    /// The name of the PEM Certificate's private key for signing the order as contained in `sslSigningFiles` path.
    ///
    /// Defaults to `orderkey.pem`
    var pemPrivateKey: String { get }

    /// The password to the private key file.
    var pemPrivateKeyPassword: String? { get }
}

public extension OrdersDelegate {
    var wwdrCertificate: String {
        get { return "WWDR.pem" }
    }

    var pemCertificate: String {
        get { return "ordercertificate.pem" }
    }

    var pemPrivateKey: String {
        get { return "orderkey.pem" }
    }

    var pemPrivateKeyPassword: String? {
        get { return nil }
    }

    var sslBinary: URL {
        get { return URL(fileURLWithPath: "/usr/bin/openssl") }
    }

    var zipBinary: URL {
        get { return URL(fileURLWithPath: "/usr/bin/zip") }
    }
    
    func generateSignatureFile(in root: URL) -> Bool {
        return false
    }
}
