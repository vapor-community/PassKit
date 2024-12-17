import FluentKit
import Foundation

extension PassesService: AsyncModelMiddleware {
    public func create(model: PD, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = Pass(
            typeIdentifier: PD.typeIdentifier,
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString()
        )
        try await pass.save(on: db)
        model._$pass.id = try pass.requireID()
        try await next.create(model, on: db)
    }

    public func update(model: PD, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = try await model._$pass.get(on: db)
        pass.updatedAt = Date.now
        try await pass.save(on: db)
        try await next.update(model, on: db)
        try await self.sendPushNotifications(for: model, on: db)
    }
}

extension PassesServiceCustom: AsyncModelMiddleware {
    public func create(model: PD, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = P(
            typeIdentifier: PD.typeIdentifier,
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString()
        )
        try await pass.save(on: db)
        model._$pass.id = try pass.requireID()
        try await next.create(model, on: db)
    }

    public func update(model: PD, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        let pass = try await model._$pass.get(on: db)
        pass.updatedAt = Date.now
        try await pass.save(on: db)
        try await next.update(model, on: db)
        try await self.sendPushNotifications(for: model, on: db)
    }
}
