//
//  OrdersForDeviceDTO.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 30/06/24.
//

import Vapor

struct OrdersForDeviceDTO: Content {
    let orderIdentifiers: [String]
    let lastModified: String

    init(with orderIdentifiers: [String], maxDate: Date) {
        self.orderIdentifiers = orderIdentifiers
        lastModified = String(maxDate.timeIntervalSince1970)
    }
}