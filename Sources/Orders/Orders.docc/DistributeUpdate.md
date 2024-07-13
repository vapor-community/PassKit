# Building, Distributing and Updating an Order

Build a distributable order and distribute it to your users or update an existing order.

## Overview

The order you distribute to a user is a signed bundle that contains the JSON description of the order, images, and optional localizations.
The Orders framework provides the ``OrdersService`` class that handles the creation of the order JSON file and the signing of the order bundle, using an ``OrdersDelegate`` that you must implement.
The ``OrdersService`` class also provides methods to send push notifications to all devices registered to an order when it's updated and all the routes that Apple Wallet expects to get and update orders.

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
            .filter(\.$order.$id == order.id!)
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
    let ordersService = try OrdersService(app: app, delegate: orderDelegate)
    ordersService.registerRoutes()
}
```

> Note: Notice how the ``OrdersDelegate`` is created as a global variable. You need to ensure that the delegate doesn't go out of scope as soon as the `routes(_:)` method exits.

### Push Notifications Routes

If you wish to include routes specifically for sending push notifications to updated orders you can also include this line in your `routes(_:)` method. You'll need to pass in whatever `Middleware` you want Vapor to use to authenticate the two routes.

```swift
ordersService.registerPushRoutes(middleware: SecretMiddleware(secret: "foo"))
```

That will add two routes, the first one sends notifications and the second one retrieves a list of push tokens which would be sent a notification.

```http
POST https://example.com/api/orders/v1/push/{orderTypeIdentifier}/{orderIdentifier} HTTP/2
```

```http
GET https://example.com/api/orders/v1/push/{orderTypeIdentifier}/{orderIdentifier} HTTP/2
```

### Order Data Model Middleware

Whether you include the routes or not, you'll want to add a model middleware that sends push notifications and updates the ``Order/updatedAt`` field when your order data updates. The model middleware could also create and link the ``Order`` during the creation of the order data, depending on your requirements.

See <doc:OrderData#Order-Data-Model-Middleware> for more information.

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
fileprivate func passHandler(_ req: Request) async throws -> Response {
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
