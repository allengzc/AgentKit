//
//  TOML.swift
//  AgentKit
//
//  A TOML reader that produces the same ordered tree as the JSON reader, plus
//  the byte range of every value.
//
//  Codex keeps its configuration in `~/.codex/config.toml`, so the whole
//  editing path — ordered tree, surgical byte splice, backups, concurrency
//  check — has to work for TOML too. Parsing into `JSONValue`/`JSONSource`
//  means none of that machinery needs to know which format it is looking at;
//  only the writer differs.
//
//  The subset covered is what real config files use: tables, arrays of tables,
//  dotted and quoted keys, inline tables, multi-line arrays, comments, and all
//  the scalar types. It is deliberately not a general-purpose TOML 1.0
//  implementation.
//

import Foundation

public struct TOMLParseResult {
	public let value: JSONValue
	public let source: JSONSource
	/// Byte range of each table's header line through the end of its body,
	/// keyed by `JSONSource.pathKey(path)`. The root table is not included.
	public let tableRanges: [String: Range<Int>]
	/// True when the file contains a comment anywhere. A structural rewrite
	/// drops comments, so the caller can warn before it happens.
	public let hasComments: Bool
	public let style: JSONStyle
}

// MARK: - Parser

public enum TOMLParser {
	public static func parse(_ text: String) throws -> JSONValue {
		try parseWithSource(text).value
	}

	public static func parseWithSource(_ text: String) throws -> TOMLParseResult {
		var scanner = Scanner(bytes: Array(text.utf8))
		scanner.skipBom()
		let root = try scanner.parseDocument()

		var style = JSONStyle.detect(in: text)
		// TOML is line-oriented; the JSON style probe is only used for the
		// newline, and indentation has no meaning here.
		style.indent = "  "

		return TOMLParseResult(
			value: root,
			source: JSONSource(text: text, byteRanges: scanner.spans),
			tableRanges: scanner.tableRanges,
			hasComments: scanner.hasComments,
			style: style
		)
	}

	private struct Scanner {
		let bytes: [UInt8]
		var index = 0
		var spans: [String: Range<Int>] = [:]
		var tableRanges: [String: Range<Int>] = [:]
		var hasComments = false

		var root = JSONValue.object(JSONObject())
		/// The table currently being filled, as a path of components. Array-of-table
		/// elements end with the index.
		var currentPath: [String] = []
		/// Start of the current table's header line, for `tableRanges`.
		var tableStart: Int?

		init(bytes: [UInt8]) {
			self.bytes = bytes
		}

		var isAtEnd: Bool { index >= bytes.count }

		func error(_ message: String) -> JSONParseError {
			var line = 1
			var column = 1
			for byte in bytes[..<min(index, bytes.count)] {
				if byte == 0x0A { line += 1; column = 1 } else { column += 1 }
			}
			return JSONParseError(message: "TOML: \(message)", line: line, column: column)
		}

		mutating func skipBom() {
			if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
				index = 3
			}
		}

		// MARK: Document

		mutating func parseDocument() throws -> JSONValue {
			while true {
				skipBlankAndComments()
				guard !isAtEnd else { break }
				if bytes[index] == UInt8(ascii: "[") {
					try parseTableHeader()
				} else {
					try parseKeyValue()
				}
			}
			closeTable(at: bytes.count)
			return root
		}

		mutating func skipBlankAndComments() {
			while !isAtEnd {
				switch bytes[index] {
				case 0x20, 0x09:
					index += 1
				case 0x0A, 0x0D:
					// A blank line ends the current table's body only visually;
					// `tableRanges` closes on the next header instead.
					index += 1
				case UInt8(ascii: "#"):
					hasComments = true
					skipToEndOfLine()
				default:
					return
				}
			}
		}

		mutating func skipToEndOfLine() {
			while !isAtEnd, bytes[index] != 0x0A { index += 1 }
		}

		mutating func skipInlineWhitespace() {
			while !isAtEnd, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
		}

		/// Records the range of the table that just ended, then starts a new one.
		mutating func closeTable(at end: Int, nextHeaderStart: Int? = nil) {
			guard let start = tableStart else { return }
			var stop = nextHeaderStart ?? end
			// Do not swallow the newline that terminates the table's last line.
			while stop > start, bytes[stop - 1] == 0x0A || bytes[stop - 1] == 0x0D { stop -= 1 }
			if stop > start {
				tableRanges[JSONSource.pathKey(currentPath)] = start..<stop
			}
			tableStart = nil
		}

		mutating func parseTableHeader() throws {
			let headerStart = index
			index += 1 // consume '['
			let isArray = !isAtEnd && bytes[index] == UInt8(ascii: "[")
			if isArray { index += 1 }

			let path = try parseDottedKey()
			guard !path.isEmpty else { throw error(L.t("parse.toml.tableNameEmpty", "表名不能为空", table: .messages)) }
			skipInlineWhitespace()
			guard !isAtEnd, bytes[index] == UInt8(ascii: "]") else {
				throw error(L.t("parse.toml.headerUnclosed", "表头缺少 ]", table: .messages))
			}
			index += 1
			if isArray {
				guard !isAtEnd, bytes[index] == UInt8(ascii: "]") else {
					throw error(L.t("parse.toml.arrayHeaderUnclosed", "数组表头缺少 ]]", table: .messages))
				}
				index += 1
			}
			skipInlineWhitespace()
			if !isAtEnd, bytes[index] == UInt8(ascii: "#") {
				hasComments = true
				skipToEndOfLine()
			}
			guard isAtEnd || bytes[index] == 0x0A || bytes[index] == 0x0D else {
				throw error(L.t("parse.toml.headerTrailing", "表头后面有多余内容", table: .messages))
			}

			closeTable(at: headerStart, nextHeaderStart: headerStart)
			tableStart = headerStart

			if isArray {
				// `[[a.b]]` appends to the array at `a.b`, resolving `a` first so
				// `[[a]]` + `[a.b]` style nesting lands in the right element.
				let parent = try ensureTable(Array(path.dropLast()))
				guard let name = path.last else { throw error(L.t("parse.toml.tableNameEmpty", "表名不能为空", table: .messages)) }
				let container = parent + [name]
				if let existing = root.value(at: container), existing.arrayValue == nil {
					throw error(String(format: L.t("parse.toml.notArrayTable", "%@ 不是数组表", table: .messages), container.joined(separator: ".")))
				}
				var list = root.value(at: container)?.arrayValue ?? []
				list.append(.object(JSONObject()))
				root.setValue(.array(list), at: container)
				currentPath = container + [String(list.count - 1)]
			} else {
				currentPath = try ensureTable(path)
			}
		}

		mutating func parseKeyValue() throws {
			let key = try parseDottedKey()
			guard !key.isEmpty else { throw error(L.t("parse.toml.keyMissingName", "缺少键名", table: .messages)) }
			skipInlineWhitespace()
			guard !isAtEnd, bytes[index] == UInt8(ascii: "=") else {
				throw error(String(format: L.t("parse.toml.keyMissingEquals", "键 %@ 后面缺少 =", table: .messages), key.joined(separator: ".")))
			}
			index += 1
			skipInlineWhitespace()
			guard !isAtEnd else { throw error(String(format: L.t("parse.toml.keyMissingValue", "键 %@ 缺少值", table: .messages), key.joined(separator: "."))) }

			let valueStart = index
			let value = try parseValue(path: currentPath + key)
			spans[JSONSource.pathKey(currentPath + key)] = valueStart..<index

			let full = currentPath + key
			if root.value(at: full) != nil {
				throw error(String(format: L.t("parse.toml.keyDuplicate", "键 %@ 重复定义", table: .messages), full.joined(separator: ".")))
			}
			root.setValue(value, at: full)

			skipInlineWhitespace()
			if !isAtEnd, bytes[index] == UInt8(ascii: "#") {
				hasComments = true
				skipToEndOfLine()
			}
			guard isAtEnd || bytes[index] == 0x0A || bytes[index] == 0x0D else {
				throw error(L.t("parse.toml.valueTrailing", "值后面有多余内容", table: .messages))
			}
		}

		// MARK: Keys

		/// Parses `a.b`, `"a b".c` and `a . b` alike.
		mutating func parseDottedKey() throws -> [String] {
			var path: [String] = []
			while true {
				skipInlineWhitespace()
				guard !isAtEnd else { throw error(L.t("parse.toml.keyNameIncomplete", "键名不完整", table: .messages)) }
				switch bytes[index] {
				case UInt8(ascii: "\""):
					path.append(try parseBasicString(multiline: false))
				case UInt8(ascii: "'"):
					path.append(try parseLiteralString(multiline: false))
				default:
					let start = index
					while !isAtEnd, isBareKeyByte(bytes[index]) { index += 1 }
					guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
						throw error(L.t("parse.toml.keyNameInvalid", "不是合法的键名", table: .messages))
					}
					path.append(text)
				}
				skipInlineWhitespace()
				if !isAtEnd, bytes[index] == UInt8(ascii: ".") {
					index += 1
					continue
				}
				return path
			}
		}

		func isBareKeyByte(_ byte: UInt8) -> Bool {
			switch byte {
			case UInt8(ascii: "A")...UInt8(ascii: "Z"),
				UInt8(ascii: "a")...UInt8(ascii: "z"),
				UInt8(ascii: "0")...UInt8(ascii: "9"),
				UInt8(ascii: "_"), UInt8(ascii: "-"):
				return true
			default:
				return false
			}
		}

		// MARK: Values

		mutating func parseValue(path: [String]) throws -> JSONValue {
			guard !isAtEnd else { throw error(L.t("parse.toml.missingValue", "缺少值", table: .messages)) }
			switch bytes[index] {
			case UInt8(ascii: "\""):
				if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") {
					return .string(try parseBasicString(multiline: true))
				}
				return .string(try parseBasicString(multiline: false))
			case UInt8(ascii: "'"):
				if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") {
					return .string(try parseLiteralString(multiline: true))
				}
				return .string(try parseLiteralString(multiline: false))
			case UInt8(ascii: "["):
				return try parseArray(path: path)
			case UInt8(ascii: "{"):
				return try parseInlineTable(path: path)
			default:
				return try parseScalar()
			}
		}

		func peek(_ offset: Int) -> UInt8? {
			let target = index + offset
			return target < bytes.count ? bytes[target] : nil
		}

		mutating func parseBasicString(multiline: Bool) throws -> String {
			index += 1
			if multiline { index += 2 }
			var out: [UInt8] = []
			// A newline immediately after the opening delimiter is trimmed.
			if multiline, !isAtEnd, bytes[index] == 0x0A { index += 1 }

			while true {
				guard !isAtEnd else { throw error(L.t("parse.string.unclosed", "字符串没有闭合", table: .messages)) }
				let byte = bytes[index]

				if byte == UInt8(ascii: "\"") {
					if multiline {
						if peek(1) == UInt8(ascii: "\""), peek(2) == UInt8(ascii: "\"") {
							index += 3
							// Up to two extra quotes belong to the content.
							while !isAtEnd, bytes[index] == UInt8(ascii: "\""), out.count < 2 {
								out.append(UInt8(ascii: "\""))
								index += 1
							}
							break
						}
					} else {
						index += 1
						break
					}
				}

				if byte == UInt8(ascii: "\\") {
					if multiline, isLineEndingAfterBackslash() {
						consumeLineEndingAndLeadingWhitespace()
						continue
					}
					index += 1
					guard !isAtEnd else { throw error(L.t("parse.escape.incomplete", "转义序列不完整", table: .messages)) }
					let escape = bytes[index]
					index += 1
					switch escape {
					case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
					case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
					case UInt8(ascii: "b"): out.append(0x08)
					case UInt8(ascii: "f"): out.append(0x0C)
					case UInt8(ascii: "n"): out.append(0x0A)
					case UInt8(ascii: "r"): out.append(0x0D)
					case UInt8(ascii: "t"): out.append(0x09)
					case UInt8(ascii: "u"): out.append(contentsOf: Array(String(try readHexScalar(4)).utf8))
					case UInt8(ascii: "U"): out.append(contentsOf: Array(String(try readHexScalar(8)).utf8))
					default: throw error(L.t("parse.toml.escapeUnknown", "无法识别的转义", table: .messages))
					}
					continue
				}

				if !multiline, byte == 0x0A { throw error(L.t("parse.string.unclosed", "字符串没有闭合", table: .messages)) }
				out.append(byte)
				index += 1
			}

			guard let string = String(bytes: out, encoding: .utf8) else {
				throw error(L.t("parse.string.notUTF8", "字符串不是合法的 UTF-8", table: .messages))
			}
			return string
		}

		mutating func parseLiteralString(multiline: Bool) throws -> String {
			index += 1
			if multiline { index += 2 }
			var out: [UInt8] = []
			if multiline, !isAtEnd, bytes[index] == 0x0A { index += 1 }

			while true {
				guard !isAtEnd else { throw error(L.t("parse.string.unclosed", "字符串没有闭合", table: .messages)) }
				if bytes[index] == UInt8(ascii: "'") {
					if multiline {
						if peek(1) == UInt8(ascii: "'"), peek(2) == UInt8(ascii: "'") {
							index += 3
							while !isAtEnd, bytes[index] == UInt8(ascii: "'"), out.count < 2 {
								out.append(UInt8(ascii: "'"))
								index += 1
							}
							break
						}
					} else {
						index += 1
						break
					}
				}
				if !multiline, bytes[index] == 0x0A { throw error(L.t("parse.string.unclosed", "字符串没有闭合", table: .messages)) }
				out.append(bytes[index])
				index += 1
			}

			guard let string = String(bytes: out, encoding: .utf8) else {
				throw error(L.t("parse.string.notUTF8", "字符串不是合法的 UTF-8", table: .messages))
			}
			return string
		}

		func isLineEndingAfterBackslash() -> Bool {
			var probe = index + 1
			while probe < bytes.count, bytes[probe] == 0x20 || bytes[probe] == 0x09 { probe += 1 }
			guard probe < bytes.count else { return false }
			return bytes[probe] == 0x0A || bytes[probe] == 0x0D
		}

		mutating func consumeLineEndingAndLeadingWhitespace() {
			index += 1
			while !isAtEnd, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
				index += 1
			}
		}

		mutating func readHexScalar(_ length: Int) throws -> Unicode.Scalar {
			guard index + length <= bytes.count else { throw error(L.t("parse.escape.unicodeIncomplete", "\\u 转义不完整", table: .messages)) }
			var value: UInt32 = 0
			for _ in 0..<length {
				guard let digit = TOMLParser.hexDigit(bytes[index]) else {
					throw error(L.t("parse.escape.unicodeNonHex", "\\u 转义里出现了非十六进制字符", table: .messages))
				}
				value = value << 4 | UInt32(digit)
				index += 1
			}
			guard let scalar = Unicode.Scalar(value) else { throw error(L.t("parse.escape.badUnicode", "不合法的 \\u 转义", table: .messages)) }
			return scalar
		}

		mutating func parseArray(path: [String]) throws -> JSONValue {
			index += 1 // consume '['
			var items: [JSONValue] = []
			while true {
				skipWhitespaceAndComments()
				guard !isAtEnd else { throw error(L.t("parse.array.unclosed", "数组没有闭合", table: .messages)) }
				if bytes[index] == UInt8(ascii: "]") {
					index += 1
					break
				}
				let itemStart = index
				let item = try parseValue(path: path + [String(items.count)])
				spans[JSONSource.pathKey(path + [String(items.count)])] = itemStart..<index
				items.append(item)
				skipWhitespaceAndComments()
				guard !isAtEnd else { throw error(L.t("parse.array.unclosed", "数组没有闭合", table: .messages)) }
				if bytes[index] == UInt8(ascii: ",") {
					index += 1
					continue
				}
				if bytes[index] == UInt8(ascii: "]") {
					index += 1
					break
				}
				throw error(L.t("parse.array.expectedCommaOrBracket", "数组里期望 , 或 ]", table: .messages))
			}
			return .array(items)
		}

		mutating func skipWhitespaceAndComments() {
			while !isAtEnd {
				switch bytes[index] {
				case 0x20, 0x09, 0x0A, 0x0D:
					index += 1
				case UInt8(ascii: "#"):
					hasComments = true
					skipToEndOfLine()
				default:
					return
				}
			}
		}

		mutating func parseInlineTable(path: [String]) throws -> JSONValue {
			index += 1 // consume '{'
			var object = JSONObject()
			skipInlineWhitespace()
			if !isAtEnd, bytes[index] == UInt8(ascii: "}") {
				index += 1
				return .object(object)
			}
			while true {
				skipInlineWhitespace()
				let key = try parseDottedKey()
				skipInlineWhitespace()
				guard !isAtEnd, bytes[index] == UInt8(ascii: "=") else {
					throw error(L.t("parse.toml.inlineMissingEquals", "内联表里缺少 =", table: .messages))
				}
				index += 1
				skipInlineWhitespace()
				let valueStart = index
				let value = try parseValue(path: path + key)
				spans[JSONSource.pathKey(path + key)] = valueStart..<index
				object[key.count == 1 ? key[0] : key.joined(separator: ".")] = value
				skipInlineWhitespace()
				guard !isAtEnd else { throw error(L.t("parse.toml.inlineUnclosed", "内联表没有闭合", table: .messages)) }
				if bytes[index] == UInt8(ascii: ",") {
					index += 1
					continue
				}
				if bytes[index] == UInt8(ascii: "}") {
					index += 1
					break
				}
				throw error(L.t("parse.toml.inlineExpectedCommaOrBrace", "内联表里期望 , 或 }", table: .messages))
			}
			return .object(object)
		}

		/// Reads up to the next structural delimiter and classifies the literal.
		mutating func parseScalar() throws -> JSONValue {
			let start = index
			while !isAtEnd {
				let byte = bytes[index]
				if byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: ",")
					|| byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}")
					|| byte == UInt8(ascii: "#")
				{
					break
				}
				index += 1
			}
			var end = index
			while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
			guard end > start, let raw = String(bytes: bytes[start..<end], encoding: .utf8) else {
				throw error(L.t("parse.toml.missingValue", "缺少值", table: .messages))
			}
			// The scan runs up to the next delimiter, so leaving `index` there
			// would make the caller record a span that carries the spaces before
			// the delimiter. Rewind to the trimmed end; every caller skips the
			// separator again anyway.
			index = end
			guard let value = TOMLParser.classify(raw) else {
				throw error(String(format: L.t("parse.toml.unknownValue", "无法识别的值 %@", table: .messages), raw))
			}
			return value
		}

		// MARK: Tree helpers

		/// Walks `[a.b.c]` onto the tree, creating missing tables.
		///
		/// Returns the path values should actually be written to: a component
		/// that resolves to an array of tables means the last element, which is
		/// how `[[a]]` followed by `[a.b]` is supposed to behave.
		mutating func ensureTable(_ path: [String]) throws -> [String] {
			var resolved: [String] = []
			for component in path {
				let candidate = resolved + [component]
				if let existing = root.value(at: candidate) {
					if let array = existing.arrayValue {
						guard !array.isEmpty else {
							throw error(String(format: L.t("parse.toml.emptyArrayTable", "表 %@ 是空数组", table: .messages), candidate.joined(separator: ".")))
						}
						resolved = candidate + [String(array.count - 1)]
					} else if existing.objectValue != nil {
						resolved = candidate
					} else {
						throw error(String(format: L.t("parse.toml.scalarTable", "%@ 已经是标量，不能再当表", table: .messages), candidate.joined(separator: ".")))
					}
				} else {
					root.setValue(.object(JSONObject()), at: candidate)
					resolved = candidate
				}
			}
			return resolved
		}
	}

	static func hexDigit(_ byte: UInt8) -> UInt8? {
		switch byte {
		case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
		case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
		case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
		default: return nil
		}
	}

	/// Turns a TOML literal into a tree node.
	static func classify(_ raw: String) -> JSONValue? {
		switch raw {
		case "true": return .bool(true)
		case "false": return .bool(false)
		default: break
		}

		let stripped = raw.replacingOccurrences(of: "_", with: "")

		if let integer = parseInteger(stripped) {
			return .number(JSONNumber(raw: integer))
		}

		switch stripped {
		case "inf", "+inf", "-inf", "nan", "+nan", "-nan":
			// `Double` cannot read these spellings, so the literal is kept as-is.
			return .number(JSONNumber(raw: stripped))
		default: break
		}

		if isFloatLiteral(stripped), Double(stripped) != nil {
			return .number(JSONNumber(raw: stripped))
		}

		// Offset date-times and local dates/times are kept verbatim: AgentKit has
		// no reason to interpret them and must not reformat them.
		if looksLikeDateOrTime(stripped) {
			return .string(stripped)
		}

		return nil
	}

	static func parseInteger(_ text: String) -> String? {
		var body = text
		var sign = ""
		if body.hasPrefix("+") || body.hasPrefix("-") {
			sign = String(body.first!)
			body.removeFirst()
		}
		if body.hasPrefix("0x") || body.hasPrefix("0X") {
			let digits = String(body.dropFirst(2))
			guard !digits.isEmpty, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
			guard let value = Int(digits, radix: 16) else { return nil }
			return sign + String(value)
		}
		if body.hasPrefix("0o") || body.hasPrefix("0O") {
			let digits = String(body.dropFirst(2))
			guard !digits.isEmpty, digits.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
			guard let value = Int(digits, radix: 8) else { return nil }
			return sign + String(value)
		}
		if body.hasPrefix("0b") || body.hasPrefix("0B") {
			let digits = String(body.dropFirst(2))
			guard !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "1" }) else { return nil }
			guard let value = Int(digits, radix: 2) else { return nil }
			return sign + String(value)
		}
		guard !body.isEmpty, body.allSatisfy(\.isNumber) else { return nil }
		// Keeps leading zeros out of the tree; they are not valid TOML anyway.
		guard let value = Int(body) else { return nil }
		return sign + String(value)
	}

	static func isFloatLiteral(_ text: String) -> Bool {
		var body = text
		if body.hasPrefix("+") || body.hasPrefix("-") { body.removeFirst() }
		guard !body.isEmpty else { return false }
		let allowed = body.allSatisfy { $0.isNumber || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-" }
		guard allowed else { return false }
		return body.contains(".") || body.contains("e") || body.contains("E")
	}

	static func looksLikeDateOrTime(_ text: String) -> Bool {
		// 1979-05-27T07:32:00Z / 1979-05-27 / 07:32:00
		let hasColon = text.contains(":")
		let dashCount = text.filter { $0 == "-" }.count
		if dashCount >= 2, text.first?.isNumber == true { return true }
		if hasColon, text.first?.isNumber == true, !text.contains("e") { return true }
		return false
	}
}

// MARK: - Writer

public struct TOMLWriter {
	public init() {}

	public func serialize(_ value: JSONValue) -> String {
		guard let object = value.objectValue else {
			return serializeValue(value) + "\n"
		}
		var out = ""
		emit(object, at: [], root: true, into: &out)
		return out
	}

	/// One table block, starting with its `[header]` line.
	public func serializeBlock(path: [String], value: JSONObject) -> String {
		var out = ""
		emit(value, at: path, root: false, into: &out)
		return out
	}

	public func serializeValue(_ value: JSONValue) -> String {
		switch value {
		case .null:
			return "\"\""
		case .bool(let flag):
			return flag ? "true" : "false"
		case .number(let number):
			return number.raw
		case .string(let string):
			return TOMLWriter.quote(string)
		case .array(let items):
			return "[" + items.map { serializeValue($0) }.joined(separator: ", ") + "]"
		case .object(let object):
			let pairs = object.pairs.map { "\(TOMLWriter.key($0.0)) = \(serializeValue($0.1))" }
			return pairs.isEmpty ? "{}" : "{ " + pairs.joined(separator: ", ") + " }"
		}
	}

	private func emit(_ object: JSONObject, at path: [String], root: Bool, into out: inout String) {
		if !root {
			out += "[" + path.map(TOMLWriter.key).joined(separator: ".") + "]\n"
		}

		var tables: [(String, JSONValue)] = []
		for (key, value) in object.pairs {
			if value.objectValue != nil {
				tables.append((key, value))
				continue
			}
			if let items = value.arrayValue, TOMLWriter.isArrayOfTables(items) {
				tables.append((key, value))
				continue
			}
			out += "\(TOMLWriter.key(key)) = \(serializeValue(value))\n"
		}

		for (key, value) in tables {
			out += "\n"
			if let nested = value.objectValue {
				emit(nested, at: path + [key], root: false, into: &out)
				continue
			}
			for item in value.arrayValue ?? [] {
				guard let element = item.objectValue else { continue }
				out += "[[" + (path + [key]).map(TOMLWriter.key).joined(separator: ".") + "]]\n"
				emitBody(element, at: path + [key], into: &out)
			}
		}
	}

	/// Emits an array-of-tables element: its scalars, then any sub-tables.
	private func emitBody(_ object: JSONObject, at path: [String], into out: inout String) {
		var tables: [(String, JSONValue)] = []
		for (key, value) in object.pairs {
			if value.objectValue != nil {
				tables.append((key, value))
				continue
			}
			if let items = value.arrayValue, TOMLWriter.isArrayOfTables(items) {
				tables.append((key, value))
				continue
			}
			out += "\(TOMLWriter.key(key)) = \(serializeValue(value))\n"
		}
		for (key, value) in tables {
			out += "\n"
			if let nested = value.objectValue {
				emit(nested, at: path + [key], root: false, into: &out)
			}
		}
	}

	/// An array is an array of tables when every element is an object.
	static func isArrayOfTables(_ items: [JSONValue]) -> Bool {
		!items.isEmpty && items.allSatisfy { $0.objectValue != nil }
	}

	static func key(_ key: String) -> String {
		let bare = !key.isEmpty && key.allSatisfy {
			$0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-"
		}
		return bare ? key : quote(key)
	}

	static func quote(_ string: String) -> String {
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
					out += String(format: "\\u%04X", scalar.value)
				} else {
					out.unicodeScalars.append(scalar)
				}
			}
		}
		return out + "\""
	}
}
