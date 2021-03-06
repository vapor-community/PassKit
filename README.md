# PassKit

[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Platform](https://img.shields.io/badge/Platforms-macOS%20|%20Linux-lightgrey.svg)](https://github.com/gargoylesoft/PassKit)

A Vapor package which handles all the server side elements required to implement passes for iOS.

## NOTE

This package requires Vapor 4. 


## Usage

### Model the `pass.json` contents

Create a `struct` that implements `Encodable` which will contain all the fields for the generated `pass.json` file.  For information on the various keys 
available see [Understanding the Keys](https://developer.apple.com/library/archive/documentation/UserExperience/Reference/PassKit_Bundle/Chapters/Introduction.html).

```swift
struct PassJsonData: Encodable {
    public static let token = "EB80D9C6-AD37-41A0-875E-3802E88CA478"
    
    private let formatVersion = 1
    private let passTypeIdentifier = "pass.com.yoursite.passType"
    private let authenticationToken = token
    ...
}
```

### Implement your pass data model

Your data model should contain all the fields that you store for your pass, as well as a foreign key for the pass itself.

```swift
public class PassData: PassKitPassData {
    public static var schema = "pass_data"

    @ID(key: "id")
    public var id: Int?

    @Parent(key: "pass_id")
    public var pass: PKPass

    @Field(key: "punches")
    public var punches: Int

    public required init() {}
}

extension PassData: Migration {
    public func prepare(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema)
            .field("id", .int, .identifier(auto: true))
            .field("punches", .int, .required)
            .field("pass_id", .uuid, .required)
            .foreignKey("pass_id", references: PKPass.schema, "id", onDelete: .cascade)
            .create()
            .flatMap {
                guard let db = database as? PostgresDatabase else {
                    fatalError("Looks like you're not using PostgreSQL any longer!")
                }
                
                return .andAllSucceed(
                    trigger.map { db.sql().raw($0).run() },
                    on: db.eventLoop
                )
        }
    }
    
    public func revert(on database: Database) -> EventLoopFuture<Void> {
        database.schema(Self.schema).delete()
    }
}

// db.sql().raw() doesn't allow for multiple statements, so make it an array
private let trigger: [SQLQueryString] = [
    """
    CREATE OR REPLACE FUNCTION "public"."UpdateModified"() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
    UPDATE \(PKPass.schema)
    SET modified = now()
    WHERE "id" = NEW.pass_id;
    
    RETURN NEW;
    END;
    $$;
    """,
    
    """
    DROP TRIGGER IF EXISTS "OnPassDataUpdated" ON "public"."\(PassData.schema)";
    """,
    
    """
    CREATE TRIGGER "OnPassDataUpdated"
    AFTER UPDATE OF "punches" ON "public"."\(PassData.schema)"
    FOR EACH ROW
    EXECUTE PROCEDURE "public"."UpdateModified"();
    """
]
```

**IMPORTANT**: Whenever your pass data changes, you must update the *modified* time of the linked pass so that Apple knows to send you a new pass. The given example, above, is for PostgreSQL, but the concept should be the same for any database.  The syntax for the triggers will simply be a little different.  You can do this in `ModelMiddleware` but I like to have the database itself do it so if anything outside the app makes a change, it still updates.

### Implement the delegate.

Create a delegate file that implements `PassKitDelegate`.  There are other fields available which have reasonable default values. See the delegate's documentation.
Because the files for your pass' template and the method of encoding might vary by pass type, you'll be provided the pass for those methods.  

```swift
import Vapor
import PassKit

class PKD: PassKitDelegate {
    var sslSigningFilesDirectory = URL(fileURLWithPath: "/www/myapp/sign", isDirectory: true)

    var pemPrivateKeyPassword: String? = "12345"

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

#### Handle cleanup

Depending on your implementation details, you'll likely want to automatically clean out the passes and devices table when
a registration is deleted.  You'll need to implement based on your type of SQL database as there's not yet a Fluent way
to implement something like SQL's `NOT EXISTS` call with a `DELETE` statement.  If you're using PostgreSQL, you can
setup these triggers/methods:

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

### Register Routes

Next, register the routes in `routes.swift`.  Notice how the `delegate` is created as
a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits!  This will
implement all of the routes that PassKit expects to exist on your server for you.

```swift
let delegate = PKD()

func routes(_ app: Application) throws {
    let pk = PassKit(app: app, delegate: delegate)
    pk.registerRoutes(authorizationCode: PassData.token)
}
```

#### Push Notifications

If you wish to include routes specifically for sending push notifications to updated passes you can also include this line in your `routes(_:)` method.  You'll
need to pass in whatever `Middleware` you want Vapor to use to authenticate the two routes.  Note that PassKit will *not* send a push notification if you
use the sandbox, which is why this method doesn't let you pass the APNs environment type.  If you've not yet configured APNSwift, calling this method will
do so for you.

```swift
try pk.registerPushRoutes(middleware: PushAuthMiddleware())
```

That will add two routes:

- POST .../api/v1/push/*passTypeIdentifier*/*passBarcode* (Sends notifications)
- GET .../api/v1/push/*passTypeIdentifier*/*passBarcode* (Retrieves a list of push tokens which would be sent a notification)

Whether you include the routes or not, you'll want to add a method that sends push notifications when your pass data updates.  If you did *not* include
the routes remember to configure APNSwift yourself.  You can implement it like so:

```swift
struct PassDataMiddleware: ModelMiddleware {
    private unowned let app: Application

    init(app: Application) {
        self.app = app
    }

    func update(model: PassData, on db: Database, next: AnyModelResponder) -> EventLoopFuture<Void> {
        next.update(model, on: db).flatMap {
            PassKit.sendPushNotifications(for: model.$pass, on: db, app: self.app)
        }
    }
}
```

and register it in *configure.swift*:

```swift
app.databases.middleware.use(PassDataMiddleware(app: app), on: .psql)
```

#### Custom Implementation

If you don't like the schema names that are used by default, you can instead instantiate the generic `PassKitCustom` and provide your model types.

```swift
let pk = PassKitCustom<MyPassType, MyDeviceType, MyRegistrationType, MyErrorType>(app: app, delegate: delegate)
```

### Register Migrations

Finally, if you're using the default schemas provided by this package you can register the default models in your `configure(_:)` method:

```swift
PassKit.register(migrations: app.migrations)
```

