//
//  JSONValue.swift
//  AgentKit
//
//  An ordered, round-trip-faithful JSON tree.
//
//  Config files owned by other tools (pi's settings.json, models.json, every
//  MCP layer) contain keys AgentKit has never heard of. Re-encoding them
//  through Codable would silently reorder keys and drop the unknown ones, so
//  every config mutation goes through this tree instead: key order is the
//  insertion order of the original file, number literals keep their original
//  spelling, and nothing is discarded.
//

import Foundation

// MARK: - Number

/// A JSON number that remembers how it was spelled.
///
/// `16384` must not come back as `16384.0`, and `1e6` must not come back as
/// `1000000`, because those are real diffs in a file a human reviews.
public struct JSONNumber: Equatable, CustomStringConvertible {
	public let raw: String

	public init(raw: String) {
		self.raw = raw
	}

	public init(_ int: Int) {
		self.raw = String(int)
	}

	public init(_ double: Double) {
		if double.rounded() == double, double.magnitude < 1e15 {
			self.raw = String(Int(double))
		} else {
			self.raw = String(double)
		}
	}

	/// True when the literal has no fraction and no exponent.
	public var isInteger: Bool {
		!raw.contains(".") && !raw.contains("e") && !raw.contains("E")
	}

	public var doubleValue: Double? {
		Double(raw)
	}

	public var intValue: Int? {
		guard isInteger else { return nil }
		return Int(raw)
	}

	public var description: String { raw }
}

// MARK: - Ordered object

/// A JSON object that preserves key order.
public struct JSONObject: Equatable {
	private var order: [String] = []
	private var storage: [String: JSONValue] = [:]

	public init() {}

	public init(_ pairs: [(String, JSONValue)]) {
		for (key, value) in pairs {
			self[key] = value
		}
	}

	public var keys: [String] { order }
	public var count: Int { order.count }
	public var isEmpty: Bool { order.isEmpty }

	public func contains(_ key: String) -> Bool {
		storage[key] != nil
	}

	public subscript(key: String) -> JSONValue? {
		get { storage[key] }
		set {
			if let newValue {
				if storage[key] == nil { order.append(key) }
				storage[key] = newValue
			} else {
				_ = removeValue(forKey: key)
			}
		}
	}

	public mutating func removeValue(forKey key: String) -> JSONValue? {
		guard let removed = storage.removeValue(forKey: key) else { return nil }
		if let index = order.firstIndex(of: key) { order.remove(at: index) }
		return removed
	}

	public func key(at index: Int) -> String { order[index] }

	public var pairs: [(String, JSONValue)] {
		order.map { ($0, storage[$0]!) }
	}

	public var dictionary: [String: JSONValue] {
		storage
	}
}

// MARK: - Value

public enum JSONValue: Equatable {
	case null
	case bool(Bool)
	case number(JSONNumber)
	case string(String)
	case array([JSONValue])
	case object(JSONObject)
}

extension JSONValue {
	public var isNull: Bool {
		if case .null = self { return true }
		return false
	}

	public var objectValue: JSONObject? {
		if case .object(let value) = self { return value }
		return nil
	}

	public var arrayValue: [JSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}

	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	public var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	public var numberValue: JSONNumber? {
		if case .number(let value) = self { return value }
		return nil
	}

	public var intValue: Int? { numberValue?.intValue }
	public var doubleValue: Double? { numberValue?.doubleValue }

	/// Convenience for strings and string arrays, used by array-valued settings.
	public var stringsValue: [String]? {
		if case .array(let items) = self {
			let strings = items.compactMap { $0.stringValue }
			return strings.count == items.count ? strings : nil
		}
		return nil
	}

	public mutating func setValue(_ value: JSONValue, at path: [String]) {
		guard let head = path.first else { return }
		if path.count == 1 {
			switch self {
			case .object(var object):
				object[head] = value
				self = .object(object)
			case .array(var items):
				guard let index = Int(head), items.indices.contains(index) else { return }
				items[index] = value
				self = .array(items)
			default:
				var object = JSONObject()
				object[head] = value
				self = .object(object)
			}
			return
		}
		let rest = Array(path.dropFirst())
		switch self {
		case .object(var object):
			var child = object[head] ?? .object(JSONObject())
			child.setValue(value, at: rest)
			object[head] = child
			self = .object(object)
		case .array(var items):
			guard let index = Int(head), items.indices.contains(index) else { return }
			items[index].setValue(value, at: rest)
			self = .array(items)
		default:
			var child = JSONValue.object(JSONObject())
			child.setValue(value, at: rest)
			var object = JSONObject()
			object[head] = child
			self = .object(object)
		}
	}

	public func value(at path: [String]) -> JSONValue? {
		guard let head = path.first else { return self }
		let rest = Array(path.dropFirst())
		switch self {
		case .object(let object):
			guard let child = object[head] else { return nil }
			return child.value(at: rest)
		case .array(let items):
			guard let index = Int(head), items.indices.contains(index) else { return nil }
			return items[index].value(at: rest)
		default:
			return nil
		}
	}

	public mutating func removeValue(at path: [String]) {
		guard let head = path.first else { return }
		let rest = Array(path.dropFirst())
		switch self {
		case .object(var object):
			if rest.isEmpty {
				_ = object.removeValue(forKey: head)
			} else if var child = object[head] {
				child.removeValue(at: rest)
				object[head] = child
			}
			self = .object(object)
		case .array(var items):
			guard let index = Int(head), items.indices.contains(index) else { return }
			if rest.isEmpty {
				items.remove(at: index)
			} else {
				items[index].removeValue(at: rest)
			}
			self = .array(items)
		default:
			break
		}
	}
}

extension JSONValue: CustomStringConvertible {
	public var description: String {
		JSONWriter.compact.serialize(self)
	}
}

// MARK: - Parser

public struct JSONParseError: Error, CustomStringConvertible {
	public let message: String
	public let line: Int
	public let column: Int

	public var description: String {
		"\(message) (第 \(line) 行第 \(column) 列)"
	}
}

/// The original text a tree was parsed from, plus the byte range of every
/// value in it.
///
/// This is what lets AgentKit change one setting without reformatting the rest
/// of the file: an edit is applied as a byte-range splice, so untouched lines —
/// including objects the user wrote inline — come back out exactly as they went
/// in.
public struct JSONSource {
	public let text: String
	public let byteRanges: [String: Range<Int>]
	private let bytes: [UInt8]

	public init(text: String, byteRanges: [String: Range<Int>]) {
		self.text = text
		self.byteRanges = byteRanges
		self.bytes = Array(text.utf8)
	}

	/// A path is joined with a unit separator because a JSON key may contain a dot.
	public static func pathKey(_ path: [String]) -> String {
		path.joined(separator: "\u{1F}")
	}

	public func range(at path: [String]) -> Range<Int>? {
		byteRanges[JSONSource.pathKey(path)]
	}

	public func valueText(at path: [String]) -> String? {
		guard let range = range(at: path) else { return nil }
		return String(bytes: bytes[range], encoding: .utf8)
	}
}

public struct JSONParseResult {
	public let value: JSONValue
	public let source: JSONSource
}

public enum JSONParser {
	public static func parse(_ text: String) throws -> JSONValue {
		try parseWithSource(text).value
	}

	public static func parseWithSource(_ text: String) throws -> JSONParseResult {
		var scanner = Scanner(bytes: Array(text.utf8))
		scanner.skipWhitespace()
		let value = try scanner.parseValue(path: [])
		scanner.skipWhitespace()
		guard scanner.isAtEnd else {
			throw scanner.error("JSON 结尾存在多余内容")
		}
		return JSONParseResult(
			value: value,
			source: JSONSource(text: text, byteRanges: scanner.spans)
		)
	}

	private struct Scanner {
		let bytes: [UInt8]
		var index: Int = 0
		/// Byte range of each parsed value, keyed by its path.
		var spans: [String: Range<Int>] = [:]

		init(bytes: [UInt8]) {
			self.bytes = bytes
		}

		var isAtEnd: Bool { index >= bytes.count }

		func error(_ message: String) -> JSONParseError {
			var line = 1
			var column = 1
			for byte in bytes[..<min(index, bytes.count)] {
				if byte == 0x0A {
					line += 1
					column = 1
				} else {
					column += 1
				}
			}
			return JSONParseError(message: message, line: line, column: column)
		}

		mutating func skipWhitespace() {
			while index < bytes.count {
				switch bytes[index] {
				case 0x20, 0x09, 0x0A, 0x0D:
					index += 1
				default:
					return
				}
			}
		}

		/// Parses a value and records the byte range it occupied.
		mutating func parseValue(path: [String]) throws -> JSONValue {
			let start = index
			let value = try parseValueBody(path: path)
			spans[JSONSource.pathKey(path)] = start..<index
			return value
		}

		mutating func parseValueBody(path: [String]) throws -> JSONValue {
			guard index < bytes.count else { throw error("意外的文件结尾") }
			switch bytes[index] {
			case UInt8(ascii: "{"):
				return try parseObject(path: path)
			case UInt8(ascii: "["):
				return try parseArray(path: path)
			case UInt8(ascii: "\""):
				return .string(try parseString())
			case UInt8(ascii: "t"):
				try expect("true")
				return .bool(true)
			case UInt8(ascii: "f"):
				try expect("false")
				return .bool(false)
			case UInt8(ascii: "n"):
				try expect("null")
				return .null
			default:
				return .number(try parseNumber())
			}
		}

		mutating func expect(_ literal: String) throws {
			let expected = Array(literal.utf8)
			guard index + expected.count <= bytes.count else { throw error("期望 \(literal)") }
			for (offset, byte) in expected.enumerated() where bytes[index + offset] != byte {
				throw error("期望 \(literal)")
			}
			index += expected.count
		}

		mutating func parseObject(path: [String]) throws -> JSONValue {
			index += 1 // consume '{'
			var object = JSONObject()
			skipWhitespace()
			if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
				index += 1
				return .object(object)
			}
			while true {
				skipWhitespace()
				guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
					throw error("对象的键必须是字符串")
				}
				let key = try parseString()
				skipWhitespace()
				guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
					throw error("键 \"\(key)\" 后面缺少冒号")
				}
				index += 1
				skipWhitespace()
				object[key] = try parseValue(path: path + [key])
				skipWhitespace()
				guard index < bytes.count else { throw error("对象没有闭合") }
				if bytes[index] == UInt8(ascii: ",") {
					index += 1
					continue
				}
				if bytes[index] == UInt8(ascii: "}") {
					index += 1
					return .object(object)
				}
				throw error("对象里期望 , 或 }")
			}
		}

		mutating func parseArray(path: [String]) throws -> JSONValue {
			index += 1 // consume '['
			var items: [JSONValue] = []
			skipWhitespace()
			if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
				index += 1
				return .array(items)
			}
			while true {
				skipWhitespace()
				items.append(try parseValue(path: path + [String(items.count)]))
				skipWhitespace()
				guard index < bytes.count else { throw error("数组没有闭合") }
				if bytes[index] == UInt8(ascii: ",") {
					index += 1
					continue
				}
				if bytes[index] == UInt8(ascii: "]") {
					index += 1
					return .array(items)
				}
				throw error("数组里期望 , 或 ]")
			}
		}

		mutating func parseString() throws -> String {
			index += 1 // consume opening quote
			var out: [UInt8] = []
			while index < bytes.count {
				let byte = bytes[index]
				if byte == UInt8(ascii: "\"") {
					index += 1
					guard let string = String(bytes: out, encoding: .utf8) else {
						throw error("字符串不是合法的 UTF-8")
					}
					return string
				}
				if byte == UInt8(ascii: "\\") {
					index += 1
					guard index < bytes.count else { throw error("转义序列不完整") }
					let escape = bytes[index]
					index += 1
					switch escape {
					case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
					case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
					case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
					case UInt8(ascii: "b"): out.append(0x08)
					case UInt8(ascii: "f"): out.append(0x0C)
					case UInt8(ascii: "n"): out.append(0x0A)
					case UInt8(ascii: "r"): out.append(0x0D)
					case UInt8(ascii: "t"): out.append(0x09)
					case UInt8(ascii: "u"):
						let scalar = try parseUnicodeEscape()
						out.append(contentsOf: Array(String(scalar).utf8))
					default:
						throw error("无法识别的转义 \\\(Character(UnicodeScalar(escape)))")
					}
					continue
				}
				if byte < 0x20 {
					throw error("字符串里出现了未转义的控制字符")
				}
				out.append(byte)
				index += 1
			}
			throw error("字符串没有闭合")
		}

		/// Reads the four hex digits after `\u` and, for a high surrogate,
		/// consumes the following `\uXXXX` low surrogate as well.
		mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
			let first = try readHex4()
			if first >= 0xD800, first <= 0xDBFF {
				guard index + 1 < bytes.count,
					bytes[index] == UInt8(ascii: "\\"),
					bytes[index + 1] == UInt8(ascii: "u")
				else { throw error("高位代理项后面缺少低位代理项") }
				index += 2
				let second = try readHex4()
				guard second >= 0xDC00, second <= 0xDFFF else {
					throw error("低位代理项不合法")
				}
				let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
				guard let scalar = Unicode.Scalar(combined) else {
					throw error("代理对无法组成合法字符")
				}
				return scalar
			}
			guard let scalar = Unicode.Scalar(first) else {
				throw error("不合法的 \\u 转义")
			}
			return scalar
		}

		mutating func readHex4() throws -> UInt32 {
			guard index + 4 <= bytes.count else { throw error("\\u 转义不完整") }
			var value: UInt32 = 0
			for _ in 0..<4 {
				guard let digit = hexDigit(bytes[index]) else {
					throw error("\\u 转义里出现了非十六进制字符")
				}
				value = value << 4 | UInt32(digit)
				index += 1
			}
			return value
		}

		func hexDigit(_ byte: UInt8) -> UInt8? {
			switch byte {
			case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
			case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
			case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
			default: return nil
			}
		}

		mutating func parseNumber() throws -> JSONNumber {
			let start = index
			if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
			while index < bytes.count, isDigit(bytes[index]) { index += 1 }
			if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
				index += 1
				while index < bytes.count, isDigit(bytes[index]) { index += 1 }
			}
			if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
				index += 1
				if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
					index += 1
				}
				while index < bytes.count, isDigit(bytes[index]) { index += 1 }
			}
			guard index > start, let raw = String(bytes: bytes[start..<index], encoding: .utf8) else {
				throw error("不是合法的数字")
			}
			guard Double(raw) != nil else { throw error("数字 \(raw) 超出范围") }
			return JSONNumber(raw: raw)
		}

		func isDigit(_ byte: UInt8) -> Bool {
			byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
		}
	}
}

// MARK: - Writer

public struct JSONWriter {
	public var indent: String
	public var trailingNewline: Bool

	public init(indent: String = "  ", trailingNewline: Bool = false) {
		self.indent = indent
		self.trailingNewline = trailingNewline
	}

	public static let compact = JSONWriter(indent: "", trailingNewline: false)
	public static let pretty = JSONWriter(indent: "  ", trailingNewline: false)

	public func serialize(_ value: JSONValue) -> String {
		var out = ""
		write(value, depth: 0, into: &out)
		if trailingNewline { out.append("\n") }
		return out
	}

	private func write(_ value: JSONValue, depth: Int, into out: inout String) {
		switch value {
		case .null:
			out += "null"
		case .bool(let flag):
			out += flag ? "true" : "false"
		case .number(let number):
			out += number.raw
		case .string(let string):
			out += JSONWriter.quote(string)
		case .array(let items):
			if items.isEmpty {
				out += "[]"
				return
			}
			// `pad` already starts with a newline, so the separator is just a comma.
			let separator = ","
			let pad = indent.isEmpty ? "" : "\n" + String(repeating: indent, count: depth + 1)
			out += "["
			out += pad
			for (offset, item) in items.enumerated() {
				if offset > 0 { out += separator + pad }
				write(item, depth: depth + 1, into: &out)
			}
			out += indent.isEmpty ? "]" : "\n" + String(repeating: indent, count: depth) + "]"
		case .object(let object):
			if object.isEmpty {
				out += "{}"
				return
			}
			// `pad` already starts with a newline, so the separator is just a comma.
			let separator = ","
			let pad = indent.isEmpty ? "" : "\n" + String(repeating: indent, count: depth + 1)
			out += "{"
			out += pad
			for (offset, pair) in object.pairs.enumerated() {
				if offset > 0 { out += separator + pad }
				out += JSONWriter.quote(pair.0)
				out += indent.isEmpty ? ":" : ": "
				write(pair.1, depth: depth + 1, into: &out)
			}
			out += indent.isEmpty ? "}" : "\n" + String(repeating: indent, count: depth) + "}"
		}
	}

	/// Matches `JSON.stringify` escaping: only the mandatory escapes, and
	/// non-ASCII passes through as UTF-8 so Chinese text stays readable.
	public static func quote(_ string: String) -> String {
		var out = "\""
		for scalar in string.unicodeScalars {
			switch scalar {
			case "\"": out += "\\\""
			case "\\": out += "\\\\"
			case "\n": out += "\\n"
			case "\r": out += "\\r"
			case "\t": out += "\\t"
			case Unicode.Scalar(0x08): out += "\\b"
			case Unicode.Scalar(0x0C): out += "\\f"
			default:
				if scalar.value < 0x20 {
					out += String(format: "\\u%04x", scalar.value)
				} else {
					out.unicodeScalars.append(scalar)
				}
			}
		}
		return out + "\""
	}
}

// MARK: - Formatting style

/// The parts of a file's formatting AgentKit reproduces on write.
///
/// Re-serializing `settings.json` must not reformat the whole file just
/// because one boolean changed, so the indent unit and the presence of a
/// trailing newline are detected from the original bytes and reused.
public struct JSONStyle: Equatable {
	public var indent: String
	public var trailingNewline: Bool

	public init(indent: String, trailingNewline: Bool) {
		self.indent = indent
		self.trailingNewline = trailingNewline
	}

	public static let standard = JSONStyle(indent: "  ", trailingNewline: false)

	/// Detects the indent unit of the first indented line and whether the file
	/// ends with a newline. Falls back to two spaces when the file is flat.
	public static func detect(in text: String) -> JSONStyle {
		var indent = "  "
		for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
			let leading = line.prefix { $0 == " " || $0 == "\t" }
			if !leading.isEmpty {
				indent = String(leading)
				break
			}
			if !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
		}
		return JSONStyle(indent: indent, trailingNewline: text.hasSuffix("\n"))
	}

	public var writer: JSONWriter {
		JSONWriter(indent: indent, trailingNewline: trailingNewline)
	}
}
