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

/// The delegate which is responsible for generating the pass files.
public protocol PassesDelegate: AnyObject, Sendable {
    /// Should return a URL path which points to the template data for the pass.
    ///
    /// The path should point to a directory containing all the images and localizations for the generated `.pkpass` archive
    /// but should *not* contain any of these items:
    ///  - `manifest.json`
    ///  - `pass.json`
    ///  - `personalization.json`
    ///  - `signature`
    ///
    /// - Parameters:
    ///   - pass: The pass data from the SQL server.
    ///   - db: The SQL database to query against.
    ///
    /// - Returns: A URL path which points to the template data for the pass.
    func template<P: PassModel>(for pass: P, db: any Database) async throws -> String

    /// Generates the SSL `signature` file.
    ///
    /// If you need to implement custom S/Mime signing you can use this
    /// method to do so. You must generate a detached DER signature of the `manifest.json` file.
    ///
    /// - Parameter root: The location of the `manifest.json` and where to write the `signature` to.
    /// - Returns: Return `true` if you generated a custom `signature`, otherwise `false`.
    func generateSignatureFile(in root: URL) -> Bool

    /// Encode the pass into JSON.
    ///
    /// This method should generate the entire pass JSON. You are provided with
    /// the pass data from the SQL database and you should return a properly
    /// formatted pass file encoding.
    ///
    /// - Parameters:
    ///   - pass: The pass data from the SQL server
    ///   - db: The SQL database to query against.
    ///   - encoder: The `JSONEncoder` which you should use.
    /// - Returns: The encoded pass JSON data.
    ///
    /// > Tip: See the [`Pass`](https://developer.apple.com/documentation/walletpasses/pass) object to understand the keys.
    func encode<P: PassModel>(pass: P, db: any Database, encoder: JSONEncoder) async throws -> Data

    /// Create the personalization JSON struct.
    ///
    /// This method of the ``PassesDelegate`` should generate the entire personalization JSON struct.
    /// You are provided with the pass data from the SQL database and,
    /// if the pass in question requires personalization,
    /// you should return a ``PersonalizationJSON``.
    ///
    /// If the pass does not require personalization, you should return `nil`.
    ///
    /// The default implementation of this method returns `nil`.
    ///
    /// - Parameters:
    ///   - pass: The pass data from the SQL server.
    ///   - db: The SQL database to query against.
    /// - Returns: A ``PersonalizationJSON`` or `nil` if the pass does not require personalization.
    func personalizationJSON<P: PassModel>(for pass: P, db: any Database) async throws -> PersonalizationJSON?
}

extension PassesDelegate {
    public func generateSignatureFile(in root: URL) -> Bool {
        return false
    }

    public func personalizationJSON<P: PassModel>(for pass: P, db: any Database) async throws -> PersonalizationJSON? {
        return nil
    }
}
