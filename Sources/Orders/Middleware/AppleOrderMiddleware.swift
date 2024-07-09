//
//  AppleOrderMiddleware.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import Vapor
import FluentKit

struct AppleOrderMiddleware<O: OrderModel>: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let auth = request.headers["Authorization"].first?.replacingOccurrences(of: "AppleOrder ", with: ""),
            let _ = try await O.query(on: request.db)
                .filter(\._$authenticationToken == auth)
                .first()
        else {
            throw Abort(.unauthorized)
        }
        return try await next.respond(to: request)
    }
}
