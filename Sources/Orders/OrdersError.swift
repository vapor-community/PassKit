//
//  OrdersError.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

public enum OrdersError: Error {
    /// The template path is not a directory
    case templateNotDirectory

    /// The `pemCertificate` file is missing.
    case pemCertificateMissing

    /// The `pemPrivateKey` file is missing.
    case pemPrivateKeyMissing

    /// Swift NIO failed to read the key.
    case nioPrivateKeyReadFailed(any Error)

    /// The path to the zip binary is incorrect.
    case zipBinaryMissing

    /// The path to the openssl binary is incorrect
    case opensslBinaryMissing
}