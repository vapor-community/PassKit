# Getting Started with Orders

Implement the order data model, define the order file contents, build a distributable order and distribute it.

## Overview

The Orders framework provides models to save all the basic information for orders, user devices and their registration to each order.
For all the other custom data needed to generate the order (such as the barcodes, merchant info, etc.), you have to create your own model and its model middleware to handle the creation and update of order.
The order data model will be used to generate the `order.json` file contents, along side image files for the icon and other visual elements, such as a logo.

The order you distribute to a user is a signed bundle that contains the `order.json` file, images, and optional localizations.
The Orders framework provides the ``OrdersService`` class that handles the creation of the order JSON file and the signing of the order bundle, using an ``OrdersDelegate`` that you must implement.
The ``OrdersService`` class also provides methods to send push notifications to all devices registered to an order when it's updated and all the routes that Apple Wallet expects to get and update orders.

### Implement the Order Data Model

Your data model should contain all the fields that you store for your order, as well as a foreign key to ``Order``, the order model offered by the Orders framework.

```swift
import Fluent
import struct Foundation.UUID
import Orders

final class OrderData: OrderDataModel, @unchecked Sendable {
    static let schema = "order_data"

    @ID
    var id: UUID?

    @Parent(key: "order_id")
    var order: Order

    // Example of other extra fields:
    @Field(key: "merchant_name")
    var merchantName: String

    // Add any other field relative to your app, such as an identifier, the order status, etc.

    init() { }
}

struct CreateOrderData: AsyncMigration {
    public func prepare(on database: Database) async throws {
        try await database.schema(Self.schema)
            .id()
            .field("order_id", .uuid, .required, .references(Order.schema, .id, onDelete: .cascade))
            .field("merchant_name", .string, .required)
            .create()
    }
    
    public func revert(on database: Database) async throws {
        try await database.schema(Self.schema).delete()
    }
}
```

### Handle Cleanup

Depending on your implementation details, you may want to automatically clean out the orders and devices table when a registration is deleted.
You'll need to implement based on your type of SQL database as there's not yet a Fluent way to implement something like SQL's `NOT EXISTS` call with a `DELETE` statement.

> Warning: Be careful with SQL triggers, as they can have unintended consequences if not properly implemented.

### Model the order.json contents

Create a `struct` that implements ``OrderJSON/Properties`` which will contain all the fields for the generated `order.json` file.
Create an initializer that takes your custom order data, the ``Order`` and everything else you may need.

> Tip: For information on the various keys available see the [documentation](https://developer.apple.com/documentation/walletorders/order).

```swift
import Orders

struct OrderJSONData: OrderJSON.Properties {
    let schemaVersion = OrderJSON.SchemaVersion.v1
    let orderTypeIdentifier = Environment.get("PASSKIT_ORDER_TYPE_IDENTIFIER")!
    let orderIdentifier: String
    let orderType = OrderJSON.OrderType.ecommerce
    let orderNumber = "HM090772020864"
    let createdAt: String
    let updatedAt: String
    let status = OrderJSON.OrderStatus.open
    let merchant: MerchantData
    let orderManagementURL = "https://www.example.com/"
    let authenticationToken: String

    private let webServiceURL = "https://example.com/api/orders/"

    struct MerchantData: OrderJSON.Merchant {
        let merchantIdentifier = "com.example.pet-store"
        let displayName: String
        let url = "https://www.example.com/"
        let logo = "pet_store_logo.png"
    }
    
    init(data: OrderData, order: Order) {
        self.orderIdentifier = order.id!.uuidString
        self.authenticationToken = order.authenticationToken
        self.merchant = MerchantData(displayName: data.title)

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = .withInternetDateTime
        self.createdAt = dateFormatter.string(from: order.createdAt!)
        self.updatedAt = dateFormatter.string(from: order.updatedAt!)
    }
}
```

> Important: You **must** add `api/orders/` to your `webServiceURL`, as shown in the example above.

### Implement the Delegate

Create a delegate file that implements ``OrdersDelegate``.
In the ``OrdersDelegate/sslSigningFilesDirectory`` you specify there must be the `WWDR.pem`, `ordercertificate.pem` and `orderkey.pem` files.
If they are named like that you're good to go, otherwise you have to specify the custom name.

> Tip: Obtaining the three certificates files could be a bit tricky. You could get some guidance from [this guide](https://github.com/alexandercerutti/passkit-generator/wiki/Generating-Certificates) and [this video](https://www.youtube.com/watch?v=rJZdPoXHtzI). Those guides are for Wallet passes, but the process is similar for Wallet orders.

There are other fields available which have reasonable default values. See ``OrdersDelegate``'s documentation.

Because the files for your order's template and the method of encoding might vary by order type, you'll be provided the ``Order`` for those methods.
In the ``OrdersDelegate/encode(order:db:encoder:)`` method, you'll want to encode a `struct` that conforms to ``OrderJSON``.

```swift
import Vapor
import Fluent
import Orders

final class OrderDelegate: OrdersDelegate {
    let sslSigningFilesDirectory = URL(fileURLWithPath: "Certificates/Orders/", isDirectory: true)

    let pemPrivateKeyPassword: String? = Environment.get("ORDER_PEM_PRIVATE_KEY_PASSWORD")!

    func encode<O: OrderModel>(order: O, db: Database, encoder: JSONEncoder) async throws -> Data {
        // The specific OrderData class you use here may vary based on the `order.orderTypeIdentifier`
        // if you have multiple different types of orders, and thus multiple types of order data.
        guard let orderData = try await OrderData.query(on: db)
            .filter(\.$order.$id == order.requireID())
            .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(OrderJSONData(data: orderData, order: order)) else {
            throw Abort(.internalServerError)
        }
        return data
    }

    func template<O: OrderModel>(for order: O, db: Database) async throws -> URL {
        // The location might vary depending on the type of order.
        return URL(fileURLWithPath: "Templates/Orders/", isDirectory: true)
    }
}
```

> Important: You **must** explicitly declare ``OrdersDelegate/pemPrivateKeyPassword`` as a `String?` or Swift will ignore it as it'll think it's a `String` instead.

### Register the Routes

Next, register the routes in `routes.swift`.
This will implement all of the routes that Apple Wallet expects to exist on your server for you.

```swift
import Vapor
import Orders

let orderDelegate = OrderDelegate()

func routes(_ app: Application) throws {
    let ordersService = try OrdersService(delegate: orderDelegate)
    ordersService.registerRoutes(app: app)
}
```

> Note: Notice how the ``OrdersDelegate`` is created as a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits.

If you wish to include routes specifically for sending push notifications to updated orders, you can also pass to the ``OrdersService/registerRoutes(app:pushMiddleware:)`` whatever `Middleware` you want Vapor to use to authenticate the two routes. Doing so will add two routes, the first one sends notifications and the second one retrieves a list of push tokens which would be sent a notification.

```http
POST https://example.com/api/orders/v1/push/{orderTypeIdentifier}/{orderIdentifier} HTTP/2
```

```http
GET https://example.com/api/orders/v1/push/{orderTypeIdentifier}/{orderIdentifier} HTTP/2
```

### Custom Implementation of OrdersService

If you don't like the schema names provided by the framework that are used by default, you can instead create your own models conforming to ``OrderModel``, `DeviceModel`, ``OrdersRegistrationModel`` and `ErrorLogModel` and instantiate the generic ``OrdersServiceCustom``, providing it your model types.

```swift
import PassKit
import Orders

let ordersService = try OrdersServiceCustom<MyOrderType, MyDeviceType, MyOrdersRegistrationType, MyErrorLogType>(delegate: delegate)
```

> Important: `DeviceModel` and `ErrorLogModel` are defined in the PassKit framework.

### Register Migrations

If you're using the default schemas provided by this framework, you can register the default models in your `configure(_:)` method:

```swift
OrdersService.register(migrations: app.migrations)
```

> Important: Register the default models before the migration of your order data model.

### Order Data Model Middleware

You'll want to create a model middleware to handle the creation and update of the order data model.
This middleware could be responsible for creating and linking an ``Order`` to the order data model, depending on your requirements.
When your order data changes, it should also update the ``Order/updatedAt`` field of the ``Order`` and send a push notification to all devices registered to that order.

```swift
import Vapor
import Fluent
import Orders

struct OrderDataMiddleware: AsyncModelMiddleware {
    private unowned let service: OrdersService

    init(service: OrdersService) {
        self.service = service
    }

    // Create the `Order` and add it to the `OrderData` automatically at creation
    func create(model: OrderData, on db: Database, next: AnyAsyncModelResponder) async throws {
        let order = Order(
            orderTypeIdentifier: "order.com.yoursite.orderType",
            authenticationToken: Data([UInt8].random(count: 12)).base64EncodedString())
        try await order.save(on: db)
        model.$order.id = try order.requireID()
        try await next.create(model, on: db)
    }

    func update(model: OrderData, on db: Database, next: AnyAsyncModelResponder) async throws {
        let order = try await model.$order.get(on: db)
        order.updatedAt = Date()
        try await order.save(on: db)
        try await next.update(model, on: db)
        try await service.sendPushNotifications(for: order, on: db)
    }
}
```

Remember to register it in the `routes.swift` file.

```swift
app.databases.middleware.use(OrderDataMiddleware(app: app), on: .psql)
```

> Important: Whenever your order data changes, you must update the ``Order/updatedAt`` time of the linked order so that Apple knows to send you a new order.

### Generate the Order Content

To generate and distribute the `.order` bundle, pass the ``OrdersService`` object to your `RouteCollection`.

```swift
import Fluent
import Vapor
import Orders

struct OrdersController: RouteCollection {
    let ordersService: OrdersService

    func boot(routes: RoutesBuilder) throws {
        ...
    }
}
```

Then use the object inside your route handlers to generate and distribute the order bundle.

```swift
fileprivate func orderHandler(_ req: Request) async throws -> Response {
    ...
    guard let orderData = try await OrderData.query(on: req.db)
        .filter(...)
        .with(\.$order)
        .first()
    else {
        throw Abort(.notFound)
    }

    let bundle = try await ordersService.generateOrderContent(for: orderData.order, on: req.db)
    let body = Response.Body(data: bundle)
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/vnd.apple.order")
    headers.add(name: .contentDisposition, value: "attachment; filename=name.order") // Add this header only if you are serving the order in a web page
    headers.add(name: .lastModified, value: String(orderData.order.updatedAt?.timeIntervalSince1970 ?? 0))
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```
