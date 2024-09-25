import Vapor

struct SecretMiddleware: AsyncMiddleware {
    let secret: String

    init(secret: String) {
        self.secret = secret
    }

    func respond(
        to request: Request, chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard request.headers.first(name: "X-Secret") == secret else {
            throw Abort(.unauthorized, reason: "Incorrect X-Secret header.")
        }
        return try await next.respond(to: request)
    }
}
