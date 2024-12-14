import FluentKit
import FluentSQLiteDriver
import PassKit
import Passes
import Testing
import Vapor
import Zip

func withApp(
    useEncryptedKey: Bool = false,
    _ body: (Application, PassesService<PassData>) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    do {
        try #require(isLoggingConfigured)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        PassesService<PassData>.register(migrations: app.migrations)
        app.migrations.add(CreatePassData())
        try await app.autoMigrate()

        let passesService = try PassesService<PassData>(
            app: app,
            pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
            logger: app.logger,
            pemWWDRCertificate: TestCertificate.pemWWDRCertificate,
            pemCertificate: useEncryptedKey ? TestCertificate.encryptedPemCertificate : TestCertificate.pemCertificate,
            pemPrivateKey: useEncryptedKey ? TestCertificate.encryptedPemPrivateKey : TestCertificate.pemPrivateKey,
            pemPrivateKeyPassword: useEncryptedKey ? "password" : nil
        )
        app.databases.middleware.use(PassDataMiddleware(service: passesService), on: .sqlite)

        Zip.addCustomFileExtension("pkpass")

        try await body(app, passesService)

        try await app.autoRevert()
    } catch {
        try await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
