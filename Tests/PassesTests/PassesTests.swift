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

    func testPassesGeneration() async throws {
        let passData1 = PassData(title: "Test Pass 1")
        try await passData1.create(on: app.db)
        let pass1 = try await passData1.$pass.get(on: app.db)

        let passData2 = PassData(title: "Test Pass 2")
        try await passData2.create(on: app.db)
        let pass2 = try await passData2.$pass.get(on: app.db)

        let data = try await passesService.generatePassesContent(for: [pass1, pass2], on: app.db)
        XCTAssertNotNil(data)
    }

    func testPersonalization() async throws {
        let passDataPersonalize = PassData(title: "Personalize")
        try await passDataPersonalize.create(on: app.db)
        let passPersonalize = try await passDataPersonalize.$pass.get(on: app.db)
        let dataPersonalize = try await passesService.generatePassContent(for: passPersonalize, on: app.db)

        let passData = PassData(title: "Test Pass")
        try await passData.create(on: app.db)
        let pass = try await passData.$pass.get(on: app.db)
        let data = try await passesService.generatePassContent(for: pass, on: app.db)

        XCTAssertGreaterThan(dataPersonalize.count, data.count)
    }
}
