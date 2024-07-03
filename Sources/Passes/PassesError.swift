//
//  PassesError.swift
//  PassKit
//
//  Created by Scott Grosch on 1/22/20.
//

/// Errors that can be thrown by the `Passes` module.
public enum PassesError: Error {
    /// The template path is not a directory
    case templateNotDirectory

    /// The `pemCertificate` file is missing.
    case pemCertificateMissing

    /// The `pemPrivateKey` file is missing.
    case pemPrivateKeyMissing

    /// The path to the zip binary is incorrect.
    case zipBinaryMissing

    /// The path to the openssl binary is incorrect
    case opensslBinaryMissing
}
