# Getting Started with Passes

Create the pass data model, build a pass for Apple Wallet and distribute it with a Vapor server.

## Overview

The Passes framework provides models to save all the basic information for passes, user devices and their registration to each pass.
For all the other custom data needed to generate the pass, such as the barcodes, locations, etc., you have to create your own model and its model middleware to handle the creation and update of passes.
The pass data model will be used to generate the `pass.json` file contents.

The pass you distribute to a user is a signed bundle that contains the `pass.json` file, images and optional localizations.
The Passes framework provides the ``PassesService`` class that handles the creation of the pass JSON file and the signing of the pass bundle.
The ``PassesService`` class also provides methods to send push notifications to all devices registered when you update a pass, and all the routes that Apple Wallet uses to retrieve passes.

### Implement the Pass Data Model

Your data model should contain all the fields that you store for your pass, as well as a foreign key to ``Pass``, the pass model offered by the Passes framework, and a pass type identifier that's registered with Apple.

```swift
import Fluent
import Foundation
import Passes

final class PassData: PassDataModel, @unchecked Sendable {
    static let schema = "pass_data"

    static let typeIdentifier = Environment.get("PASS_TYPE_IDENTIFIER")!

    @ID
    var id: UUID?

    @Parent(key: "pass_id")
    var pass: Pass

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
        try await database.schema(PassData.schema)
            .id()
            .field("pass_id", .uuid, .required, .references(Pass.schema, .id, onDelete: .cascade))
            .field("punches", .int, .required)
            .field("title", .string, .required)
            .create()
    }
    
    public func revert(on database: Database) async throws {
        try await database.schema(PassData.schema).delete()
    }
}
```

You also have to define two methods in the ``PassDataModel``:
- ``PassDataModel/passJSON(on:)``, where you'll have to return a `struct` that conforms to ``PassJSON/Properties``.
- ``PassDataModel/template(on:)``, where you'll have to return the path to a folder containing the pass files.

```swift
extension PassData {
    func passJSON(on db: any Database) async throws -> any PassJSON.Properties {
        try await PassJSONData(data: self, pass: self.$pass.get(on: db))
    }

    func template(on db: any Database) async throws -> String {
        // The location might vary depending on the type of pass.
        "Templates/Passes/"
    }
}
```

### Handle Cleanup

Depending on your implementation details, you may want to automatically clean out the passes and devices table when a registration is deleted.
The implementation will be based on your type of SQL database, as there's not yet a Fluent way to implement something like SQL's `NOT EXISTS` call with a `DELETE` statement.

> Warning: Be careful with SQL triggers, as they can have unintended consequences if not properly implemented.

### Model the pass.json contents

Create a `struct` that implements ``PassJSON/Properties`` which will contain all the fields for the generated `pass.json` file.
Create an initializer that takes your custom pass data, the ``Pass`` and everything else you may need.

> Tip: For information on the various keys available see the [documentation](https://developer.apple.com/documentation/walletpasses/pass). See also [this guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/index.html#//apple_ref/doc/uid/TP40012195-CH1-SW1) for some help.

```swift
import Passes

struct PassJSONData: PassJSON.Properties {
    let description: String
    let formatVersion = PassJSON.FormatVersion.v1
    let organizationName = "vapor-community"
    let passTypeIdentifier = PassData.typeIdentifier
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

    init(data: PassData, pass: Pass) {
        self.description = data.title
        self.serialNumber = pass.id!.uuidString
        self.authenticationToken = pass.authenticationToken
    }
}
```

> Important: You **must** add `api/passes/` to your `webServiceURL`, as shown in the example above.

### Initialize the Service

Next, initialize the ``PassesService`` inside the `configure.swift` file.
This will implement all of the routes that Apple Wallet expects to exist on your server.

> Tip: Obtaining the three certificates files could be a bit tricky. You could get some guidance from [this guide](https://github.com/alexandercerutti/passkit-generator/wiki/Generating-Certificates) and [this video](https://www.youtube.com/watch?v=rJZdPoXHtzI).

```swift
import Fluent
import Vapor
import Passes

public func configure(_ app: Application) async throws {
    ...
    let passesService = try PassesService<PassData>(
        app: app,
        pemWWDRCertificate: Environment.get("PEM_WWDR_CERTIFICATE")!,
        pemCertificate: Environment.get("PEM_CERTIFICATE")!,
        pemPrivateKey: Environment.get("PEM_PRIVATE_KEY")!
    )
}
```

If you wish to include routes specifically for sending push notifications to updated passes, you can also pass to the ``PassesService`` initializer whatever `Middleware` you want Vapor to use to authenticate the two routes. Doing so will add two routes, the first one sends notifications and the second one retrieves a list of push tokens which would be sent a notification.

```http
POST https://example.com/api/passes/v1/push/{passTypeIdentifier}/{passSerial} HTTP/2
```

```http
GET https://example.com/api/passes/v1/push/{passTypeIdentifier}/{passSerial} HTTP/2
```

### Custom Implementation of PassesService

If you don't like the schema names provided by default, you can create your own models conforming to ``PassModel``, ``UserPersonalizationModel``, `DeviceModel`, ``PassesRegistrationModel`` and `ErrorLogModel` and instantiate the generic ``PassesServiceCustom``, providing it your model types.

```swift
import Fluent
import Vapor
import PassKit
import Passes

public func configure(_ app: Application) async throws {
    ...
    let passesService = try PassesServiceCustom<
        PassData,
        MyPassType,
        MyUserPersonalizationType,
        MyDeviceType,
        MyPassesRegistrationType,
        MyErrorLogType
    >(
        app: app,
        pemWWDRCertificate: Environment.get("PEM_WWDR_CERTIFICATE")!,
        pemCertificate: Environment.get("PEM_CERTIFICATE")!,
        pemPrivateKey: Environment.get("PEM_PRIVATE_KEY")!
    )
}
```

### Register Migrations

If you're using the default schemas provided by this framework, you can register the default models in your `configure(_:)` method:

```swift
PassesService<PassData>.register(migrations: app.migrations)
```

> Important: Register the default models before the migration of your pass data model.

### Pass Data Model Middleware

This framework provides a model middleware to handle the creation and update of the pass data model.

When you create a ``PassDataModel`` object, it will automatically create a ``PassModel`` object with a random auth token and the correct type identifier and link it to the pass data model.
When you update a pass data model, it will update the ``PassModel`` object and send a push notification to all devices registered to that pass.

You can register it like so (either with a ``PassesService`` or a ``PassesServiceCustom``):

```swift
app.databases.middleware.use(passesService, on: .psql)
```

> Note: If you don't like the default implementation of the model middleware, it is highly recommended that you create your own. But remember: whenever your pass data changes, you must update the ``Pass/updatedAt`` time of the linked ``Pass`` so that Wallet knows to retrieve a new pass.

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

> Note: You'll have to register the `PassesController` in the `configure.swift` file, in order to pass it the ``PassesService`` object.

Then use the object inside your route handlers to generate the pass bundle with the ``PassesService/build(pass:on:)`` method and distribute it with the "`application/vnd.apple.pkpass`" MIME type.

```swift
fileprivate func passHandler(_ req: Request) async throws -> Response {
    ...
    guard let pass = try await PassData.query(on: req.db)
        .filter(...)
        .first()
    else {
        throw Abort(.notFound)
    }

    let bundle = try await passesService.build(pass: pass, on: req.db)
    let body = Response.Body(data: bundle)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
    headers.add(name: .contentDisposition, value: "attachment; filename=name.pkpass")
    headers.lastModified = HTTPHeaders.LastModified(pass.updatedAt ?? Date.distantPast)
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```

### Create a Bundle of Passes

You can also create a bundle of passes to enable your user to download multiple passes at once.
Use the ``PassesService/build(passes:on:)`` method to generate the bundle and serve it to the user.
The MIME type for a bundle of passes is "`application/vnd.apple.pkpasses`".

> Note: You can have up to 10 passes or 150 MB for a bundle of passes.

```swift
fileprivate func passesHandler(_ req: Request) async throws -> Response {
    ...
    let passes = try await PassData.query(on: req.db).all()

    let bundle = try await passesService.build(passes: passes, on: req.db)
    let body = Response.Body(data: bundle)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/vnd.apple.pkpasses")
    headers.add(name: .contentDisposition, value: "attachment; filename=name.pkpasses")
    headers.lastModified = HTTPHeaders.LastModified(Date())
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```

> Important: Bundles of passes are supported only in Safari. You can't send the bundle via AirDrop or other methods.
