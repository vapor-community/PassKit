//
//  PassesError.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 04/07/24.
//

/// Errors that can be thrown by PassKit passes.
public struct PassesError: Error, Sendable, Equatable {
    /// The type of the errors that can be thrown by PassKit passes.
    public struct ErrorType: Sendable, Hashable, CustomStringConvertible, Equatable {
        enum Base: String, Sendable, Equatable {
            case noSourceFiles
            case noOpenSSLExecutable
            case invalidNumberOfPasses
        }

        let base: Base

        private init(_ base: Base) {
            self.base = base
        }

        /// The path for the source files is not a directory.
        public static let noSourceFiles = Self(.noSourceFiles)
        /// The `openssl` executable is missing.
        public static let noOpenSSLExecutable = Self(.noOpenSSLExecutable)
        /// The number of passes to bundle is invalid.
        public static let invalidNumberOfPasses = Self(.invalidNumberOfPasses)

        /// A textual representation of this error.
        public var description: String {
            base.rawValue
        }
    }

    private struct Backing: Sendable, Equatable {
        fileprivate let errorType: ErrorType

        init(errorType: ErrorType) {
            self.errorType = errorType
        }

        static func == (lhs: PassesError.Backing, rhs: PassesError.Backing) -> Bool {
            lhs.errorType == rhs.errorType
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

    /// The number of passes to bundle is invalid.
    public static let invalidNumberOfPasses = Self(errorType: .invalidNumberOfPasses)

    public static func == (lhs: PassesError, rhs: PassesError) -> Bool {
        lhs.backing == rhs.backing
    }
}

extension PassesError: CustomStringConvertible {
    public var description: String {
        "PassesError(errorType: \(self.errorType))"
    }
}
