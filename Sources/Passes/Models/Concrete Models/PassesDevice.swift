//
//  PassesDevice.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 29/06/24.
//

import FluentKit
import PassKit

/// The `Model` that stores PassKit passes devices.
final public class PassesDevice: DeviceModel, @unchecked Sendable {
    /// The schema name of the device model.
    public static let schema = PassesDevice.FieldKeys.schemaName

    @ID(custom: .id)
    public var id: Int?

    /// The push token used for sending updates to the device.
    @Field(key: PassesDevice.FieldKeys.pushToken)
    public var pushToken: String

    /// The identifier PassKit provides for the device.
    @Field(key: PassesDevice.FieldKeys.libraryIdentifier)
    public var libraryIdentifier: String

    public init(libraryIdentifier: String, pushToken: String) {
        self.libraryIdentifier = libraryIdentifier
        self.pushToken = pushToken
    }

    public init() {}
}

extension PassesDevice: AsyncMigration {
    public func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
            .field(.id, .int, .identifier(auto: true))
            .field(PassesDevice.FieldKeys.pushToken, .string, .required)
            .field(PassesDevice.FieldKeys.libraryIdentifier, .string, .required)
            .unique(on: PassesDevice.FieldKeys.pushToken, PassesDevice.FieldKeys.libraryIdentifier)
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
        static let libraryIdentifier = FieldKey(stringLiteral: "library_identifier")
    }
}
