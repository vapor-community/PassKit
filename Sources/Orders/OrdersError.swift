//
//  OrdersError.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 04/07/24.
//

/// Errors that can be thrown by Apple Wallet orders.
public struct OrdersError: Error, Sendable {
    /// The type of the errors that can be thrown by Apple Wallet orders.
    public struct ErrorType: Sendable, Hashable, CustomStringConvertible {
        enum Base: String, Sendable {
            case templateNotDirectory
            case pemCertificateMissing
            case pemPrivateKeyMissing
            case opensslBinaryMissing
        }
        
        let base: Base
        
        private init(_ base: Base) {
            self.base = base
        }
        
        /// The template path is not a directory.
        public static let templateNotDirectory = Self(.templateNotDirectory)
        /// The `pemCertificate` file is missing.
        public static let pemCertificateMissing = Self(.pemCertificateMissing)
        /// The `pemPrivateKey` file is missing.
        public static let pemPrivateKeyMissing = Self(.pemPrivateKeyMissing)
        /// The path to the `openssl` binary is incorrect.
        public static let opensslBinaryMissing = Self(.opensslBinaryMissing)

        /// A textual representation of this error.
        public var description: String {
            base.rawValue
        }
    }
    
    private struct Backing: Sendable {
        fileprivate let errorType: ErrorType
        
        init(errorType: ErrorType) {
            self.errorType = errorType
        }
    }
    
    private var backing: Backing

    /// The type of this error.
    public var errorType: ErrorType { backing.errorType }

    private init(errorType: ErrorType) {
        self.backing = .init(errorType: errorType)
    }
    
    /// The template path is not a directory.
    public static let templateNotDirectory = Self(errorType: .templateNotDirectory)

    /// The `pemCertificate` file is missing.
    public static let pemCertificateMissing = Self(errorType: .pemCertificateMissing)

    /// The `pemPrivateKey` file is missing.
    public static let pemPrivateKeyMissing = Self(errorType: .pemPrivateKeyMissing)

    /// The path to the `openssl` binary is incorrect.
    public static let opensslBinaryMissing = Self(errorType: .opensslBinaryMissing)
}

extension OrdersError: CustomStringConvertible {
    public var description: String {
        "OrdersError(errorType: \(self.errorType))"
    }
}
