import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Passes

final class PassesTests: XCTestCase {
    var app: Application!
    let passDelegate = PassDelegate()
    
    override func setUp() async throws {
        self.app = try await Application.make(.testing)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        PassesService.register(migrations: app.migrations)
        app.migrations.add(CreatePassData())
        let passesService = try PassesService(app: app, delegate: passDelegate)
        app.databases.middleware.use(PassDataMiddleware(service: passesService), on: .sqlite)

        try await app.autoMigrate()
    }
    
    override func tearDown() async throws { 
        try await app.autoRevert()
        try await self.app.asyncShutdown()
        self.app = nil
    }
}
