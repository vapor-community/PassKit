import Foundation
import Orders

extension OrderJSON.SchemaVersion: Decodable {}
extension OrderJSON.OrderType: Decodable {}
extension OrderJSON.OrderStatus: Decodable {}

struct OrderJSONData: OrderJSON.Properties, Decodable {
    let schemaVersion = OrderJSON.SchemaVersion.v1
    let orderTypeIdentifier = OrderData.typeIdentifier
    let orderIdentifier: String
    let orderType = OrderJSON.OrderType.ecommerce
    let orderNumber = "HM090772020864"
    let createdAt: String
    let updatedAt: String
    let status = OrderJSON.OrderStatus.open
    let merchant: MerchantData
    let orderManagementURL = "https://www.example.com/"
    let authenticationToken: String

    private let webServiceURL = "https://www.example.com/api/orders/"

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case orderTypeIdentifier, orderIdentifier, orderType, orderNumber
        case createdAt, updatedAt
        case status, merchant
        case orderManagementURL, authenticationToken, webServiceURL
    }

    struct MerchantData: OrderJSON.Merchant, Decodable {
        let merchantIdentifier = "com.example.pet-store"
        let displayName: String
        let url = "https://www.example.com/"
        let logo = "pet_store_logo.png"

        enum CodingKeys: String, CodingKey {
            case merchantIdentifier, displayName, url, logo
        }
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
