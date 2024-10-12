import FluentKit
import FluentSQLiteDriver
import Orders
import PassKit
import Testing
import Vapor
import Zip

func withApp(
    delegate: some OrdersDelegate,
    _ body: (Application, OrdersService) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)

    try #require(isLoggingConfigured)

    app.databases.use(.sqlite(.memory), as: .sqlite)

    OrdersService.register(migrations: app.migrations)
    app.migrations.add(CreateOrderData())
    let passesService = try OrdersService(
        app: app,
        delegate: delegate,
        pushRoutesMiddleware: SecretMiddleware(secret: "foo"),
        logger: app.logger
    )

    app.databases.middleware.use(OrderDataMiddleware(service: passesService), on: .sqlite)

    try await app.autoMigrate()

    Zip.addCustomFileExtension("order")

    try await body(app, passesService)

    try await app.autoRevert()
    try await app.asyncShutdown()
}
