import Foundation

/// A perceptual speed scale with the system-equivalent gain at its midpoint.
enum PointerSpeedScale {
    static let range = 0.1...4.0

    static func value(at position: Double) -> Double {
        let position = min(1, max(0, position.isFinite ? position : 0.5))
        if position <= 0.5 { return pow(10, position * 2 - 1) }
        return pow(4, (position - 0.5) * 2)
    }

    static func position(for value: Double) -> Double {
        let value = min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 1))
        if value <= 1 { return (log10(value) + 1) / 2 }
        return 0.5 + log(value) / log(4) / 2
    }

    /// Normalize decimal digits from the current numbering system without accepting
    /// grouping, exponent notation, mixed separators, or a partial numeric prefix.
    private static func normalizedNumeric(_ text: String, locale: Locale) -> String? {
        guard text.count <= 128 else { return nil }
        let decimal = locale.decimalSeparator ?? "."
        var result = ""
        var separators = 0
        for character in text {
            if character == "." || character == "," || String(character) == decimal {
                separators += 1
                guard separators <= 1 else { return nil }
                result.append(".")
            } else if character.unicodeScalars.count == 1,
                character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
                let digit = character.wholeNumberValue, (0...9).contains(digit)
            {
                result.append(String(digit))
            } else if character.unicodeScalars.allSatisfy({ [0x061C, 0x200E, 0x200F].contains($0.value) }) {
                // Locale formatters can add directional marks around Arabic numbers.
                continue
            } else {
                return nil
            }
        }
        return result
    }

    static func isNumericDraft(_ text: String, locale: Locale = .current) -> Bool {
        normalizedNumeric(text, locale: locale) != nil
    }

    static func parse(_ text: String, in range: ClosedRange<Double> = Self.range, locale: Locale = .current) -> Double?
    {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("×") || text.lowercased().hasSuffix("x") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let normalized = normalizedNumeric(text, locale: locale),
            let value = Double(normalized), value.isFinite, range.contains(value)
        else { return nil }
        return value
    }

    static func adjustedValue(_ value: Double, by increments: Int, step: Double, in range: ClosedRange<Double>)
        -> Double
    {
        // Decimal arithmetic avoids accumulating binary floating-point artifacts
        // while preserving the offset of an exact entry between ordinary steps.
        let locale = Locale(identifier: "en_US_POSIX")
        let base = Decimal(string: String(value), locale: locale) ?? Decimal(value)
        let increment = Decimal(string: String(step), locale: locale) ?? Decimal(step)
        let proposed = NSDecimalNumber(decimal: base + increment * Decimal(increments)).doubleValue
        return min(range.upperBound, max(range.lowerBound, proposed))
    }

    static func formatted(_ value: Double, minimumFractionDigits: Int = 0, locale: Locale = .current) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(minimumFractionDigits...15)).locale(locale))
    }
}
