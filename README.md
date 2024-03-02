# PassKit

[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Platform](https://img.shields.io/badge/Platforms-macOS%20|%20Linux-lightgrey.svg)](https://github.com/gargoylesoft/PassKit)

A Vapor package which handles all the server side elements required to implement passes for Apple Wallet.

## NOTE

This package requires Vapor 4.

## Usage

### Implement your pass data model

Your data model should contain all the fields that you store for your pass, as well as a foreign key for the pass itself.

```swift
final class PassData: PassKitPassData {
    static let schema = "pass_data"

    @ID
    var id: UUID?

    @Parent(key: "pass_id")
    var pass: PKPass

    // Add any other field relative to your app, such as a location, a date, etc.
    @Field(key: "punches")
    var punches: Int

    init() {}
}

struct CreatePassData: AsyncMigration {
    public func prepare(on database: Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field("punches", .int, .required)
            .field("pass_id", .uuid, .required, .references(PKPass.schema, "id", onDelete: .cascade))
            .create()
    }
    
    public func revert(on database: Database) -> EventLoopFuture<Void> {
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
struct PassJsonData: Encodable {
    public static let token = "EB80D9C6-AD37-41A0-875E-3802E88CA478"
    
    private let formatVersion = 1
    private let passTypeIdentifier = "pass.com.yoursite.passType"
    private let authenticationToken = token
    let serialNumber: String
    let relevantDate: String
    let barcodes: [PassJsonData.Barcode]
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

Create a delegate file that implements `PassKitDelegate`.
In the `sslSigningFilesDirectory` you specify there must be the `WWDR.pem`, `passcertificate.pem` and `passkey.pem` files. If they are named like that you're good to go, otherwise you have to specify the custom name.
There are other fields available which have reasonable default values. See the delegate's documentation.
Because the files for your pass' template and the method of encoding might vary by pass type, you'll be provided the pass for those methods.

```swift
import Vapor
import PassKit

class PKD: PassKitDelegate {
    var sslSigningFilesDirectory = URL(fileURLWithPath: "/www/myapp/sign", isDirectory: true)

    var pemPrivateKeyPassword: String? = Environment.get("PEM_PRIVATE_KEY_PASSWORD")!

    func encode<P: PassKitPass>(pass: P, db: Database, encoder: JSONEncoder) -> EventLoopFuture<Data> {
        // The specific PassData class you use here may vary based on the pass.type if you have multiple
        // different types of passes, and thus multiple types of pass data.
        return PassData.query(on: db)
            .filter(\.$pass == pass.id!)
            .first()
            .unwrap(or: Abort(.internalServerError))
            .flatMap { passData in
                guard let data = try? encoder.encode(PassJsonData(data: passData, pass: pass)) else {
                    return db.eventLoop.makeFailedFuture(Abort(.internalServerError))
                }
                return db.eventLoop.makeSucceededFuture(data)
        }
    }

    func template<P: PassKitPass>(for: P, db: Database) -> EventLoopFuture<URL> {
        // The location might vary depending on the type of pass.
        let url = URL(fileURLWithPath: "/www/myapp/pass", isDirectory: true)
        return db.eventLoop.makeSucceededFuture(url)
    }
}
```

You **must** explicitly declare `pemPrivateKeyPassword` as a `String?` or Swift will ignore it as it'll think it's a `String` instead.

### Register Routes

Next, register the routes in `routes.swift`.  Notice how the `delegate` is created as
a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits!
This will implement all of the routes that PassKit expects to exist on your server for you.

```swift
let delegate = PKD()

func routes(_ app: Application) throws {
    let pk = PassKit(app: app, delegate: delegate)
    pk.registerRoutes(authorizationCode: PassData.token)
}
```

#### Push Notifications

If you wish to include routes specifically for sending push notifications to updated passes you can also include this line in your `routes(_:)` method. You'll need to pass in whatever `Middleware` you want Vapor to use to authenticate the two routes. If you don't include this line, you have to configure an APNS container yourself

```swift
try pk.registerPushRoutes(middleware: SecretMiddleware())
```

That will add two routes:

- POST .../api/v1/push/*passTypeIdentifier*/*passBarcode* (Sends notifications)
- GET .../api/v1/push/*passTypeIdentifier*/*passBarcode* (Retrieves a list of push tokens which would be sent a notification)

Whether you include the routes or not, you'll want to add a middleware that sends push notifications and updates the `modified` field when your pass data updates. You can implement it like so:

```swift
struct PassDataMiddleware: AsyncModelMiddleware {
    private unowned let app: Application

    init(app: Application) {
        self.app = app
    }

    func update(model: PassData, on db: Database, next: AnyAsyncModelResponder) async throws {
        let pkPass = try await model.$pass.get(on: db)
        pkPass.modified = Date()
        try await pkPass.update(on: db)
        try await next.update(model, on: db)
        try await PassKit.sendPushNotifications(for: model.$pass.get(on: db), on: db, app: self.app)
    }
}
```

and register it in *configure.swift*:

```swift
app.databases.middleware.use(PassDataMiddleware(app: app), on: .psql)
```

**IMPORTANT**: Whenever your pass data changes, you must update the *modified* time of the linked pass so that Apple knows to send you a new pass.

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
    as: .init(string: "passkit"),
    isDefault: false
)
```

#### Custom Implementation

If you don't like the schema names that are used by default, you can instead instantiate the generic `PassKitCustom` and provide your model types.

```swift
let pk = PassKitCustom<MyPassType, MyDeviceType, MyRegistrationType, MyErrorType>(app: app, delegate: delegate)
```

### Register Migrations

If you're using the default schemas provided by this package you can register the default models in your `configure(_:)` method:

```swift
PassKit.register(migrations: app.migrations)
```

Register the default models before the migration of your pass data model.

### Generate Pass Content

To generate and distribute the `.pkpass` bundle, pass a `PassKit` object to your `RouteCollection`:

```swift
import Vapor
import PassKit

struct PassesController: RouteCollection {
    let passKit: PassKit

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

    let bundle = try await passKit.generatePassContent(for: passData.pass, on: req.db).get()
    let body = Response.Body(data: bundle)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/vnd.apple.pkpass")
    headers.add(name: .contentDisposition, value: "attachment; filename=pass.pkpass") // Add this header only if you are serving the pass in a web page
    headers.add(name: .lastModified, value: String(passData.pass.modified.timeIntervalSince1970))
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```
