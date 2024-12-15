import FluentKit

/// Represents the `Model` that stores custom app data associated to Wallet orders.
public protocol OrderDataModel: Model {
    associatedtype OrderType: OrderModel

    /// An identifier for the order type associated with the order.
    static var typeIdentifier: String { get }

    /// The foreign key to the order table.
    var order: OrderType { get set }

    /// Encode the order into JSON.
    ///
    /// This method should generate the entire order JSON.
    ///
    /// - Parameter db: The SQL database to query against.
    ///
    /// - Returns: An object that conforms to ``OrderJSON/Properties``.
    ///
    /// > Tip: See the [`Order`](https://developer.apple.com/documentation/walletorders/order) object to understand the keys.
    func orderJSON(on db: any Database) async throws -> any OrderJSON.Properties

    /// Should return a URL path which points to the template data for the order.
    ///
    /// The path should point to a directory containing all the images and localizations for the generated `.order` archive
    /// but should *not* contain any of these items:
    ///  - `manifest.json`
    ///  - `order.json`
    ///  - `signature`
    ///
    /// - Parameter db: The SQL database to query against.
    ///
    /// - Returns: A URL path which points to the template data for the order.
    func template(on db: any Database) async throws -> String
}

extension OrderDataModel {
    var _$order: Parent<OrderType> {
        guard let mirror = Mirror(reflecting: self).descendant("_order"),
            let order = mirror as? Parent<OrderType>
        else {
            fatalError("order property must be declared using @Parent")
        }

        return order
    }
}
