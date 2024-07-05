# Building, Distributing and Updating a Pass

Build a distributable pass and distribute it to your users or update an existing pass.

## Overview

The pass you distribute to a user is a signed bundle that contains the JSON description of the pass, images, and optional localizations.
The Passes framework provides the ``PassesService`` class that handles the creation of the pass JSON file and the signing of the pass bundle, using a ``PassesDelegate`` that you must implement.
The ``PassesService`` class also provides methods to send push notifications to all devices registered to a pass when it's updated and all the routes that Apple Wallet expects to get and update passes.

### Implement the Delegate

Create a delegate file that implements ``PassesDelegate``.
In the ``PassesDelegate/sslSigningFilesDirectory`` you specify there must be the `WWDR.pem`, `passcertificate.pem` and `passkey.pem` files.
If they are named like that you're good to go, otherwise you have to specify the custom name.

> Tip: Obtaining the three certificates files could be a bit tricky. You could get some guidance from [this guide](https://github.com/alexandercerutti/passkit-generator/wiki/Generating-Certificates) and [this video](https://www.youtube.com/watch?v=rJZdPoXHtzI).

There are other fields available which have reasonable default values. See ``PassesDelegate``'s documentation.

Because the files for your pass' template and the method of encoding might vary by pass type, you'll be provided the ``PKPass`` for those methods.
In the ``PassesDelegate/encode(pass:db:encoder:)`` method, you'll want to encode a `struct` that conforms to ``PassJSON``.

```swift
import Vapor
import Fluent
import Passes

final class PassDelegate: PassesDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "Certificates/Passes/", isDirectory: true)

    let pemPrivateKeyPassword: String? = Environment.get("PEM_PRIVATE_KEY_PASSWORD")!

    func encode<P: PassModel>(pass: P, db: Database, encoder: JSONEncoder) async throws -> Data {
        // The specific PassData class you use here may vary based on the `pass.passTypeIdentifier`
        // if you have multiple different types of passes, and thus multiple types of pass data.
        guard let passData = try await PassData.query(on: db)
            .filter(\.$pass.$id == pass.id!)
            .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(PassJSONData(data: passData, pass: pass)) else {
            throw Abort(.internalServerError)
        }
        return data
    }

    func template<P: PassModel>(for: P, db: Database) async throws -> URL {
        // The location might vary depending on the type of pass.
        return URL(fileURLWithPath: "Templates/Passes/", isDirectory: true)
    }
}
```

> Important: You **must** explicitly declare ``PassesDelegate/pemPrivateKeyPassword`` as a `String?` or Swift will ignore it as it'll think it's a `String` instead.

### Register the Routes

Next, register the routes in `routes.swift`.
This will implement all of the routes that Apple Wallet expects to exist on your server for you.

```swift
import Vapor
import Passes

let passDelegate = PassDelegate()

func routes(_ app: Application) throws {
    let passesService = PassesService(app: app, delegate: passDelegate)
    passesService.registerRoutes()
}
```

> Note: Notice how the ``PassesDelegate`` is created as a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits.

### Push Notifications

If you wish to include routes specifically for sending push notifications to updated passes you can also include this line in your `routes(_:)` method. You'll need to pass in whatever `Middleware` you want Vapor to use to authenticate the two routes.

> Important: If you don't include this line, you have to configure an APNS container yourself.

```swift
try passesService.registerPushRoutes(middleware: SecretMiddleware(secret: "foo"))
```

That will add two routes, the first one sends notifications and the second one retrieves a list of push tokens which would be sent a notification.

```http
POST https://example.com/api/passes/v1/push/{passTypeIdentifier}/{passSerial} HTTP/2
```

```http
GET https://example.com/api/passes/v1/push/{passTypeIdentifier}/{passSerial} HTTP/2
```

### Pass Data Model Middleware

Whether you include the routes or not, you'll want to add a model middleware that sends push notifications and updates the ``PKPass/updatedAt`` field when your pass data updates. The model middleware could also create and link the ``PKPass`` during the creation of the pass data, depending on your requirements.

See <doc:PassData> for more information.

### Apple Push Notification service

If you did not include the push notification routes, remember to configure APNs yourself.

> Important: PassKit *only* works with the APNs production environment. You can't pass in the `.sandbox` environment.

```swift
let apnsConfig: APNSClientConfiguration
if let pemPrivateKeyPassword {
    apnsConfig = APNSClientConfiguration(
        authenticationMethod: try .tls(
            privateKey: .privateKey(
                NIOSSLPrivateKey(file: privateKeyPath, format: .pem) { closure in
                    closure(pemPrivateKeyPassword.utf8)
                }),
            certificateChain: NIOSSLCertificate.fromPEMFile(pemPath).map { .certificate($0) }
        ),
        environment: .production
    )
} else {
    apnsConfig = APNSClientConfiguration(
        authenticationMethod: try .tls(
            privateKey: .file(privateKeyPath),
            certificateChain: NIOSSLCertificate.fromPEMFile(pemPath).map { .certificate($0) }
        ),
        environment: .production
    )
}
app.apns.containers.use(
    apnsConfig,
    eventLoopGroupProvider: .shared(app.eventLoopGroup),
    responseDecoder: JSONDecoder(),
    requestEncoder: JSONEncoder(),
    as: .init(string: "passes"),
    isDefault: false
)
```

### Generate the Pass Content

To generate and distribute the `.pkpass` bundle, pass the ``PassesService`` object to your `RouteCollection`.

```swift
import Fluent
import Vapor
import Passes

struct PassesController: RouteCollection {
    let passesService: PassesService

    func boot(routes: RoutesBuilder) throws {
        ...
    }
}
```

Then use the object inside your route handlers to generate the pass bundle with the ``PassesService/generatePassContent(for:on:)`` method and distribute it with the "`application/vnd.apple.pkpass`" MIME type.

```swift
fileprivate func passHandler(_ req: Request) async throws -> Response {
    ...
    guard let passData = try await PassData.query(on: req.db)
        .filter(...)
        .with(\.$pass)
        .first()
    else {
        throw Abort(.notFound)
    }

    let bundle = try await passesService.generatePassContent(for: passData.pass, on: req.db)
    let body = Response.Body(data: bundle)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
    headers.add(name: .contentDisposition, value: "attachment; filename=name.pkpass") // Add this header only if you are serving the pass in a web page
    headers.add(name: .lastModified, value: String(passData.pass.updatedAt?.timeIntervalSince1970 ?? 0))
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```

### Create a Bundle of Passes

You can also create a bundle of passes to enable your user to download multiple passes at once.
Use the ``PassesService/generatePassesContent(for:on:)`` method to generate the bundle and serve it to the user.
The MIME type for a bundle of passes is "`application/vnd.apple.pkpasses`".

> Note: You can have up to 10 passes or 150 MB for a bundle of passes.

> Important: Bundles of passes are supported only in Safari. You can't send the bundle via AirDrop or other methods.

```swift
fileprivate func passesHandler(_ req: Request) async throws -> Response {
    ...
    let passesData = try await PassData.query(on: req.db).with(\.$pass).all()
    let passes = passesData.map { $0.pass }

    let bundle = try await passesService.generatePassesContent(for: passes, on: req.db)
    let body = Response.Body(data: bundle)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/vnd.apple.pkpasses")
    headers.add(name: .contentDisposition, value: "attachment; filename=name.pkpasses")
    headers.add(name: .lastModified, value: String(Date().timeIntervalSince1970))
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```
