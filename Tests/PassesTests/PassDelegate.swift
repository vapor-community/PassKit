import Vapor
import Fluent
import Passes

final class PassDelegate: PassesDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "Certificates/Passes/", isDirectory: true)

    let pemPrivateKeyPassword: String? = "password"

    func encode<P: PassModel>(pass: P, db: any Database, encoder: JSONEncoder) async throws -> Data {
        guard let passData = try await PassData.query(on: db)
            .filter(\.$pass.$id == pass.requireID())
            .with(\.$pass)
            .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(PassJSONData(data: passData, pass: passData.pass)) else {
            throw Abort(.internalServerError)
        }
        return data
    }
    
    /*
    func encodePersonalization<P: PassModel>(for pass: P, db: any Database, encoder: JSONEncoder) async throws -> Data? {
        guard let passData = try await PassData.query(on: db)
            .filter(\.$pass.$id == pass.id!)
            .with(\.$pass)
            .first()
        else {
            throw Abort(.internalServerError)
        }
        
        if try await passData.pass.$userPersonalization.get(on: db) == nil {
            guard let data = try? encoder.encode(PersonalizationJSONData()) else {
                throw Abort(.internalServerError)
            }
            return data
        } else { return nil }
    }
    */

    func template<P: PassModel>(for pass: P, db: any Database) async throws -> URL {
        return URL(fileURLWithPath: "Templates/Passes/", isDirectory: true)
    }
}
