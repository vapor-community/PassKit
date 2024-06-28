/// Copyright 2020 Gargoyle Software, LLC
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import Vapor
import Fluent
import PassKit

/// The `Model` that stores PassKit devices.
final public class PassesDevice: DeviceModel, @unchecked Sendable {
    public static let schema = PassesDevice.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    @Field(key: PassesDevice.FieldKeys.pushToken)
    public var pushToken: String

    @Field(key: PassesDevice.FieldKeys.deviceLibraryIdentifier)
    public var deviceLibraryIdentifier: String

    public init(deviceLibraryIdentifier: String, pushToken: String) {
        self.deviceLibraryIdentifier = deviceLibraryIdentifier
        self.pushToken = pushToken
    }

    public init() {}
}

extension PassesDevice: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(PassesDevice.FieldKeys.pushToken, .string, .required)
            .field(PassesDevice.FieldKeys.deviceLibraryIdentifier, .string, .required)
            .unique(on: PassesDevice.FieldKeys.pushToken, PassesDevice.FieldKeys.deviceLibraryIdentifier)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension PassesDevice {
    enum FieldKeys {
        static let schemaName = "passes_devices"
        static let pushToken = FieldKey(stringLiteral: "push_token")
        static let deviceLibraryIdentifier = FieldKey(stringLiteral: "device_library_identifier")
    }
}

/// The `Model` that stores PassKit passes.
open class PKPass: PassModel, @unchecked Sendable {
    public static let schema = PKPass.FieldKeys.schemaName

    @ID
    public var id: UUID?

    @Timestamp(key: PKPass.FieldKeys.updatedAt, on: .update)
    public var updatedAt: Date?

    @Field(key: PKPass.FieldKeys.passTypeIdentifier)
    public var passTypeIdentifier: String

    @Field(key: PKPass.FieldKeys.authenticationToken)
    public var authenticationToken: String
    
    public required init() { }

    public required init(passTypeIdentifier: String, authenticationToken: String) {
        self.passTypeIdentifier = passTypeIdentifier
        self.authenticationToken = authenticationToken
    }
}

extension PKPass: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field(PKPass.FieldKeys.updatedAt, .datetime, .required)
            .field(PKPass.FieldKeys.passTypeIdentifier, .string, .required)
            .field(PKPass.FieldKeys.authenticationToken, .string, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension PKPass {
    enum FieldKeys {
        static let schemaName = "passes"
        static let updatedAt = FieldKey(stringLiteral: "updated_at")
        static let passTypeIdentifier = FieldKey(stringLiteral: "pass_type_identifier")
        static let authenticationToken = FieldKey(stringLiteral: "authentication_token")
    }
}

/// The `Model` that stores PassKit error logs.
final public class PassesErrorLog: ErrorLogModel, @unchecked Sendable {
    public static let schema = PassesErrorLog.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    @Timestamp(key: PassesErrorLog.FieldKeys.createdAt, on: .create)
    public var createdAt: Date?

    @Field(key: PassesErrorLog.FieldKeys.message)
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public init() {}
}

extension PassesErrorLog: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(PassesErrorLog.FieldKeys.createdAt, .datetime, .required)
            .field(PassesErrorLog.FieldKeys.message, .string, .required)
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension PassesErrorLog {
    enum FieldKeys {
        static let schemaName = "passes_errors"
        static let createdAt = FieldKey(stringLiteral: "created_at")
        static let message = FieldKey(stringLiteral: "message")
    }
}

/// The `Model` that stores passes registrations.
final public class PassesRegistration: PassesRegistrationModel, @unchecked Sendable {
    public typealias PassType = PKPass
    public typealias DeviceType = PassesDevice

    public static let schema = PassesRegistration.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    @Parent(key: PassesRegistration.FieldKeys.deviceID)
    public var device: DeviceType

    @Parent(key: PassesRegistration.FieldKeys.passID)
    public var pass: PassType

    public init() {}
}

extension PassesRegistration: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(PassesRegistration.FieldKeys.deviceID, .int, .required, .references(DeviceType.schema, .id, onDelete: .cascade))
            .field(PassesRegistration.FieldKeys.passID, .uuid, .required, .references(PassType.schema, .id, onDelete: .cascade))
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}

extension PassesRegistration {
    enum FieldKeys {
        static let schemaName = "passes_registrations"
        static let deviceID = FieldKey(stringLiteral: "device_id")
        static let passID = FieldKey(stringLiteral: "pass_id")
    }
}
