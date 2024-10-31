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

import FluentKit
import Foundation

/// Represents the `Model` that stores PassKit passes.
///
/// Uses a UUID so people can't easily guess pass serial numbers.
public protocol PassModel: Model where IDValue == UUID {
    associatedtype UserPersonalizationType: UserPersonalizationModel

    /// The pass type identifier that’s registered with Apple.
    var typeIdentifier: String { get set }

    /// The last time the pass was modified.
    var updatedAt: Date? { get set }

    /// The authentication token to use with the web service in the `webServiceURL` key.
    var authenticationToken: String { get set }

    /// The user personalization info.
    var userPersonalization: UserPersonalizationType? { get set }

    /// The designated initializer.
    /// - Parameters:
    ///   - typeIdentifier: The pass type identifier that’s registered with Apple.
    ///   - authenticationToken: The authentication token to use with the web service in the `webServiceURL` key.
    init(typeIdentifier: String, authenticationToken: String)
}

extension PassModel {
    var _$id: ID<UUID> {
        guard let mirror = Mirror(reflecting: self).descendant("_id"),
            let id = mirror as? ID<UUID>
        else {
            fatalError("id property must be declared using @ID")
        }

        return id
    }

    var _$typeIdentifier: Field<String> {
        guard let mirror = Mirror(reflecting: self).descendant("_typeIdentifier"),
            let typeIdentifier = mirror as? Field<String>
        else {
            fatalError("typeIdentifier property must be declared using @Field")
        }

        return typeIdentifier
    }

    var _$updatedAt: Timestamp<DefaultTimestampFormat> {
        guard let mirror = Mirror(reflecting: self).descendant("_updatedAt"),
            let updatedAt = mirror as? Timestamp<DefaultTimestampFormat>
        else {
            fatalError("updatedAt property must be declared using @Timestamp(on: .update)")
        }

        return updatedAt
    }

    var _$authenticationToken: Field<String> {
        guard let mirror = Mirror(reflecting: self).descendant("_authenticationToken"),
            let authenticationToken = mirror as? Field<String>
        else {
            fatalError("authenticationToken property must be declared using @Field")
        }

        return authenticationToken
    }

    var _$userPersonalization: OptionalParent<UserPersonalizationType> {
        guard let mirror = Mirror(reflecting: self).descendant("_userPersonalization"),
            let userPersonalization = mirror as? OptionalParent<UserPersonalizationType>
        else {
            fatalError("userPersonalization property must be declared using @OptionalParent")
        }

        return userPersonalization
    }
}
