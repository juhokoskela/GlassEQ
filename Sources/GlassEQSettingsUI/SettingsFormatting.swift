import Foundation
import GlassEQCore

private let settingsResourcesBundle: Bundle = {
    let resourceBundleName = "GlassEQ_GlassEQSettingsUI.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(resourceBundleName)
    ].compactMap { $0 }

    for candidate in candidates {
        if let bundle = Bundle(url: candidate) {
            return bundle
        }
    }

    return Bundle.main
}()

func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: settingsResourcesBundle)
}

// The bundled Settings helper has no string catalog of its own and localizes against this one.
public enum SettingsUIResources {
    public static var bundle: Bundle { settingsResourcesBundle }
}

func localizedDecimal(
    _ value: Double,
    minimumFractionDigits: Int,
    maximumFractionDigits: Int,
    signed: Bool = false
) -> String {
    let formatter = NumberFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = minimumFractionDigits
    formatter.maximumFractionDigits = maximumFractionDigits
    if signed {
        formatter.positivePrefix = formatter.plusSign
    }
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func editableNumberText(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.usesSignificantDigits = true
    formatter.minimumSignificantDigits = 1
    formatter.maximumSignificantDigits = 17
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func parseEditableNumber(_ text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    if let groupingSeparator = formatter.groupingSeparator,
       !groupingSeparator.isEmpty,
       groupingSeparator != formatter.decimalSeparator,
       trimmed.contains(groupingSeparator) {
        return nil
    }

    var normalized = trimmed
    if let decimalSeparator = formatter.decimalSeparator,
       decimalSeparator != "." {
        normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
    }
    if let minusSign = formatter.minusSign,
       minusSign != "-" {
        normalized = normalized.replacingOccurrences(of: minusSign, with: "-")
    }
    if let plusSign = formatter.plusSign,
       plusSign != "+" {
        normalized = normalized.replacingOccurrences(of: plusSign, with: "+")
    }
    var asciiNormalized = ""
    for scalar in normalized.unicodeScalars {
        if scalar.properties.numericType == .decimal,
           let numericValue = scalar.properties.numericValue,
           let asciiDigit = UnicodeScalar(Int(numericValue) + 48) {
            asciiNormalized.unicodeScalars.append(asciiDigit)
        } else {
            asciiNormalized.unicodeScalars.append(scalar)
        }
    }
    let parsed = Double(asciiNormalized)
    guard let parsed, parsed.isFinite else {
        return nil
    }
    return parsed
}

func clampedEditableNumber(
    _ text: String,
    range: ClosedRange<Double>,
    locale: Locale = .autoupdatingCurrent
) -> Double? {
    guard let parsed = parseEditableNumber(text, locale: locale) else {
        return nil
    }
    return min(max(parsed, range.lowerBound), range.upperBound)
}

// Quantizes slider output in the binding instead of passing `step:` to Slider. Stepped macOS
// sliders render a tick mark per step, which draws a dense line of dots under the track.
func quantized(_ value: Double, step: Double) -> Double {
    guard step > 0 else {
        return value
    }
    let scale = 1 / step
    return (value * scale).rounded() / scale
}

func playbackFramesToMilliseconds(
    _ frames: Double,
    bufferSampleRate: Double,
    fallbackSampleRate: Double
) -> Double {
    let sampleRate = bufferSampleRate > 0 ? bufferSampleRate : fallbackSampleRate
    guard sampleRate > 0 else {
        return 0
    }
    return frames / sampleRate * 1_000
}

func localizedInteger(_ value: Int) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

func localizedInteger(_ value: UInt32) -> String {
    UInt64(value).formatted(.number.locale(.autoupdatingCurrent))
}

func localizedInteger(_ value: UInt64) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

func localizedDecibels(_ value: Double, fractionDigits: Int = 1) -> String {
    let number = localizedDecimal(
        value,
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
        signed: true
    )
    return localized("\(number) dB")
}

func localizedFrequency(_ value: Double) -> String {
    if value >= 1_000 {
        let number = localizedDecimal(value / 1_000, minimumFractionDigits: 1, maximumFractionDigits: 1)
        return localized("\(number) kHz")
    }
    let number = localizedDecimal(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
    return localized("\(number) Hz")
}

func localizedFrameCount(_ value: Int) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

func localizedFrameCount(_ value: UInt32) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

func localizedLatency(milliseconds: Double) -> String {
    let number = localizedDecimal(milliseconds, minimumFractionDigits: 2, maximumFractionDigits: 2)
    return localized("\(number) ms")
}

extension Double {
    var dbLabel: String {
        localizedDecibels(self)
    }

    var frequencyLabel: String {
        localizedFrequency(self)
    }

    var axisFrequencyLabel: String {
        if self >= 1_000 {
            return localized("\(localizedDecimal(self / 1_000, minimumFractionDigits: 0, maximumFractionDigits: 0)) kHz")
        }
        return localized("\(localizedDecimal(self, minimumFractionDigits: 0, maximumFractionDigits: 0)) Hz")
    }

    var dbAxisLabel: String {
        localizedDecimal(self, minimumFractionDigits: 0, maximumFractionDigits: 0, signed: self > 0)
    }

    subscript(quantizedTo step: Double) -> Double {
        get {
            self
        }
        set {
            self = quantized(newValue, step: step)
        }
    }
}

extension FilterKind {
    var title: String {
        switch self {
        case .peak:
            localized("Peak")
        case .lowShelf:
            localized("Low Shelf")
        case .highShelf:
            localized("High Shelf")
        case .highPass:
            localized("High Pass")
        case .lowPass:
            localized("Low Pass")
        }
    }

    var shortTitle: String {
        switch self {
        case .peak:
            localized("Peak")
        case .lowShelf:
            localized("Low")
        case .highShelf:
            localized("High")
        case .highPass:
            "HP"
        case .lowPass:
            "LP"
        }
    }
}
