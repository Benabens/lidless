import Foundation

// Lidless edits configuration files it does not own. Foundation's JSON support would reorder the
// keys and re-format the numbers of the whole file, so this is a small JSON model that keeps key
// order, number spelling and indentation. For a file laid out the way `JSON.stringify` does it,
// which is how the agents write theirs, re-serialising an untouched document gives the original
// text back. A hand-formatted file keeps its content but is laid out that standard way.

public enum JSONValue: Equatable, Sendable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    /// The number exactly as written in the file (`0.10`, `1E+3`, a 20-digit integer…).
    case number(String)
    case bool(Bool)
    case null
}

/// A JSON object that remembers the order of its keys.
public struct JSONObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
    }

    public private(set) var members: [Member]

    public init(_ members: KeyValuePairs<String, JSONValue> = [:]) {
        self.members = members.map { Member(key: $0.key, value: $0.value) }
    }

    public var isEmpty: Bool { members.isEmpty }

    /// Setting an existing key replaces its value in place; a new key goes last; `nil` removes.
    public subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            let index = members.firstIndex { $0.key == key }
            switch (index, newValue) {
            case let (index?, value?): members[index].value = value
            case let (index?, nil): members.remove(at: index)
            case let (nil, value?): members.append(Member(key: key, value: value))
            case (nil, nil): break
            }
        }
    }

    fileprivate mutating func append(key: String, value: JSONValue) {
        members.append(Member(key: key, value: value))
    }
}

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    /// Byte offset in the UTF-8 text.
    public var offset: Int

    public var description: String { "\(message) at byte \(offset)" }
}

/// A JSON file: its value plus the formatting habits needed to write it back unchanged.
public struct JSONDocument: Equatable, Sendable {
    public var root: JSONValue
    /// One level of indentation, or `nil` for a single-line document.
    public var indent: String?
    public var endsWithNewline: Bool

    public init(root: JSONValue, indent: String? = "  ", endsWithNewline: Bool = true) {
        self.root = root
        self.indent = indent
        self.endsWithNewline = endsWithNewline
    }

    /// Parses strict JSON (RFC 8259): no comments, no trailing commas.
    public init(text: String) throws {
        var parser = JSONParser(bytes: Array(text.utf8))
        root = try parser.parseDocument()
        indent = Self.detectIndent(in: text)
        endsWithNewline = text.hasSuffix("\n")
    }

    public var text: String {
        var output = ""
        JSONWriter(indent: indent).write(root, depth: 0, into: &output)
        if endsWithNewline { output += "\n" }
        return output
    }

    /// The leading whitespace of the first indented line.
    private static func detectIndent(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return nil }
        for line in lines {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if !leading.isEmpty, leading.count < line.count { return String(leading) }
        }
        return "  "
    }
}

// MARK: - Writing

private struct JSONWriter {
    let indent: String?

    func write(_ value: JSONValue, depth: Int, into output: inout String) {
        switch value {
        case .null: output += "null"
        case let .bool(flag): output += flag ? "true" : "false"
        case let .number(lexeme): output += lexeme
        case let .string(string): writeString(string, into: &output)
        case let .array(elements):
            writeContainer("[", "]", count: elements.count, depth: depth, into: &output) { index, output in
                write(elements[index], depth: depth + 1, into: &output)
            }
        case let .object(object):
            writeContainer("{", "}", count: object.members.count, depth: depth, into: &output) { index, output in
                writeString(object.members[index].key, into: &output)
                output += indent == nil ? ":" : ": "
                write(object.members[index].value, depth: depth + 1, into: &output)
            }
        }
    }

    private func writeContainer(
        _ open: String, _ close: String, count: Int, depth: Int, into output: inout String,
        element: (Int, inout String) -> Void
    ) {
        output += open
        guard count > 0 else {
            output += close
            return
        }
        for index in 0..<count {
            if index > 0 { output += "," }
            newline(depth: depth + 1, into: &output)
            element(index, &output)
        }
        newline(depth: depth, into: &output)
        output += close
    }

    private func newline(depth: Int, into output: inout String) {
        guard let indent else { return }
        output += "\n"
        for _ in 0..<depth { output += indent }
    }

    /// Same escaping as `JSON.stringify`, which wrote most of the files Lidless edits.
    private func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Parsing

private struct JSONParser {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard position == bytes.count else { throw error("Unexpected content after the JSON value") }
        return value
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message, offset: position)
    }

    private var current: UInt8? {
        position < bytes.count ? bytes[position] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            position += 1
        }
    }

    private mutating func expect(_ byte: UInt8, _ what: String) throws {
        guard current == byte else { throw error("Expected \(what)") }
        position += 1
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw error("JSON is nested too deeply") }
        switch current {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        case let byte? where byte == UInt8(ascii: "-") || (0x30...0x39).contains(byte):
            return try parseNumber()
        default:
            throw error("Expected a JSON value")
        }
    }

    private mutating func parseLiteral(_ literal: String, _ value: JSONValue) throws -> JSONValue {
        let expected = Array(literal.utf8)
        guard position + expected.count <= bytes.count,
              Array(bytes[position..<position + expected.count]) == expected
        else { throw error("Expected \(literal)") }
        position += expected.count
        return value
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        position += 1
        var object = JSONObject()
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            position += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw error("Expected a string key") }
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"), "':'")
            skipWhitespace()
            object.append(key: key, value: try parseValue(depth: depth + 1))
            skipWhitespace()
            if current == UInt8(ascii: ",") {
                position += 1
                continue
            }
            try expect(UInt8(ascii: "}"), "',' or '}'")
            return .object(object)
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        position += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            position += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if current == UInt8(ascii: ",") {
                position += 1
                continue
            }
            try expect(UInt8(ascii: "]"), "',' or ']'")
            return .array(elements)
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = position
        func isDigit(_ byte: UInt8?) -> Bool { byte.map { (0x30...0x39).contains($0) } ?? false }

        if current == UInt8(ascii: "-") { position += 1 }
        guard isDigit(current) else { throw error("Malformed number") }
        if current == UInt8(ascii: "0") {
            position += 1
            if isDigit(current) { throw error("Numbers cannot have leading zeros") }
        } else {
            while isDigit(current) { position += 1 }
        }
        if current == UInt8(ascii: ".") {
            position += 1
            guard isDigit(current) else { throw error("Malformed number") }
            while isDigit(current) { position += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            position += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
            guard isDigit(current) else { throw error("Malformed number") }
            while isDigit(current) { position += 1 }
        }
        return .number(String(decoding: bytes[start..<position], as: UTF8.self))
    }

    private mutating func parseString() throws -> String {
        position += 1
        var scalars = String.UnicodeScalarView()
        var literalStart = position

        func flushLiteral(upTo end: Int, into scalars: inout String.UnicodeScalarView) throws {
            guard end > literalStart else { return }
            guard let chunk = String(validatingUTF8: bytes[literalStart..<end]) else {
                throw JSONParseError(message: "Invalid UTF-8 in string", offset: literalStart)
            }
            scalars.append(contentsOf: chunk.unicodeScalars)
        }

        while true {
            guard let byte = current else { throw error("Unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                try flushLiteral(upTo: position, into: &scalars)
                position += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                try flushLiteral(upTo: position, into: &scalars)
                position += 1
                scalars.append(try parseEscape())
                literalStart = position
            case 0..<0x20:
                throw error("Unescaped control character in string")
            default:
                position += 1
            }
        }
    }

    private mutating func parseEscape() throws -> Unicode.Scalar {
        guard let byte = current else { throw error("Unterminated string") }
        position += 1
        switch byte {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{08}"
        case UInt8(ascii: "f"): return "\u{0C}"
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"):
            let unit = try parseHexUnit()
            if (0xD800...0xDBFF).contains(unit) {
                // High surrogate: the low half must follow as another \u escape.
                guard current == UInt8(ascii: "\\"), position + 1 < bytes.count,
                      bytes[position + 1] == UInt8(ascii: "u")
                else { throw error("Unpaired surrogate in string") }
                position += 2
                let low = try parseHexUnit()
                guard (0xDC00...0xDFFF).contains(low) else { throw error("Unpaired surrogate in string") }
                let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else { throw error("Invalid escape") }
                return scalar
            }
            guard let scalar = Unicode.Scalar(unit) else { throw error("Unpaired surrogate in string") }
            return scalar
        default:
            throw error("Invalid escape")
        }
    }

    private mutating func parseHexUnit() throws -> UInt32 {
        guard position + 4 <= bytes.count,
              let unit = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16)
        else { throw error("Invalid \\u escape") }
        position += 4
        return unit
    }
}

private extension String {
    /// `nil` unless `bytes` is well-formed UTF-8.
    init?(validatingUTF8 bytes: ArraySlice<UInt8>) {
        var result = ""
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): result.unicodeScalars.append(scalar)
            case .emptyInput:
                self = result
                return
            case .error: return nil
            }
        }
    }
}
