# Create the Pass Data Model

Implement the pass data model, its model middleware and define the pass file contents.

## Overview

The Passes framework provides models to save all the basic information for passes, user devices and their registration to each pass.
For all the other custom data needed to generate the pass (such as the barcodes, locations, etc.), you have to create your own model and its model middleware to handle the creation and update of passes.
The pass data model will be used to generate the `pass.json` file contents, along side image files for the icon and other visual elements, such as a logo.

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

### Pass Data Model Middleware

You'll want to create a model middleware to handle the creation and update of the pass data model.
This middleware could be responsible for creating and linking a ``PKPass`` to the pass data model, depending on your requirements.
When your pass data changes, it should also update the ``PKPass/updatedAt`` field of the ``PKPass`` and send a push notification to all devices registered to that pass. 

> Important: To send push notifications inside the middleware, you need to initialize the ``PassesService`` first, using the `Application` instance. See <doc:DistributeUpdate#Register-the-Routes> for more information.

```swift
import Vapor
import Fluent
import Passes

struct PassDataMiddleware: AsyncModelMiddleware {
    private unowned let app: Application

    init(app: Application) {
        self.app = app
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
        try await PassesService.sendPushNotifications(for: pkPass, on: db, app: self.app)
    }
}
```

Remember to register it in the `configure.swift` file.

```swift
app.databases.middleware.use(PassDataMiddleware(app: app), on: .psql)
```

> Important: Whenever your pass data changes, you must update the ``PKPass/updatedAt`` time of the linked pass so that Apple knows to send you a new pass.

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

### Register Migrations

If you're using the default schemas provided by this framework, you can register the default models in your `configure(_:)` method:

```swift
PassesService.register(migrations: app.migrations)
```

> Important: Register the default models before the migration of your pass data model.

### Custom Implementation

If you don't like the schema names provided by the framework that are used by default, you can instead create your own models conforming to ``PassModel``, ``UserPersonalizationModel``, `DeviceModel`, ``PassesRegistrationModel`` and `ErrorLogModel` and instantiate the generic ``PassesServiceCustom``, providing it your model types.

```swift
import PassKit
import Passes

let passesService = try PassesServiceCustom<MyPassType, MyUserPersonalizationType, MyDeviceType, MyPassesRegistrationType, MyErrorLogType>(app: app, delegate: delegate)
```

> Important: `DeviceModel` and `ErrorLogModel` are defined in the PassKit framework.
