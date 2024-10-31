# Getting Started with Orders

Create the order data model, build an order for Apple Wallet and distribute it with a Vapor server.

## Overview

The Orders framework provides models to save all the basic information for orders, user devices and their registration to each order.
For all the other custom data needed to generate the order, such as the barcodes, merchant info, etc., you have to create your own model and its model middleware to handle the creation and update of order.
The order data model will be used to generate the `order.json` file contents.

The order you distribute to a user is a signed bundle that contains the `order.json` file, images, and optional localizations.
The Orders framework provides the ``OrdersService`` class that handles the creation of the order JSON file and the signing of the order bundle, using an ``OrdersDelegate`` that you must implement.
The ``OrdersService`` class also provides methods to send push notifications to all devices registered when you update an order, and all the routes that Apple Wallet uses to retrieve orders.

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
        try await database.schema(OrderData.schema)
            .id()
            .field("order_id", .uuid, .required, .references(Order.schema, .id, onDelete: .cascade))
            .field("merchant_name", .string, .required)
            .create()
    }
    
    public func revert(on database: Database) async throws {
        try await database.schema(OrderData.schema).delete()
    }
}
```

### Handle Cleanup

Depending on your implementation details, you may want to automatically clean out the orders and devices table when a registration is deleted.
The implementation will be based on your type of SQL database, as there's not yet a Fluent way to implement something like SQL's `NOT EXISTS` call with a `DELETE` statement.

> Warning: Be careful with SQL triggers, as they can have unintended consequences if not properly implemented.

### Model the order.json contents

Create a `struct` that implements ``OrderJSON/Properties`` which will contain all the fields for the generated `order.json` file.
Create an initializer that takes your custom order data, the ``Order`` and everything else you may need.

> Tip: For information on the various keys available see the [documentation](https://developer.apple.com/documentation/walletorders/order).

```swift
import Orders

struct OrderJSONData: OrderJSON.Properties {
    let schemaVersion = OrderJSON.SchemaVersion.v1
    let orderTypeIdentifier = Environment.get("ORDER_TYPE_IDENTIFIER")!
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

Create a delegate class that implements ``OrdersDelegate``.

Because the files for your order's template and the method of encoding might vary by order type, you'll be provided the ``Order`` for those methods.
In the ``OrdersDelegate/encode(order:db:encoder:)`` method, you'll want to encode a `struct` that conforms to ``OrderJSON``.

```swift
import Vapor
import Fluent
import Orders

final class OrderDelegate: OrdersDelegate {
    func encode<O: OrderModel>(order: O, db: Database, encoder: JSONEncoder) async throws -> Data {
        // The specific OrderData class you use here may vary based on the `order.typeIdentifier`
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

    func template<O: OrderModel>(for order: O, db: Database) async throws -> String {
        // The location might vary depending on the type of order.
        "Templates/Orders/"
    }
}
```

### Initialize the Service

Next, initialize the ``OrdersService`` inside the `configure.swift` file.
This will implement all of the routes that Apple Wallet expects to exist on your server.
In the `signingFilesDirectory` you specify there must be the `WWDR.pem`, `certificate.pem` and `key.pem` files.
If they are named like that you're good to go, otherwise you have to specify the custom name.

> Tip: Obtaining the three certificates files could be a bit tricky. You could get some guidance from [this guide](https://github.com/alexandercerutti/passkit-generator/wiki/Generating-Certificates) and [this video](https://www.youtube.com/watch?v=rJZdPoXHtzI). Those guides are for Wallet passes, but the process is similar for Wallet orders.

```swift
import Fluent
import Vapor
import Orders

let orderDelegate = OrderDelegate()

public func configure(_ app: Application) async throws {
    ...
    let ordersService = try OrdersService(
        app: app,
        delegate: orderDelegate,
        signingFilesDirectory: "Certificates/Orders/"
    )
}
```

> Note: Notice how the ``OrdersDelegate`` is created as a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `configure(_:)` method exits.

If you wish to include routes specifically for sending push notifications to updated orders, you can also pass to the ``OrdersService`` initializer whatever `Middleware` you want Vapor to use to authenticate the two routes. Doing so will add two routes, the first one sends notifications and the second one retrieves a list of push tokens which would be sent a notification.

```http
POST https://example.com/api/orders/v1/push/{orderTypeIdentifier}/{orderIdentifier} HTTP/2
```

```http
GET https://example.com/api/orders/v1/push/{orderTypeIdentifier}/{orderIdentifier} HTTP/2
```

### Custom Implementation of OrdersService

If you don't like the schema names provided by default, you can create your own models conforming to ``OrderModel``, `DeviceModel`, ``OrdersRegistrationModel`` and `ErrorLogModel` and instantiate the generic ``OrdersServiceCustom``, providing it your model types.

```swift
import Fluent
import Vapor
import PassKit
import Orders

let orderDelegate = OrderDelegate()

public func configure(_ app: Application) async throws {
    ...
    let ordersService = try OrdersServiceCustom<
        MyOrderType,
        MyDeviceType,
        MyOrdersRegistrationType,
        MyErrorLogType
    >(
        app: app,
        delegate: orderDelegate,
        signingFilesDirectory: "Certificates/Orders/"
    )
}
```

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
            typeIdentifier: Environment.get("ORDER_TYPE_IDENTIFIER")!,
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

You could register it in the `configure.swift` file.

```swift
app.databases.middleware.use(OrderDataMiddleware(service: ordersService), on: .psql)
```

> Important: Whenever your order data changes, you must update the ``Order/updatedAt`` time of the linked ``Order`` so that Wallet knows to retrieve a new order.

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

> Note: You'll have to register the `OrdersController` in the `configure.swift` file, in order to pass it the ``OrdersService`` object.

Then use the object inside your route handlers to generate the order bundle with the ``OrdersService/generateOrderContent(for:on:)`` method and distribute it with the "`application/vnd.apple.order`" MIME type.

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
    headers.add(name: .contentDisposition, value: "attachment; filename=name.order")
    headers.lastModified = HTTPHeaders.LastModified(order.updatedAt ?? Date.distantPast)
    headers.add(name: .contentTransferEncoding, value: "binary")
    return Response(status: .ok, headers: headers, body: body)
}
```
