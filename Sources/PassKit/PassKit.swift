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
import ZIPFoundation
import APNSwift
import NIOSSL
import Fluent

public class PassKit {
    private let kit: PassKitCustom<PKPass, PKDevice, PKRegistration, PKErrorLog>
    private let logger: Logger?

    public init(app: Application, delegate: PassKitDelegate, logger: Logger? = nil) {
        self.logger = logger
        kit = .init(app: app, delegate: delegate, logger: logger)
    }

    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Application` passed to `routes(_:)`
    ///   - delegate: The `PassKitDelegate` to use.
    ///   - authorizationCode: The `authenticationToken` which you are going to use in the `pass.json` file.
    public func registerRoutes(authorizationCode: String? = nil) {
        kit.registerRoutes(authorizationCode: authorizationCode)
    }

    /// Registers routes to send push notifications for updated passes
    ///
    /// ### Example ###
    /// ```
    /// try pk.registerPushRoutes(environment: .sandbox, middleware: PushAuthMiddleware())
    /// ```
    ///
    /// - Parameters:
    ///   - environment: The environment to use:  `sandbox` or `production`
    ///   - middleware: The `Middleware` which will control authentication for the routes.
    ///   - logger: The logger you wish to use.  If `nil`, one will be created
    public func registerPushRoutes(environment: APNSwiftConfiguration.Environment, middleware: Middleware, logger: Logger? = nil) throws {
        try kit.registerPushRoutes(environment: environment, middleware: middleware, logger: logger)
    }

    public static func register(migrations: Migrations) {
        migrations.add(PKPass())
        migrations.add(PKDevice())
        migrations.add(PKRegistration())
        migrations.add(PKErrorLog())
    }
}

/// Class to handle PassKit.
///
/// The generics should be passed in this order:
/// - Pass Type
/// - Device Type
/// - Registration Type
/// - Error Log Type
public class PassKitCustom<P, D, R: PassKitRegistration, E: PassKitErrorLog> where P == R.PassType, D == R.DeviceType {
    public unowned let delegate: PassKitDelegate

    private var ctrl: ApiController<P, D, R, E>
    private unowned let app: Application
    private let v1: RoutesBuilder
    private let logger: Logger?

    public init(app: Application, delegate: PassKitDelegate, logger: Logger? = nil) {
        self.delegate = delegate
        self.app = app
        self.logger = logger

        ctrl = .init(delegate: delegate, logger: logger)
        v1 = app.grouped("api", "v1")
    }

    /// Registers all the routes required for PassKit to work.
    ///
    /// - Parameters:
    ///   - app: The `Application` passed to `routes(_:)`
    ///   - delegate: The `PassKitDelegate` to use.
    ///   - authorizationCode: The `authenticationToken` which you are going to use in the `pass.json` file.
    public func registerRoutes(authorizationCode: String? = nil) {
        v1.get("devices", ":deviceLibraryIdentifier", "registrations", ":type", use: ctrl.passesForDevice)
        v1.post("log", use: ctrl.logError)

        guard let code = authorizationCode ?? Environment.get("PASS_KIT_AUTHORIZATION") else {
            fatalError("Must pass in an authorization code")
        }

        let v1auth = v1.grouped(ApplePassMiddleware(authorizationCode: code))

        v1auth.post("devices", ":deviceLibraryIdentifier", "registrations", ":type", ":passSerial", use: ctrl.registerDevice)
        v1auth.get("passes", ":type", ":passSerial", use: ctrl.latestVersionOfPass)
        v1auth.delete("devices", ":deviceLibraryIdentifier", "registrations", ":type", ":passSerial", use: ctrl.unregisterDevice)
    }

    /// Registers routes to send push notifications for updated passes
    ///
    /// ### Example ###
    /// ```
    /// try pk.registerPushRoutes(environment: .sandbox, middleware: PushAuthMiddleware())
    /// ```
    ///
    /// - Parameters:
    ///   - environment: The environment to use:  `sandbox` or `production`
    ///   - middleware: The `Middleware` which will control authentication for the routes.
    ///   - logger: The logger you wish to use.  If `nil`, one will be created
    public func registerPushRoutes(environment: APNSwiftConfiguration.Environment, middleware: Middleware, logger: Logger? = nil) throws {
        let privateKeyPath = URL(fileURLWithPath: delegate.pemPrivateKey, relativeTo: delegate.sslSigningFilesDirectory).unixPath()
        let pemPath = URL(fileURLWithPath: delegate.pemCertificate, relativeTo: delegate.sslSigningFilesDirectory).unixPath()

        app.apns.configuration = try .init(privateKeyPath: privateKeyPath, pemPath: pemPath, topic: "", environment: environment, logger: logger) {
            $0(self.delegate.pemPrivateKeyPassword.utf8)
        }

        let pushAuth = v1.grouped(middleware)

        pushAuth.post("push", ":type", ":passSerial", use: ctrl.pushUpdatesForPass)
        pushAuth.get("push", ":type", ":passSerial", use: ctrl.tokensForPassUpdate)
    }
}

// This will go away as soon as Kyle accepts my pull request
extension APNSwiftConfiguration {
    public init<T: Collection>(privateKeyPath: String, pemPath: String, topic: String, environment: APNSwiftConfiguration.Environment,
                               logger: Logger? = nil, passphraseCallback: @escaping NIOSSLPassphraseCallback<T>) throws
        where T.Element == UInt8 {
            try self.init(keyIdentifier: "", teamIdentifier: "", signer: APNSwiftSigner(buffer: ByteBufferAllocator().buffer(capacity: 1024)), topic: topic, environment: environment, logger: logger)
            let key = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem, passphraseCallback: passphraseCallback)
            self.tlsConfiguration.privateKey = NIOSSLPrivateKeySource.privateKey(key)
            self.tlsConfiguration.certificateVerification = .noHostnameVerification
            self.tlsConfiguration.certificateChain = try [.certificate(.init(file: pemPath, format: .pem))]
    }
}

