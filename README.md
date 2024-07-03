<div align="center">
    <img src="https://avatars.githubusercontent.com/u/26165732?s=200&v=4" width="100" height="100" alt="avatar" />
    <h1>PassKit</h1>
    <a href="https://swiftpackageindex.com/vapor-community/PassKit/0.3.0/documentation/passes">
        <img src="https://design.vapor.codes/images/readthedocs.svg" alt="Documentation">
    </a>
    <a href="https://discord.gg/vapor"><img src="https://design.vapor.codes/images/discordchat.svg" alt="Team Chat"></a>
    <a href="LICENSE"><img src="https://design.vapor.codes/images/mitlicense.svg" alt="MIT License"></a>
    <a href="https://github.com/vapor-community/PassKit/actions/workflows/test.yml">
        <img src="https://img.shields.io/github/actions/workflow/status/vapor-community/PassKit/test.yml?event=push&style=plastic&logo=github&label=tests&logoColor=%23ccc" alt="Continuous Integration">
    </a>
    <a href="https://codecov.io/github/vapor-community/PassKit">
        <img src="https://img.shields.io/codecov/c/github/vapor-community/PassKit?style=plastic&logo=codecov&label=codecov">
    </a>
    <a href="https://swift.org">
        <img src="https://design.vapor.codes/images/swift510up.svg" alt="Swift 5.10+">
    </a>
</div>
<br>

🎟️ 📦 A Vapor package for creating, distributing and updating passes and orders for Apple Wallet.

### Major Releases

The table below shows a list of PassKit major releases alongside their compatible Swift versions. 

|Version|Swift|SPM|
|---|---|---|
|0.4.0|5.10+|`from: "0.4.0"`|
|0.2.0|5.9+|`from: "0.2.0"`|
|0.1.0|5.9+|`from: "0.1.0"`|

Use the SPM string to easily include the dependendency in your `Package.swift` file

```swift
.package(url: "https://github.com/vapor-community/PassKit.git", from: "0.4.0")
```

> Note: This package is made for Vapor 4.

## 🎟️ Wallet Passes

Add the `Passes` product to your target's dependencies:

```swift
.product(name: "Passes", package: "PassKit")
```

### Implement your pass data model

Your data model should contain all the fields that you store for your pass, as well as a foreign key for the pass itself.

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

### Handle cleanup

Depending on your implementation details, you'll likely want to automatically clean out the passes and devices table when a registration is deleted.
You'll need to implement based on your type of SQL database as there's not yet a Fluent way to implement something like SQL's `NOT EXISTS` call with a `DELETE` statement.
If you're using PostgreSQL, you can setup these triggers/methods:

```sql
CREATE OR REPLACE FUNCTION public."RemoveUnregisteredItems"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$BEGIN  
       DELETE FROM devices d
       WHERE NOT EXISTS (
           SELECT 1
           FROM passes_registrations r
           WHERE d."id" = r.device_id
           LIMIT 1
       );
                
       DELETE FROM passes p
       WHERE NOT EXISTS (
           SELECT 1
           FROM passes_registrations r
           WHERE p."id" = r.pass_id
           LIMIT 1
       );
                
       RETURN OLD;
END
$$;

CREATE TRIGGER "OnRegistrationDelete" 
AFTER DELETE ON "public"."passes_registrations"
FOR EACH ROW
EXECUTE PROCEDURE "public"."RemoveUnregisteredItems"();
```

> [!CAUTION]
> Be careful with SQL triggers, as they can have unintended consequences if not properly implemented.

### Model the `pass.json` contents

Create a `struct` that implements `PassJSON` which will contain all the fields for the generated `pass.json` file.
Create an initializer that takes your custom pass data, the `PKPass` and everything else you may need.

> [!TIP]
> For information on the various keys available see the [documentation](https://developer.apple.com/documentation/walletpasses/pass). See also [this guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/index.html#//apple_ref/doc/uid/TP40012195-CH1-SW1) for some help.

Here's an example of a `struct` that implements `PassJSON`.

```swift
import Passes

struct PassJSONData: PassJSON {
    let description: String
    let formatVersion = 1
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
    struct Barcode: Barcodes {
        let format = BarcodeFormat.qr
        let message: String
        let messageEncoding = "iso-8859-1"
    }

    let boardingPass = Boarding(transitType: .air)
    struct Boarding: BoardingPass {
        let transitType: TransitType
        let headerFields: [PassField]
        let primaryFields: [PassField]
        let secondaryFields: [PassField]
        let auxiliaryFields: [PassField]
        let backFields: [PassField]

        struct PassField: PassFieldContent {
            let key: String
            let label: String
            let value: String
        }

        init(transitType: TransitType) {
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

> [!IMPORTANT]
> You **must** add `api/passes/` to your `webServiceURL`, as shown in the example above.

### Implement the Delegate

Create a delegate file that implements `PassesDelegate`.
In the `sslSigningFilesDirectory` you specify there must be the `WWDR.pem`, `passcertificate.pem` and `passkey.pem` files. If they are named like that you're good to go, otherwise you have to specify the custom name.

> [!TIP]
> Obtaining the three certificates files could be a bit tricky. You could get some guidance from [this guide](https://github.com/alexandercerutti/passkit-generator/wiki/Generating-Certificates) and [this video](https://www.youtube.com/watch?v=rJZdPoXHtzI).

There are other fields available which have reasonable default values. See the delegate's documentation.

Because the files for your pass' template and the method of encoding might vary by pass type, you'll be provided the pass for those methods.

```swift
import Vapor
import Fluent
import Passes

final class PassDelegate: PassesDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "Certificates/Passes/", isDirectory: true)

    let pemPrivateKeyPassword: String? = Environment.get("PEM_PRIVATE_KEY_PASSWORD")!

    func encode<P: PassModel>(pass: P, db: Database, encoder: JSONEncoder) async throws -> Data {
        // The specific PassData class you use here may vary based on the pass.type if you have multiple
        // different types of passes, and thus multiple types of pass data.
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

> [!IMPORTANT]
> You **must** explicitly declare `pemPrivateKeyPassword` as a `String?` or Swift will ignore it as it'll think it's a `String` instead.

### Register Routes

Next, register the routes in `routes.swift`.
This will implement all of the routes that PassKit expects to exist on your server for you.

```swift
import Vapor
import Passes

let passDelegate = PassDelegate()

func routes(_ app: Application) throws {
    let passesService = PassesService(app: app, delegate: passDelegate)
    passesService.registerRoutes()
}
```

> [!NOTE]
> Notice how the `delegate` is created as a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits!

#### Push Notifications

If you wish to include routes specifically for sending push notifications to updated passes you can also include this line in your `routes(_:)` method. You'll need to pass in whatever `Middleware` you want Vapor to use to authenticate the two routes.

> [!IMPORTANT]
> If you don't include this line, you have to configure an APNS container yourself

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

#### Pass data model middleware

Whether you include the routes or not, you'll want to add a model middleware that sends push notifications and updates the `updatedAt` field when your pass data updates. The model middleware could also create and link the `PKPass` during the creation of the pass data, depending on your requirements. 

You can implement it like so:

```swift
import Vapor
import Fluent
import Passes

struct PassDataMiddleware: AsyncModelMiddleware {
    private unowned let app: Application

    init(app: Application) {
        self.app = app
    }

    // Create the PKPass and add it to the PassData automatically at creation
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

and register it in *configure.swift*:

```swift
app.databases.middleware.use(PassDataMiddleware(app: app), on: .psql)
```

> [!IMPORTANT]
> Whenever your pass data changes, you must update the *updatedAt* time of the linked pass so that Apple knows to send you a new pass.

#### Apple Push Notification service

If you did not include the routes, remember to configure APNs yourself like this:

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

### Custom Implementation

If you don't like the schema names that are used by default, you can instead create your own models conforming to `PassModel`, `DeviceModel`, `PassesRegistrationModel` and `ErrorLogModel` and instantiate the generic `PassesServiceCustom`, providing it your model types.

```swift
import PassKit
import Passes

let passesService = PassesServiceCustom<MyPassType, MyDeviceType, MyPassesRegistrationType, MyErrorLogType>(app: app, delegate: delegate)
```

### Register Migrations

If you're using the default schemas provided by this package you can register the default models in your `configure(_:)` method:

```swift
PassesService.register(migrations: app.migrations)
```

> [!IMPORTANT]
> Register the default models before the migration of your pass data model.

### Generate Pass Content

To generate and distribute the `.pkpass` bundle, pass the `PassesService` object to your `RouteCollection`:

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

and then use it in route handlers:

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
    headers.add(name: .contentDisposition, value: "attachment; filename=pass.pkpass") // Add this header only if you are serving the pass in a web page
    headers.add(name: .lastModified, value: String(passData.pass.updatedAt?.timeIntervalSince1970 ?? 0))
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```

## 📦 Wallet Orders

Add the `Orders` product to your target's dependencies:

```swift
.product(name: "Orders", package: "PassKit")
```

> [!WARNING]
> The `Orders` module is WIP, right now you can only set up the models and generate `.order` bundles.
APNS support and order updates will be added soon. See the `Orders` target's documentation.