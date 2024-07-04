# Create the Order Data Model

Implement the order data model, its model middleware and define the order file contents.

## Overview

The Orders framework provides models to save all the basic information for orders, user devices and their registration to each order.
For all the other custom data needed to generate the order (such as the barcodes, merchant info, etc.), you have to create your own model and its model middleware to handle the creation and update of order.
The order data model will be used to generate the `order.json` file contents, along side image files for the icon and other visual elements, such as a logo.

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

### Order Data Model Middleware

You'll want to create a model middleware to handle the creation and update of the order data model.
This middleware could be responsible for creating and linking an ``Order`` to the order data model, depending on your requirements.
When your order data changes, it should also update the ``Order/updatedAt`` field of the ``Order`` and send a push notification to all devices registered to that order. See <doc:DistributeUpdate> for more information on how to send push notifications.

```swift
import Vapor
import Fluent
import Orders

struct OrderDataMiddleware: AsyncModelMiddleware {
    private unowned let app: Application

    init(app: Application) {
        self.app = app
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
        try await OrdersService.sendPushNotifications(for: order, on: db, app: self.app)
    }
}
```

Remember to register it in the `configure.swift` file.

```swift
app.databases.middleware.use(OrderDataMiddleware(app: app), on: .psql)
```

> Important: Whenever your order data changes, you must update the ``Order/updatedAt`` time of the linked order so that Apple knows to send you a new order.

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

### Register Migrations

If you're using the default schemas provided by this framework, you can register the default models in your `configure(_:)` method:

```swift
OrdersService.register(migrations: app.migrations)
```

> Important: Register the default models before the migration of your order data model.

### Custom Implementation

If you don't like the schema names provided by the framework that are used by default, you can instead create your own models conforming to ``OrderModel``, `DeviceModel`, ``OrdersRegistrationModel`` and `ErrorLogModel` and instantiate the generic ``OrdersServiceCustom``, providing it your model types.

```swift
import PassKit
import Orders

let ordersService = OrdersServiceCustom<MyOrderType, MyDeviceType, MyOrdersRegistrationType, MyErrorLogType>(app: app, delegate: delegate)
```

> Important: `DeviceModel` and `ErrorLogModel` are defined in the PassKit framework.
