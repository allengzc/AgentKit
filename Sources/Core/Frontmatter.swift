//
//  Frontmatter.swift
//  AgentKit
//
//  YAML frontmatter for the Markdown files we edit (sub-agent definitions and
//  `SKILL.md`).
//
//  Entries keep the literal text of their value rather than a parsed value, so
//  editing the body of an agent file rewrites nothing but the body, and
//  `tools: read, grep` keeps that exact spelling instead of becoming a YAML
//  flow sequence.
//

import Foundation

public enum FrontmatterValue: Equatable {
	case string(String)
	case bool(Bool)
	case number(Double)
	case list([String])
	/// A nested map or block scalar: kept verbatim, edited only as raw text.
	case complex(String)

	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}

	public var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	public var listValue: [String]? {
		if case .list(let value) = self { return value }
		return nil
	}

	public var displayText: String {
		switch self {
		case .string(let value): return value
		case .bool(let value): return value ? "true" : "false"
		case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
		case .list(let value): return value.joined(separator: ", ")
		case .complex(let value): return value
		}
	}
}

public struct FrontmatterDocument {
	public struct Entry {
		public var key: String
		/// The literal right-hand side, exactly as it appears in the file.
		public var rawValue: String

		public init(key: String, rawValue: String) {
			self.key = key
			self.rawValue = rawValue
		}
	}

	public var entries: [Entry]
	public var body: String
	public var hasFrontmatter: Bool
	/// The line ending the file used, preserved on write.
	public var lineEnding: String
	public let rawText: String

	public init(
		entries: [Entry],
		body: String,
		hasFrontmatter: Bool,
		lineEnding: String,
		rawText: String
	) {
		self.entries = entries
		self.body = body
		self.hasFrontmatter = hasFrontmatter
		self.lineEnding = lineEnding
		self.rawText = rawText
	}

	public static let empty = FrontmatterDocument(
		entries: [],
		body: "",
		hasFrontmatter: false,
		lineEnding: "\n",
		rawText: ""
	)

	public func entry(_ key: String) -> Entry? {
		entries.first { $0.key == key }
	}

	public func value(_ key: String) -> FrontmatterValue? {
		guard let entry = entry(key) else { return nil }
		return FrontmatterDocument.parseValue(entry.rawValue)
	}

	public func string(_ key: String) -> String? {
		value(key)?.stringValue
	}

	/// Mirrors pi's own tolerance: `tools: a, b` and `tools: [a, b]` are both
	/// valid and both are in use in the wild.
	public func stringArray(_ key: String) -> [String]? {
		guard let value = value(key) else { return nil }
		let items: [String]
		switch value {
		case .list(let list): items = list
		case .string(let string): items = string.split(separator: ",").map(String.init)
		case .complex(let raw): items = raw.split(separator: ",").map(String.init)
		default: return nil
		}
		let cleaned = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		return cleaned.isEmpty ? nil : cleaned
	}

	public mutating func setRaw(_ rawValue: String, forKey key: String) {
		if let index = entries.firstIndex(where: { $0.key == key }) {
			entries[index].rawValue = rawValue
		} else {
			entries.append(Entry(key: key, rawValue: rawValue))
		}
	}

	public mutating func remove(key: String) {
		entries.removeAll { $0.key == key }
	}

	/// Serializes back to Markdown, keeping entry order and the original
	/// right-hand sides.
	public func render() -> String {
		guard hasFrontmatter || !entries.isEmpty else { return body }
		var out = "---" + lineEnding
		for entry in entries {
			out += "\(entry.key): \(entry.rawValue)" + lineEnding
		}
		out += "---" + lineEnding
		out += body
		return out
	}

	// MARK: - Parsing

	public static func parse(_ text: String) -> FrontmatterDocument {
		var cleaned = text
		var lineEnding = "\n"
		if cleaned.contains("\r\n") {
			lineEnding = "\r\n"
			cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
		}
		if cleaned.hasPrefix("\u{FEFF}") { cleaned.removeFirst() }

		let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		guard let first = lines.first,
			first.trimmingCharacters(in: .whitespaces) == "---"
		else {
			return FrontmatterDocument(
				entries: [],
				body: cleaned,
				hasFrontmatter: false,
				lineEnding: lineEnding,
				rawText: text
			)
		}

		var closingIndex: Int?
		var index = 1
		while index < lines.count {
			let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
			if trimmed == "---" || trimmed == "..." {
				closingIndex = index
				break
			}
			index += 1
		}

		guard let closing = closingIndex else {
			// An unterminated block: treat the whole file as body rather than
			// silently swallowing it.
			return FrontmatterDocument(
				entries: [],
				body: cleaned,
				hasFrontmatter: false,
				lineEnding: lineEnding,
				rawText: text
			)
		}

		var entries: [Entry] = []
		for line in lines[1..<closing] {
			if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
			if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
			// Indented lines continue the previous value (block scalars, nested maps).
			if line.hasPrefix(" ") || line.hasPrefix("\t") {
				if var last = entries.popLast() {
					last.rawValue += "\n" + line
					entries.append(last)
				}
				continue
			}
			guard let colon = firstUnquotedColon(in: line) else { continue }
			let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
			let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
			guard !key.isEmpty else { continue }
			entries.append(Entry(key: key, rawValue: rest))
		}

		let body = lines[(closing + 1)...].joined(separator: "\n")
		return FrontmatterDocument(
			entries: entries,
			body: body,
			hasFrontmatter: true,
			lineEnding: lineEnding,
			rawText: text
		)
	}

	/// Finds the `:` that separates key from value, ignoring colons inside a
	/// quoted key.
	static func firstUnquotedColon(in line: String) -> String.Index? {
		var inSingle = false
		var inDouble = false
		var index = line.startIndex
		while index < line.endIndex {
			let character = line[index]
			if character == "'", !inDouble { inSingle.toggle() }
			if character == "\"", !inSingle { inDouble.toggle() }
			if character == ":", !inSingle, !inDouble { return index }
			index = line.index(after: index)
		}
		return nil
	}

	public static func parseValue(_ raw: String) -> FrontmatterValue {
		let trimmed = raw.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty { return .string("") }

		if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
			let inner = String(trimmed.dropFirst().dropLast())
			let items = splitInlineList(inner)
			if !items.isEmpty || inner.trimmingCharacters(in: .whitespaces).isEmpty {
				return .list(items)
			}
		}

		if trimmed.hasPrefix("{") || trimmed.hasPrefix("|") || trimmed.hasPrefix(">") || trimmed.contains("\n") {
			return .complex(trimmed)
		}

		if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
			return .string(unescapeDouble(String(trimmed.dropFirst().dropLast())))
		}
		if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
			return .string(String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
		}

		switch trimmed.lowercased() {
		case "true", "yes", "on": return .bool(true)
		case "false", "no", "off": return .bool(false)
		case "null", "~": return .string("")
		default: break
		}

		if let number = Double(trimmed), !trimmed.hasPrefix("+") {
			return .number(number)
		}

		return .string(trimmed)
	}

	static func splitInlineList(_ text: String) -> [String] {
		var items: [String] = []
		var current = ""
		var inSingle = false
		var inDouble = false
		for character in text {
			if character == "'", !inDouble { inSingle.toggle() }
			else if character == "\"", !inSingle { inDouble.toggle() }
			if character == ",", !inSingle, !inDouble {
				items.append(current.trimmingCharacters(in: .whitespaces))
				current = ""
				continue
			}
			current.append(character)
		}
		let tail = current.trimmingCharacters(in: .whitespaces)
		if !tail.isEmpty { items.append(tail) }
		return items.map { item in
			var value = item
			if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
				value = String(value.dropFirst().dropLast())
			} else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
				value = String(value.dropFirst().dropLast())
			}
			return value
		}
	}

	static func unescapeDouble(_ text: String) -> String {
		var out = ""
		var escaped = false
		for character in text {
			if escaped {
				switch character {
				case "n": out.append("\n")
				case "t": out.append("\t")
				case "\\": out.append("\\")
				case "\"": out.append("\"")
				default: out.append(character)
				}
				escaped = false
				continue
			}
			if character == "\\" {
				escaped = true
				continue
			}
			out.append(character)
		}
		if escaped { out.append("\\") }
		return out
	}

	/// Renders a value the way these files already spell it: a comma-separated
	/// scalar for tool lists, a quoted string when it contains `:` or `#`.
	public static func literal(for value: FrontmatterValue) -> String {
		switch value {
		case .string(let string):
			return quoteIfNeeded(string)
		case .bool(let flag):
			return flag ? "true" : "false"
		case .number(let number):
			return number == number.rounded() ? String(Int(number)) : String(number)
		case .list(let items):
			return items.joined(separator: ", ")
		case .complex(let raw):
			return raw
		}
	}

	public static func quoteIfNeeded(_ string: String) -> String {
		if string.isEmpty { return "\"\"" }
		let needsQuoting = string.contains(":") || string.contains("#")
			|| string.hasPrefix("{") || string.hasPrefix("[")
			|| string.hasPrefix(" ") || string.hasSuffix(" ")
			|| string.lowercased() == "true" || string.lowercased() == "false"
			|| Double(string) != nil
		guard needsQuoting else { return string }
		let escaped = string
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		return "\"\(escaped)\""
	}
}
