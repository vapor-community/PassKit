import FluentKit
import FluentSQLiteDriver
import PassKit
import Passes
import Testing
import Vapor
import Zip

func withApp(
    useEncryptedKey: Bool = false,
    _ body: (Application, PassesService) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)

    try #require(isLoggingConfigured)

    app.databases.use(.sqlite(.memory), as: .sqlite)

    let delegate = TestPassesDelegate()

    PassesService.register(migrations: app.migrations)
    app.migrations.add(CreatePassData())
    let passesService = try PassesService(
        app: app,
        delegate: delegate,
        signingFilesDirectory: "\(FileManager.default.currentDirectoryPath)/Tests/Certificates/",
        pemCertificate: useEncryptedKey ? "encryptedcert.pem" : "certificate.pem",
        pemPrivateKey: useEncryptedKey ? "encryptedkey.pem" : "key.pem",
        pemPrivateKeyPassword: useEncryptedKey ? "password" : nil,
        pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
        logger: app.logger
    )

    app.databases.middleware.use(PassDataMiddleware(service: passesService), on: .sqlite)

    try await app.autoMigrate()

    Zip.addCustomFileExtension("pkpass")

    try await body(app, passesService)

    try await app.autoRevert()
    try await app.asyncShutdown()
}
