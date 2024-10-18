import FluentKit
import FluentSQLiteDriver
import Orders
import PassKit
import Testing
import Vapor
import Zip

func withApp(
    useEncryptedKey: Bool = false,
    _ body: (Application, OrdersService) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    try #require(isLoggingConfigured)

    app.databases.use(.sqlite(.memory), as: .sqlite)
    OrdersService.register(migrations: app.migrations)
    app.migrations.add(CreateOrderData())
    try await app.autoMigrate()

    let delegate = TestOrdersDelegate()
    let ordersService = try OrdersService(
        app: app,
        delegate: delegate,
        signingFilesDirectory: "\(FileManager.default.currentDirectoryPath)/Tests/Certificates/",
        pemCertificate: useEncryptedKey ? "encryptedcert.pem" : "certificate.pem",
        pemPrivateKey: useEncryptedKey ? "encryptedkey.pem" : "key.pem",
        pemPrivateKeyPassword: useEncryptedKey ? "password" : nil,
        pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
        logger: app.logger
    )
    app.databases.middleware.use(OrderDataMiddleware(service: ordersService), on: .sqlite)

    Zip.addCustomFileExtension("order")

    try await body(app, ordersService)

    try await app.autoRevert()
    try await app.asyncShutdown()
}
