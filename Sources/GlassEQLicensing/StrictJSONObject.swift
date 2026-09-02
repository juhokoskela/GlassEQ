import Foundation

enum StrictJSONValue: Equatable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
}

enum StrictJSONObjectError: Error, Equatable {
    case malformed
    case duplicateKey
    case unsupportedValue
}

struct StrictJSONObjectParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func parse() throws -> [String: StrictJSONValue] {
        skipWhitespace()
        guard consume(0x7B) else {
            throw StrictJSONObjectError.malformed
        }

        skipWhitespace()
        if consume(0x7D) {
            skipWhitespace()
            guard index == bytes.count else {
                throw StrictJSONObjectError.malformed
            }
            return [:]
        }

        var result: [String: StrictJSONValue] = [:]
        while true {
            skipWhitespace()
            let key = try parseString()
            guard result[key] == nil else {
                throw StrictJSONObjectError.duplicateKey
            }

            skipWhitespace()
            guard consume(0x3A) else {
                throw StrictJSONObjectError.malformed
            }
            skipWhitespace()
            result[key] = try parseValue()
            skipWhitespace()

            if consume(0x7D) {
                break
            }
            guard consume(0x2C) else {
                throw StrictJSONObjectError.malformed
            }
        }

        skipWhitespace()
        guard index == bytes.count else {
            throw StrictJSONObjectError.malformed
        }
        return result
    }

    private mutating func parseValue() throws -> StrictJSONValue {
        guard let byte = currentByte else {
            throw StrictJSONObjectError.malformed
        }

        switch byte {
        case 0x22:
            return .string(try parseString())
        case 0x2D, 0x30 ... 0x39:
            return .integer(try parseInteger())
        case 0x74:
            try consumeKeyword("true")
            return .boolean(true)
        case 0x66:
            try consumeKeyword("false")
            return .boolean(false)
        case 0x5B, 0x7B, 0x6E:
            throw StrictJSONObjectError.unsupportedValue
        default:
            throw StrictJSONObjectError.malformed
        }
    }

    private mutating func parseString() throws -> String {
        guard consume(0x22) else {
            throw StrictJSONObjectError.malformed
        }

        var result = ""
        var chunkStart = index
        while let byte = currentByte {
            switch byte {
            case 0x22:
                try appendUTF8(bytes[chunkStart ..< index], to: &result)
                index += 1
                return result
            case 0x5C:
                try appendUTF8(bytes[chunkStart ..< index], to: &result)
                index += 1
                try appendEscape(to: &result)
                chunkStart = index
            case 0x00 ... 0x1F:
                throw StrictJSONObjectError.malformed
            default:
                index += 1
            }
        }
        throw StrictJSONObjectError.malformed
    }

    private mutating func appendEscape(to result: inout String) throws {
        guard let byte = currentByte else {
            throw StrictJSONObjectError.malformed
        }
        index += 1

        switch byte {
        case 0x22:
            result.append("\"")
        case 0x5C:
            result.append("\\")
        case 0x2F:
            result.append("/")
        case 0x62:
            result.append("\u{0008}")
        case 0x66:
            result.append("\u{000C}")
        case 0x6E:
            result.append("\n")
        case 0x72:
            result.append("\r")
        case 0x74:
            result.append("\t")
        case 0x75:
            let first = try parseHexQuad()
            if (0xD800 ... 0xDBFF).contains(first) {
                guard consume(0x5C), consume(0x75) else {
                    throw StrictJSONObjectError.malformed
                }
                let second = try parseHexQuad()
                guard (0xDC00 ... 0xDFFF).contains(second) else {
                    throw StrictJSONObjectError.malformed
                }
                let scalarValue = 0x10000
                    + (UInt32(first - 0xD800) << 10)
                    + UInt32(second - 0xDC00)
                guard let scalar = Unicode.Scalar(scalarValue) else {
                    throw StrictJSONObjectError.malformed
                }
                result.unicodeScalars.append(scalar)
            } else {
                guard !(0xDC00 ... 0xDFFF).contains(first),
                      let scalar = Unicode.Scalar(first) else {
                    throw StrictJSONObjectError.malformed
                }
                result.unicodeScalars.append(scalar)
            }
        default:
            throw StrictJSONObjectError.malformed
        }
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw StrictJSONObjectError.malformed
        }

        var result: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let nibble = hexValue(bytes[index]) else {
                throw StrictJSONObjectError.malformed
            }
            result = result * 16 + UInt32(nibble)
            index += 1
        }
        return result
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39:
            byte - 0x30
        case 0x41 ... 0x46:
            byte - 0x41 + 10
        case 0x61 ... 0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = index
        _ = consume(0x2D)
        guard let firstDigit = currentByte else {
            throw StrictJSONObjectError.malformed
        }

        if firstDigit == 0x30 {
            index += 1
            if let next = currentByte, (0x30 ... 0x39).contains(next) {
                throw StrictJSONObjectError.malformed
            }
        } else {
            guard (0x31 ... 0x39).contains(firstDigit) else {
                throw StrictJSONObjectError.malformed
            }
            while let byte = currentByte, (0x30 ... 0x39).contains(byte) {
                index += 1
            }
        }

        if let next = currentByte, next == 0x2E || next == 0x45 || next == 0x65 {
            throw StrictJSONObjectError.unsupportedValue
        }

        guard let text = String(bytes: bytes[start ..< index], encoding: .utf8),
              let value = Int64(text) else {
            throw StrictJSONObjectError.malformed
        }
        return value
    }

    private mutating func consumeKeyword(_ keyword: String) throws {
        let expected = Array(keyword.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected else {
            throw StrictJSONObjectError.malformed
        }
        index += expected.count
    }

    private func appendUTF8(_ bytes: ArraySlice<UInt8>, to result: inout String) throws {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw StrictJSONObjectError.malformed
        }
        result.append(text)
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else {
            return false
        }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }
}
