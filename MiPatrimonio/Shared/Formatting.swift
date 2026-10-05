import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum MoneyFormatter {
    static func string(
        minorUnits: Int64,
        currencyCode: String = "EUR",
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        (Double(minorUnits) / 100).formatted(
            .currency(code: currencyCode)
                .locale(locale)
                .precision(.fractionLength(2))
        )
    }

    static func compactString(
        minorUnits: Int64,
        currencyCode: String = "EUR",
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        (Double(minorUnits) / 100).formatted(
            .currency(code: currencyCode)
                .locale(locale)
                .precision(.fractionLength(0...1))
        )
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }
}

enum MoneyParser {
    static func minorUnits(from rawValue: String) -> Int64? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
        let commaIndex = normalized.lastIndex(of: ",")
        let dotIndex = normalized.lastIndex(of: ".")

        if let commaIndex, let dotIndex {
            if commaIndex > dotIndex {
                normalized = normalized.replacingOccurrences(of: ".", with: "")
                normalized = normalized.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = normalized.replacingOccurrences(of: ",", with: "")
            }
        } else if commaIndex != nil {
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }

        // Decimal(string:) can accept a numeric prefix of malformed input.
        // Validate the whole value before converting it into money.
        guard normalized.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }

        var value = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .bankers)
        // Int64.min cannot be made positive by the transaction and balance helpers.
        guard !rounded.isNaN,
              rounded >= Decimal(Int64.min + 1), rounded <= Decimal(Int64.max) else {
            return nil
        }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

extension Date {
    func startOfMonth(calendar: Calendar = .autoupdatingCurrent) -> Date {
        let components = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: components) ?? self
    }

    func endOfMonth(calendar: Calendar = .autoupdatingCurrent) -> Date {
        let start = startOfMonth(calendar: calendar)
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? self
        return calendar.date(byAdding: .second, value: -1, to: next) ?? self
    }

    func addingMonths(_ value: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .month, value: value, to: self) ?? self
    }
}

extension Color {
    #if canImport(UIKit)
    func hexRGB() -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#1F6B7A"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
    #endif

    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch cleaned.count {
        case 3:
            red = (int >> 8) * 17
            green = (int >> 4 & 0xF) * 17
            blue = (int & 0xF) * 17
            alpha = 255
        case 6:
            red = int >> 16
            green = int >> 8 & 0xFF
            blue = int & 0xFF
            alpha = 255
        case 8:
            red = int >> 24
            green = int >> 16 & 0xFF
            blue = int >> 8 & 0xFF
            alpha = int & 0xFF
        default:
            red = 31
            green = 107
            blue = 122
            alpha = 255
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}
