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

🎟️ A Vapor package which handles all the server side elements required to implement passes for Apple Wallet.

### Major Releases

The table below shows a list of PassKit major releases alongside their compatible Swift versions. 

|Version|Swift|SPM|
|---|---|---|
|0.3.1|5.10+|`from: "0.3.1"`|
|0.2.0|5.9+|`from: "0.2.0"`|
|0.1.0|5.9+|`from: "0.1.0"`|

Use the SPM string to easily include the dependendency in your `Package.swift` file

```swift
.package(url: "https://github.com/vapor-community/PassKit.git", from: "0.3.1")
```

and add it to your target's dependencies:

```swift
.product(name: "Passes", package: "PassKit")
```

> Note: This package requires Vapor 4.

## Usage

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

    // Add any other field relative to your app, such as a location, a date, etc.
    @Field(key: "punches")
    var punches: Int

    init() { }
}

struct CreatePassData: AsyncMigration {
    public func prepare(on database: Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field("punches", .int, .required)
            .field("pass_id", .uuid, .required, .references(PKPass.schema, .id, onDelete: .cascade))
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
           FROM registrations r
           WHERE d."id" = r.device_id
           LIMIT 1
       );
                
       DELETE FROM passes p
       WHERE NOT EXISTS (
           SELECT 1
           FROM registrations r
           WHERE p."id" = r.pass_id
           LIMIT 1
       );
                
       RETURN OLD;
END
$$;

CREATE TRIGGER "OnRegistrationDelete" 
AFTER DELETE ON "public"."registrations"
FOR EACH ROW
EXECUTE PROCEDURE "public"."RemoveUnregisteredItems"();
```

### Model the `pass.json` contents

Create a `struct` that implements `Encodable` which will contain all the fields for the generated `pass.json` file.
Create an initializer that takes your custom pass data, the `PKPass` and everything else you may need.
For information on the various keys available see the [documentation](https://developer.apple.com/documentation/walletpasses/pass).
See also [this guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/index.html#//apple_ref/doc/uid/TP40012195-CH1-SW1) for some help.

```swift
struct PassJSONData: Encodable {
    public static let token = "EB80D9C6-AD37-41A0-875E-3802E88CA478"
    
    private let formatVersion = 1
    private let passTypeIdentifier = "pass.com.yoursite.passType"
    private let authenticationToken = token
    let serialNumber: String
    let relevantDate: String
    let barcodes: [PassJSONData.Barcode]
    ...

    struct Barcode: Encodable {
        let altText: String
        let format = "PKBarcodeFormatQR"
        let message: String
        let messageEncoding = "iso-8859-1"
    }

    init(data: PassData, pass: PKPass) {
        ...
    }
}
```

### Implement the delegate.

Create a delegate file that implements `PassesDelegate`.
In the `sslSigningFilesDirectory` you specify there must be the `WWDR.pem`, `passcertificate.pem` and `passkey.pem` files. If they are named like that you're good to go, otherwise you have to specify the custom name.
Obtaining the three certificates files could be a bit tricky, you could get some guidance from [this guide](https://github.com/alexandercerutti/passkit-generator/wiki/Generating-Certificates) and [this video](https://www.youtube.com/watch?v=rJZdPoXHtzI).
There are other fields available which have reasonable default values. See the delegate's documentation.
Because the files for your pass' template and the method of encoding might vary by pass type, you'll be provided the pass for those methods.

```swift
import Vapor
import Fluent
import Passes

final class PKDelegate: PassesDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "Certificates/", isDirectory: true)

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
        return URL(fileURLWithPath: "PassKitTemplate/", isDirectory: true)
    }
}
```

You **must** explicitly declare `pemPrivateKeyPassword` as a `String?` or Swift will ignore it as it'll think it's a `String` instead.

### Register Routes

Next, register the routes in `routes.swift`.  Notice how the `delegate` is created as
a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits!
This will implement all of the routes that PassKit expects to exist on your server for you.

```swift
import Vapor
import Passes

let pkDelegate = PKDelegate()

func routes(_ app: Application) throws {
    let passesService = PassesService(app: app, delegate: pkDelegate)
    passesService.registerRoutes(authorizationCode: PassJSONData.token)
}
```

#### Push Notifications

If you wish to include routes specifically for sending push notifications to updated passes you can also include this line in your `routes(_:)` method. You'll need to pass in whatever `Middleware` you want Vapor to use to authenticate the two routes. If you don't include this line, you have to configure an APNS container yourself

```swift
try passesService.registerPushRoutes(middleware: SecretMiddleware(secret: "foo"))
```

That will add two routes:

- POST .../api/v1/push/*passTypeIdentifier*/*passBarcode* (Sends notifications)
- GET .../api/v1/push/*passTypeIdentifier*/*passBarcode* (Retrieves a list of push tokens which would be sent a notification)

Whether you include the routes or not, you'll want to add a model middleware that sends push notifications and updates the `updatedAt` field when your pass data updates. The model middleware could also create and link the `PKPass` during the creation of the pass data, depending on your requirements. You can implement it like so:

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
        let pkPass = PKPass(passTypeIdentifier: "pass.com.yoursite.passType")
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

If you did not include the routes remember to configure APNSwift yourself like this:

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

#### Custom Implementation

If you don't like the schema names that are used by default, you can instead instantiate the generic `PassesServiceCustom` and provide your model types.

```swift
let passesService = PassesServiceCustom<MyPassType, MyDeviceType, MyPassesRegistrationType, MyErrorLogType>(app: app, delegate: delegate)
```

### Register Migrations

If you're using the default schemas provided by this package you can register the default models in your `configure(_:)` method:

```swift
PassesService.register(migrations: app.migrations)
```

Register the default models before the migration of your pass data model.

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

and then use it in the route handler:

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
