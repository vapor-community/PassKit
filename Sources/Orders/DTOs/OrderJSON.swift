/// The structure of a `order.json` file.
public struct OrderJSON {
    /// A protocol that defines the structure of a `order.json` file.
    ///
    /// > Tip: See the [`Order`](https://developer.apple.com/documentation/walletorders/order) object to understand the keys.
    public protocol Properties: Encodable {
        /// The date and time when the customer created the order, in RFC 3339 format.
        var createdAt: String { get }

        /// A unique order identifier scoped to your order type identifier.
        ///
        /// In combination with the order type identifier, this uniquely identifies an order within the system and isn’t displayed to the user.
        var orderIdentifier: String { get }

        /// A URL where the customer can manage the order.
        var orderManagementURL: String { get }

        /// The type of order this bundle represents.
        ///
        /// Currently the only supported value is `ecommerce`.
        var orderType: OrderType { get }

        /// An identifier for the order type associated with the order.
        ///
        /// The value must correspond with your signing certificate and isn’t displayed to the user.
        var orderTypeIdentifier: String { get }

        /// A high-level status of the order, used for display purposes.
        ///
        /// The system considers orders with status `completed` or `cancelled` closed.
        var status: OrderStatus { get }

        /// The version of the schema used for the order.
        ///
        /// The current version is `1`.
        var schemaVersion: SchemaVersion { get }

        /// The date and time when the order was last updated, in RFC 3339 format.
        ///
        /// This should equal the `createdAt` time, if the order hasn’t had any updates.
        /// Must be monotonically increasing.
        /// Consider using a hybrid logical clock if your web service can’t make that guarantee.
        var updatedAt: String { get }
    }
}

extension OrderJSON {
    /// A protocol that represents the merchant associated with the order.
    ///
    /// > Tip: See the [`Order.Merchant`](https://developer.apple.com/documentation/walletorders/merchant) object to understand the keys.
    public protocol Merchant: Encodable {
        /// The localized display name of the merchant.
        var displayName: String { get }

        /// The Apple Merchant Identifier for this merchant, generated at `developer.apple.com`.
        var merchantIdentifier: String { get }

        /// The URL for the merchant’s website or landing page.
        var url: String { get }
    }
}

extension OrderJSON {
    /// A protocol that represents the details of a barcode for an order.
    ///
    /// > Tip: See the [`Order.Barcode`](https://developer.apple.com/documentation/walletorders/barcode) object to understand the keys.
    public protocol Barcode: Encodable {
        /// The format of the barcode.
        var format: BarcodeFormat { get }

        /// The contents of the barcode.
        var message: String { get }

        /// The text encoding of the barcode message.
        ///
        /// Typically this is `iso-8859-1`, but you may specify an alternative encoding if required.
        var messageEncoding: String { get }
    }
}

extension OrderJSON {
    /// The type of order this bundle represents.
    public enum OrderType: String, Encodable {
        case ecommerce
    }

    /// A high-level status of the order, used for display purposes.
    public enum OrderStatus: String, Encodable {
        case completed
        case cancelled
        case open
    }

    /// The version of the schema used for the order.
    public enum SchemaVersion: Int, Encodable {
        case v1 = 1
    }

    /// The format of the barcode.
    public enum BarcodeFormat: String, Encodable {
        case pdf417
        case qr
        case aztec
        case code128
    }
}
