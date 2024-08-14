import Vapor
import Fluent
import Orders

final class TestOrdersDelegate: OrdersDelegate {
    let sslSigningFilesDirectory = URL(
        fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/Tests/Certificates/",
        isDirectory: true
    )

    let pemCertificate = "certificate.pem"
    let pemPrivateKey = "key.pem"
    
    func encode<O: OrderModel>(order: O, db: any Database, encoder: JSONEncoder) async throws -> Data {
        guard let orderData = try await OrderData.query(on: db)
            .filter(\.$order.$id == order.requireID())
            .with(\.$order)
            .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(OrderJSONData(data: orderData, order: orderData.order)) else {
            throw Abort(.internalServerError)
        }
        return data
    }

    func template<O: OrderModel>(for: O, db: any Database) async throws -> URL {
        URL(
            fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/Tests/OrdersTests/Templates/",
            isDirectory: true
        )
    }
}

final class DefaultOrdersDelegate: OrdersDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "", isDirectory: true)
    func template<O: OrderModel>(for order: O, db: any Database) async throws -> URL { URL(fileURLWithPath: "") }
    func encode<O: OrderModel>(order: O, db: any Database, encoder: JSONEncoder) async throws -> Data { Data() }
}
