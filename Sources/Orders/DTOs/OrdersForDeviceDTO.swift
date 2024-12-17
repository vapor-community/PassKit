import Vapor

struct OrdersForDeviceDTO: Content {
    let orderIdentifiers: [String]
    let lastModified: String

    init(with orderIdentifiers: [String], maxDate: Date) {
        self.orderIdentifiers = orderIdentifiers
        self.lastModified = String(maxDate.timeIntervalSince1970)
    }
}
