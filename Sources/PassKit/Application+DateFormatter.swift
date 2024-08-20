//
//  Application+DateFormatter.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 20/08/24.
//

import Vapor

package extension Application {
    var dateFormatters: DateFormatters {
        .init(application: self)
    }

    struct DateFormatters {
        struct PosixKey: StorageKey {
            typealias Value = DateFormatter
        }

        package var posix: DateFormatter {
            if let existing = self.application.storage[PosixKey.self] {
                return existing
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                self.application.storage[PosixKey.self] = formatter
                return formatter
            }
        }

        struct ISO8601Key: StorageKey {
            typealias Value = ISO8601DateFormatter
        }

        package var iso8601: ISO8601DateFormatter {
            if let existing = self.application.storage[ISO8601Key.self] {
                return existing
            } else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = .withInternetDateTime
                self.application.storage[ISO8601Key.self] = formatter
                return formatter
            }
        }

        let application: Application
    }
}