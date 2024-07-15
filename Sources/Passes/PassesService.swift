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
import FluentKit

/// The main class that handles PassKit passes.
public final class PassesService: Sendable {
    let service: PassesServiceCustom<PKPass, UserPersonalization, PassesDevice, PassesRegistration, PassesErrorLog>
    
    /// Initializes the service.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to use for APNs.
    ///   - delegate: The ``PassesDelegate`` to use for pass generation.
    ///   - logger: The `Logger` to use.
    public init(app: Application, delegate: any PassesDelegate, logger: Logger? = nil) throws {
        service = try .init(app: app, delegate: delegate, logger: logger)
    }

    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Vapor.Application` to setup the routes.
    ///   - pushMiddleware: The `Middleware` to use for push notification routes. If `nil`, push routes will not be registered.
    public func registerRoutes(app: Application, pushMiddleware: (any Middleware)? = nil) {
        service.registerRoutes(app: app, pushMiddleware: pushMiddleware)
    }

    /// Generates the pass content bundle for a given pass.
    ///
    /// - Parameters:
    ///   - pass: The pass to generate the content for.
    ///   - db: The `Database` to use.
    /// - Returns: The generated pass content as `Data`.
    public func generatePassContent(for pass: PKPass, on db: any Database) async throws -> Data {
        try await service.generatePassContent(for: pass, on: db)
    }

    /// Generates a bundle of passes to enable your user to download multiple passes at once.
    ///
    /// > Note: You can have up to 10 passes or 150 MB for a bundle of passes.
    ///
    /// > Important: Bundles of passes are supported only in Safari. You can't send the bundle via AirDrop or other methods.
    ///
    /// - Parameters:
    ///   - passes: The passes to include in the bundle.
    ///   - db: The `Database` to use.
    /// - Returns: The bundle of passes as `Data`.
    public func generatePassesContent(for passes: [PKPass], on db: any Database) async throws -> Data {
        try await service.generatePassesContent(for: passes, on: db)
    }
    
    /// Adds the migrations for PassKit passes models.
    ///
    /// - Parameter migrations: The `Migrations` object to add the migrations to.
    public static func register(migrations: Migrations) {
        migrations.add(UserPersonalization())
        migrations.add(PKPass())
        migrations.add(PassesDevice())
        migrations.add(PassesRegistration())
        migrations.add(PassesErrorLog())
    }
    
    /// Sends push notifications for a given pass.
    ///
    /// - Parameters:
    ///   - id: The `UUID` of the pass to send the notifications for.
    ///   - passTypeIdentifier: The type identifier of the pass.
    ///   - db: The `Database` to use.
    public func sendPushNotificationsForPass(id: UUID, of passTypeIdentifier: String, on db: any Database) async throws {
        try await service.sendPushNotificationsForPass(id: id, of: passTypeIdentifier, on: db)
    }
    
    /// Sends push notifications for a given pass.
    /// 
    /// - Parameters:
    ///   - pass: The pass to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for pass: PKPass, on db: any Database) async throws {
        try await service.sendPushNotifications(for: pass, on: db)
    }
    
    /// Sends push notifications for a given pass.
    /// 
    /// - Parameters:
    ///   - pass: The pass (as the `ParentProperty`) to send the notifications for.
    ///   - db: The `Database` to use.
    public func sendPushNotifications(for pass: ParentProperty<PassesRegistration, PKPass>, on db: any Database) async throws {
        try await service.sendPushNotifications(for: pass, on: db)
    }
}
