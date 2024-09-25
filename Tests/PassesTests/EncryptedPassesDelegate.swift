import FluentKit
import Passes
import Vapor

final class EncryptedPassesDelegate: PassesDelegate {
    let sslSigningFilesDirectory = URL(
        fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/Tests/Certificates/",
        isDirectory: true
    )

    let pemCertificate = "encryptedcert.pem"
    let pemPrivateKey = "encryptedkey.pem"

    let pemPrivateKeyPassword: String? = "password"

    func encode<P: PassModel>(
        pass: P, db: any Database, encoder: JSONEncoder
    ) async throws -> Data {
        guard
            let passData = try await PassData.query(on: db)
                .filter(\.$pass.$id == pass.requireID())
                .with(\.$pass)
                .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(PassJSONData(data: passData, pass: passData.pass))
        else {
            throw Abort(.internalServerError)
        }
        return data
    }

    func encodePersonalization<P: PassModel>(
        for pass: P, db: any Database, encoder: JSONEncoder
    ) async throws -> Data? {
        guard
            let passData = try await PassData.query(on: db)
                .filter(\.$pass.$id == pass.id!)
                .with(\.$pass)
                .first()
        else {
            throw Abort(.internalServerError)
        }

        if passData.title != "Personalize" { return nil }

        if try await passData.pass.$userPersonalization.get(on: db) == nil {
            guard let data = try? encoder.encode(PersonalizationJSONData()) else {
                throw Abort(.internalServerError)
            }
            return data
        } else {
            return nil
        }
    }

    func template<P: PassModel>(for pass: P, db: any Database) async throws -> URL {
        URL(
            fileURLWithPath:
                "\(FileManager.default.currentDirectoryPath)/Tests/PassesTests/Templates/",
            isDirectory: true
        )
    }
}
