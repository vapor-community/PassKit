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

final public class PKDevice: PassKitDevice {
    public static let schema = "devices"

    @ID(key: "id")
    public var id: Int?

    @Field(key: "push_token")
    public var pushToken: String

    @Field(key: "device_library_identifier")
    public var deviceLibraryIdentifier: String

    public init(deviceLibraryIdentifier: String, pushToken: String) {
        self.deviceLibraryIdentifier = deviceLibraryIdentifier
        self.pushToken = pushToken
    }

    public init() {}
}

extension PKDevice: Migration {
    public func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema)
            .field("id", .int, .identifier(auto: true))
            .field("push_token", .string, .required)
            .field("device_library_identifier", .string, .required)
            .unique(on: "push_token", "device_library_identifier")
            .create()
    }

    public func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema).delete()
    }
}

open class PKPass: PassKitPass {
    public static let schema = "passes"

    @ID(key: "id")
    public var id: UUID?

    @Field(key: "modified")
    public var modified: Date

    @Field(key: "type_identifier")
    public var type: String

    public required init() {
        self.modified = Date()
    }
}

extension PKPass: Migration {
    public func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("modified", .datetime, .required)
            .field("type_identifier", .string, .required)
            .create()
    }

    public func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema).delete()
    }
}

final public class PKErrorLog: PassKitErrorLog {
    public static let schema = "errors"

    @ID(key: "id")
    public var id: Int?

    @Field(key: "created")
    public var date: Date

    @Field(key: "message")
    public var message: String

    public init(message: String) {
        date = Date()
        self.message = message
    }

    public init() {}
}

extension PKErrorLog: Migration {
    public func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema)
            .field("id", .int, .identifier(auto: true))
            .field("created", .datetime, .required)
            .field("message", .string, .required)
            .create()
    }

    public func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(PKErrorLog.schema).delete()
    }
}

final public class PKRegistration: PassKitRegistration {
    public typealias PassType = PKPass
    public typealias DeviceType = PKDevice

    public static let schema = "registrations"

    @ID(key: "id")
    public var id: Int?

    @Parent(key: "device_id")
    public var device: DeviceType

    @Parent(key: "pass_id")
    public var pass: PassType

    public init() {}
}

extension PKRegistration: Migration {
    public func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema)
            .field("id", .int, .identifier(auto: true))
            .field("device_id", .int, .required)
            .field("pass_id", .uuid, .required)
            .foreignKey("device_id", references: PKDevice.schema, "id", onDelete: .cascade)
            .foreignKey("pass_id", references: PKPass.schema, "id", onDelete: .cascade)
            .create()
    }

    public func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema).delete()
    }
}
