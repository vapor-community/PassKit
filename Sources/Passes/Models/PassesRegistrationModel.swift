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
import PassKit

/// Represents the `Model` that stores passes registrations.
public protocol PassesRegistrationModel: Model where IDValue == Int {
    associatedtype PassType: PassModel
    associatedtype DeviceType: DeviceModel

    /// The device for this registration.
    var device: DeviceType { get set }

    /// The pass for this registration.
    var pass: PassType { get set }
}

extension PassesRegistrationModel {
    var _$device: Parent<DeviceType> {
        guard let mirror = Mirror(reflecting: self).descendant("_device"),
            let device = mirror as? Parent<DeviceType>
        else {
            fatalError("device property must be declared using @Parent")
        }

        return device
    }

    var _$pass: Parent<PassType> {
        guard let mirror = Mirror(reflecting: self).descendant("_pass"),
            let pass = mirror as? Parent<PassType>
        else {
            fatalError("pass property must be declared using @Parent")
        }

        return pass
    }

    static func `for`(deviceLibraryIdentifier: String, typeIdentifier: String, on db: any Database) -> QueryBuilder<Self> {
        Self.query(on: db)
            .join(parent: \._$pass)
            .join(parent: \._$device)
            .with(\._$pass)
            .with(\._$device)
            .filter(PassType.self, \._$typeIdentifier == typeIdentifier)
            .filter(DeviceType.self, \._$deviceLibraryIdentifier == deviceLibraryIdentifier)
    }
}
