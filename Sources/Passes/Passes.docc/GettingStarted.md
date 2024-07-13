# Getting Started with Passes

Implement the pass data model, define the pass file contents, build a distributable pass and distribute it.

## Overview

The Passes framework provides models to save all the basic information for passes, user devices and their registration to each pass.
For all the other custom data needed to generate the pass (such as the barcodes, locations, etc.), you have to create your own model and its model middleware to handle the creation and update of passes.
The pass data model will be used to generate the `pass.json` file contents, along side image files for the icon and other visual elements, such as a logo.

The pass you distribute to a user is a signed bundle that contains the `pass.json` file, images and optional localizations.
The Passes framework provides the ``PassesService`` class that handles the creation of the pass JSON file and the signing of the pass bundle, using a ``PassesDelegate`` that you must implement.
The ``PassesService`` class also provides methods to send push notifications to all devices registered to a pass when it's updated and all the routes that Apple Wallet expects to get and update passes.

### Implement the Pass Data Model

Your data model should contain all the fields that you store for your pass, as well as a foreign key to ``PKPass``, the pass model offered by the Passes framework.

```swift
import Fluent
import struct Foundation.UUID
import Passes

final class PassData: PassDataModel, @unchecked Sendable {
    static let schema = "pass_data"

    @ID
    var id: UUID?

    @Parent(key: "pass_id")
    var pass: PKPass

    // Examples of other extra fields:
    @Field(key: "punches")
    var punches: Int

    @Field(key: "title")
    var title: String

    // Add any other field relative to your app, such as a location, a date, etc.

    init() { }
}

struct CreatePassData: AsyncMigration {
    public func prepare(on database: Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field("pass_id", .uuid, .required, .references(PKPass.schema, .id, onDelete: .cascade))
            .field("punches", .int, .required)
            .field("title", .string, .required)
            .create()
    }
    
    public func revert(on database: Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}
```

### Handle Cleanup

Depending on your implementation details, you may want to automatically clean out the passes and devices table when a registration is deleted.
You'll need to implement based on your type of SQL database as there's not yet a Fluent way to implement something like SQL's `NOT EXISTS` call with a `DELETE` statement.

> Warning: Be careful with SQL triggers, as they can have unintended consequences if not properly implemented.

### Model the pass.json contents

Create a `struct` that implements ``PassJSON/Properties`` which will contain all the fields for the generated `pass.json` file.
Create an initializer that takes your custom pass data, the ``PKPass`` and everything else you may need.

> Tip: For information on the various keys available see the [documentation](https://developer.apple.com/documentation/walletpasses/pass). See also [this guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/index.html#//apple_ref/doc/uid/TP40012195-CH1-SW1) for some help.

```swift
import Passes

struct PassJSONData: PassJSON.Properties {
    let description: String
    let formatVersion = PassJSON.FormatVersion.v1
    let organizationName = "vapor-community"
    let passTypeIdentifier = Environment.get("PASSKIT_PASS_TYPE_IDENTIFIER")!
    let serialNumber: String
    let teamIdentifier = Environment.get("APPLE_TEAM_IDENTIFIER")!

    private let webServiceURL = "https://example.com/api/passes/"
    private let authenticationToken: String
    private let logoText = "Vapor"
    private let sharingProhibited = true
    let backgroundColor = "rgb(207, 77, 243)"
    let foregroundColor = "rgb(255, 255, 255)"

    let barcodes = Barcode(message: "test")
    struct Barcode: PassJSON.Barcodes {
        let format = PassJSON.BarcodeFormat.qr
        let message: String
        let messageEncoding = "iso-8859-1"
    }

    let boardingPass = Boarding(transitType: .air)
    struct Boarding: PassJSON.BoardingPass {
        let transitType: PassJSON.TransitType
        let headerFields: [PassField]
        let primaryFields: [PassField]
        let secondaryFields: [PassField]
        let auxiliaryFields: [PassField]
        let backFields: [PassField]

        struct PassField: PassJSON.PassFieldContent {
            let key: String
            let label: String
            let value: String
        }

        init(transitType: PassJSON.TransitType) {
            self.headerFields = [.init(key: "header", label: "Header", value: "Header")]
            self.primaryFields = [.init(key: "primary", label: "Primary", value: "Primary")]
            self.secondaryFields = [.init(key: "secondary", label: "Secondary", value: "Secondary")]
            self.auxiliaryFields = [.init(key: "auxiliary", label: "Auxiliary", value: "Auxiliary")]
            self.backFields = [.init(key: "back", label: "Back", value: "Back")]
            self.transitType = transitType
        }
    }

    init(data: PassData, pass: PKPass) {
        self.description = data.title
        self.serialNumber = pass.id!.uuidString
        self.authenticationToken = pass.authenticationToken
    }
}
```

> Important: You **must** add `api/passes/` to your `webServiceURL`, as shown in the example above.

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
            .filter(\.$pass.$id == pass.requireID())
            .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(PassJSONData(data: passData, pass: pass)) else {
            throw Abort(.internalServerError)
        }
        return data
    }

    func template<P: PassModel>(for pass: P, db: Database) async throws -> URL {
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
    let passesService = try PassesService(delegate: passDelegate)
    passesService.registerRoutes(app: app)
}
```

> Note: Notice how the ``PassesDelegate`` is created as a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits.

If you wish to include routes specifically for sending push notifications to updated passes, you can also pass to the ``PassesService/registerRoutes(app:pushMiddleware:)`` whatever `Middleware` you want Vapor to use to authenticate the two routes. Doing so will add two routes, the first one sends notifications and the second one retrieves a list of push tokens which would be sent a notification.

```http
POST https://example.com/api/passes/v1/push/{passTypeIdentifier}/{passSerial} HTTP/2
```

```http
GET https://example.com/api/passes/v1/push/{passTypeIdentifier}/{passSerial} HTTP/2
```

### Custom Implementation of PassesService

If you don't like the schema names provided by the framework that are used by default, you can instead create your own models conforming to ``PassModel``, ``UserPersonalizationModel``, `DeviceModel`, ``PassesRegistrationModel`` and `ErrorLogModel` and instantiate the generic ``PassesServiceCustom``, providing it your model types.

```swift
import PassKit
import Passes

let passesService = try PassesServiceCustom<MyPassType, MyUserPersonalizationType, MyDeviceType, MyPassesRegistrationType, MyErrorLogType>(delegate: delegate)
```

> Important: `DeviceModel` and `ErrorLogModel` are defined in the PassKit framework.

### Register Migrations

If you're using the default schemas provided by this framework, you can register the default models in your `configure(_:)` method:

```swift
PassesService.register(migrations: app.migrations)
```

> Important: Register the default models before the migration of your pass data model.

### Pass Data Model Middleware

You'll want to create a model middleware to handle the creation and update of the pass data model.
This middleware could be responsible for creating and linking a ``PKPass`` to the pass data model, depending on your requirements.
When your pass data changes, it should also update the ``PKPass/updatedAt`` field of the ``PKPass`` and send a push notification to all devices registered to that pass. 

```swift
import Vapor
import Fluent
import Passes

struct PassDataMiddleware: AsyncModelMiddleware {
    private unowned let service: PassesService

    init(service: PassesService) {
        self.service = service
    }

    // Create the `PKPass` and add it to the `PassData` automatically at creation
    func create(model: PassData, on db: Database, next: AnyAsyncModelResponder) async throws {
        let pkPass = PKPass(
            passTypeIdentifier: "pass.com.yoursite.passType",
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString())
        try await pkPass.save(on: db)
        model.$pass.id = try pkPass.requireID()
        try await next.create(model, on: db)
    }

    func update(model: PassData, on db: Database, next: AnyAsyncModelResponder) async throws {
        let pkPass = try await model.$pass.get(on: db)
        pkPass.updatedAt = Date()
        try await pkPass.save(on: db)
        try await next.update(model, on: db)
        try await service.sendPushNotifications(for: pkPass, on: db)
    }
}
```

Remember to register it in the `routes.swift` file.

```swift
app.databases.middleware.use(PassDataMiddleware(app: app), on: .psql)
```

> Important: Whenever your pass data changes, you must update the ``PKPass/updatedAt`` time of the linked pass so that Apple knows to send you a new pass.

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

> Important: Bundles of passes are supported only in Safari. You can't send the bundle via AirDrop or other methods.
