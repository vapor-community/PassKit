//
//  File.swift
//  
//
//  Created by Scott Grosch on 1/22/20.
//

import Foundation

public enum PassKitError: Error {
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
