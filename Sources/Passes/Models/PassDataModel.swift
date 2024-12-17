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

/// Represents the `Model` that stores custom app data associated to Apple Wallet passes.
public protocol PassDataModel: Model {
    associatedtype PassType: PassModel

    /// The pass type identifier that’s registered with Apple.
    static var typeIdentifier: String { get }

    /// The foreign key to the pass table.
    var pass: PassType { get set }

    /// Encode the pass into JSON.
    ///
    /// This method should generate the entire pass JSON.
    ///
    /// - Parameter db: The SQL database to query against.
    ///
    /// - Returns: An object that conforms to ``PassJSON/Properties``.
    ///
    /// > Tip: See the [`Pass`](https://developer.apple.com/documentation/walletpasses/pass) object to understand the keys.
    func passJSON(on db: any Database) async throws -> any PassJSON.Properties

    /// Should return a URL path which points to the template data for the pass.
    ///
    /// The path should point to a directory containing all the images and localizations for the generated `.pkpass` archive
    /// but should *not* contain any of these items:
    ///  - `manifest.json`
    ///  - `pass.json`
    ///  - `personalization.json`
    ///  - `signature`
    ///
    /// - Parameter db: The SQL database to query against.
    ///
    /// - Returns: A URL path which points to the template data for the pass.
    func template(on db: any Database) async throws -> String

    /// Create the personalization JSON struct.
    ///
    /// This method should generate the entire personalization JSON struct.
    /// If the pass in question requires personalization, you should return a ``PersonalizationJSON``.
    /// If the pass does not require personalization, you should return `nil`.
    ///
    /// The default implementation of this method returns `nil`.
    ///
    /// - Parameter db: The SQL database to query against.
    ///
    /// - Returns: A ``PersonalizationJSON`` or `nil` if the pass does not require personalization.
    func personalizationJSON(on db: any Database) async throws -> PersonalizationJSON?
}

extension PassDataModel {
    var _$pass: Parent<PassType> {
        guard let mirror = Mirror(reflecting: self).descendant("_pass"),
            let pass = mirror as? Parent<PassType>
        else {
            fatalError("pass property must be declared using @Parent")
        }

        return pass
    }
}

extension PassDataModel {
    public func personalizationJSON(on db: any Database) async throws -> PersonalizationJSON? { nil }
}
