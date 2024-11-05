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
            case noSourceFiles
            case noOpenSSLExecutable
        }

        let base: Base

        private init(_ base: Base) {
            self.base = base
        }

        /// The path for the source files is not a directory.
        public static let noSourceFiles = Self(.noSourceFiles)
        /// The `openssl` executable is missing.
        public static let noOpenSSLExecutable = Self(.noOpenSSLExecutable)

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

    /// The path for the source files is not a directory.
    public static let noSourceFiles = Self(errorType: .noSourceFiles)

    /// The `openssl` executable is missing.
    public static let noOpenSSLExecutable = Self(errorType: .noOpenSSLExecutable)
}

extension OrdersError: CustomStringConvertible {
    public var description: String {
        "OrdersError(errorType: \(self.errorType))"
    }
}
