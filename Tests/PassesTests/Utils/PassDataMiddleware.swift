import Fluent
import Foundation
import Passes

struct PassDataMiddleware: AsyncModelMiddleware {
    private unowned let service: PassesService<PassData>

    init(service: PassesService<PassData>) {
        self.service = service
    }

    func create(model: PassData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = Pass(
            typeIdentifier: PassData.typeIdentifier,
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString()
        )
        try await pass.save(on: db)
        model.$pass.id = try pass.requireID()
        try await next.create(model, on: db)
    }

    func update(model: PassData, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = try await model.$pass.get(on: db)
        pass.updatedAt = Date()
        try await pass.save(on: db)
        try await next.update(model, on: db)
        try await service.sendPushNotifications(for: model, on: db)
    }
}
