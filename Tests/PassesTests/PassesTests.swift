import XCTVapor
import Fluent
import FluentSQLiteDriver
@testable import Passes

final class PassesTests: XCTestCase {
    var app: Application!
    let passDelegate = TestPassesDelegate()
    var passesService: PassesService!
    
    override func setUp() async throws {
        self.app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        
        PassesService.register(migrations: app.migrations)
        app.migrations.add(CreatePassData())
        passesService = try PassesService(app: app, delegate: passDelegate)
        app.databases.middleware.use(PassDataMiddleware(service: passesService), on: .sqlite)

        try await app.autoMigrate()
    }

    func testPassGeneration() async throws {
        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let data = try await passesService.generatePassContent(for: pass, on: app.db)
        XCTAssertNotNil(data)
    }
}
