import FluentKit
import Vapor

struct AppleOrderMiddleware<O: OrderModel>: AsyncMiddleware {
    func respond(
        to request: Request, chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard
            let auth = request.headers["Authorization"].first?.replacingOccurrences(
                of: "AppleOrder ", with: ""),
            (try await O.query(on: request.db)
                .filter(\._$authenticationToken == auth)
                .first()) != nil
        else {
            throw Abort(.unauthorized)
        }
        return try await next.respond(to: request)
    }
}
