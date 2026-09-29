//
//  SettingsEditor.swift
//  AgentKit
//
//  Turns a settings file plus a typed schema into editable field values, while
//  keeping every key the schema does not know about exactly where it was.
//

import Foundation

public enum FieldEditorKind: Equatable {
	case toggle
	case text
	case path
	case picker
	case list
	case json
}

public struct SettingsEditor {
	public let schema: SettingsSchemaDefinition
	public let original: JSONValue
	public var root: JSONValue
	/// Per-key parse errors from free-text editing, shown inline.
	public var errors: [String: String] = [:]
	/// Non-nil when the file could not be parsed and must not be written.
	public let readOnlyReason: String?

	public init(document: JSONDocument, schema: SettingsSchemaDefinition) {
		self.schema = schema
		if document.status.isWritable {
			self.original = document.editableValue
			self.root = document.editableValue
			self.readOnlyReason = nil
		} else {
			self.original = .object(JSONObject())
			self.root = .object(JSONObject())
			switch document.status {
			case .malformed(let reason):
				self.readOnlyReason = String(format: L.t("settings.readOnly.malformed", "settings.json 不是合法 JSON：%@", table: .messages), reason)
			case .unreadable(let reason):
				self.readOnlyReason = String(format: L.t("settings.readOnly.unreadable", "settings.json 无法读取：%@", table: .messages), reason)
			default:
				self.readOnlyReason = nil
			}
		}
	}

	public var hasChanges: Bool { root != original }

	public var errorCount: Int { errors.count }

	// MARK: - Presence

	public func isSet(_ field: SettingField) -> Bool {
		root.value(at: field.path) != nil
	}

	public func rawValue(_ field: SettingField) -> JSONValue? {
		root.value(at: field.path)
	}

	// MARK: - Reads

	public func bool(_ field: SettingField) -> Bool {
		if case .bool(let flag) = rawValue(field) { return flag }
		return field.fallback == "true"
	}

	/// The string shown for text-like editors: the stored value, or the
	/// documented default when the key is absent.
	public func text(_ field: SettingField) -> String {
		guard let value = rawValue(field) else { return field.fallback }
		switch value {
		case .string(let string): return string
		case .bool(let flag): return flag ? "true" : "false"
		case .number(let number): return number.raw
		case .null: return ""
		default: return JSONWriter.compact.serialize(value)
		}
	}

	/// For `.textList`: the stored list rendered the way pi accepts it.
	public func listText(_ field: SettingField) -> String {
		guard let value = rawValue(field) else { return field.fallback }
		if let strings = value.stringsValue {
			return strings.joined(separator: ", ")
		}
		return JSONWriter.compact.serialize(value)
	}

	public func jsonText(_ field: SettingField) -> String {
		guard let value = rawValue(field) else { return field.fallback }
		return JSONWriter.pretty.serialize(value)
	}

	public func editorKind(_ field: SettingField) -> FieldEditorKind {
		switch field.type {
		case .bool: return .toggle
		case .path: return .path
		case .choice, .boolOrAuto, .choiceOrFalse: return .picker
		case .textList, .mixedList: return .list
		case .json: return .json
		case .integer, .text: return .text
		}
	}

	/// Picker options, with the empty string meaning "use the default".
	public func pickerOptions(_ field: SettingField) -> [String] {
		[""] + field.type.choices
	}

	// MARK: - Writes

	public mutating func setValue(_ value: JSONValue, _ field: SettingField) {
		root.setValue(value, at: field.path)
		errors[field.key] = nil
	}

	public mutating func clear(_ field: SettingField) {
		root.removeValue(at: field.path)
		errors[field.key] = nil
	}

	public mutating func setBool(_ flag: Bool, _ field: SettingField) {
		setValue(.bool(flag), field)
	}

	/// Validates and stores a text-like value. Returns the error message when
	/// the input is rejected, so the view can keep the keystroke visible.
	@discardableResult
	public mutating func setText(_ raw: String, _ field: SettingField) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespaces)

		if trimmed.isEmpty {
			clear(field)
			return nil
		}

		switch field.type {
		case .bool:
			switch trimmed.lowercased() {
			case "true", "1", "yes": setValue(.bool(true), field)
			case "false", "0", "no": setValue(.bool(false), field)
			default: return record(L.t("settings.error.bool", "只能是 true / false", table: .messages), field)
			}
		case .integer(let min, let max):
			guard let number = Int(trimmed) else {
				return record(L.t("settings.error.integer", "需要一个整数", table: .messages), field)
			}
			if let min, number < min { return record(String(format: L.t("settings.error.min", "不能小于 %d", table: .messages), min), field) }
			if let max, number > max { return record(String(format: L.t("settings.error.max", "不能大于 %d", table: .messages), max), field) }
			setValue(.number(JSONNumber(number)), field)
		case .choice(let options):
			guard options.contains(trimmed) else {
				return record(String(format: L.t("settings.error.choice", "只能是 %@", table: .messages), options.joined(separator: " / ")), field)
			}
			setValue(.string(trimmed), field)
		case .boolOrAuto:
			switch trimmed {
			case "auto": setValue(.string("auto"), field)
			case "true": setValue(.bool(true), field)
			case "false": setValue(.bool(false), field)
			default: return record(L.t("settings.error.boolOrAuto", "只能是 auto / true / false", table: .messages), field)
			}
		case .choiceOrFalse(let options):
			if trimmed == "false" {
				setValue(.bool(false), field)
			} else if options.contains(trimmed) {
				setValue(.string(trimmed), field)
			} else {
				return record(String(format: L.t("settings.error.choiceOrFalse", "只能是 false / %@", table: .messages), options.joined(separator: " / ")), field)
			}
		case .textList:
			guard let items = SettingsEditor.parseList(trimmed) else {
				return record(L.t("settings.error.list", "需要逗号分隔的列表，或 JSON 数组", table: .messages), field)
			}
			setValue(.array(items.map { .string($0) }), field)
		case .mixedList:
			guard let value = try? JSONParser.parse(trimmed), value.arrayValue != nil else {
				return record(L.t("settings.error.jsonArray", "需要一个 JSON 数组", table: .messages), field)
			}
			setValue(value, field)
		case .json:
			guard let value = try? JSONParser.parse(trimmed) else {
				return record(L.t("settings.error.json", "不是合法 JSON", table: .messages), field)
			}
			setValue(value, field)
		case .text, .path:
			setValue(.string(raw), field)
		}
		return nil
	}

	/// For `.textList` the field accepts `a, b` as well as `["a", "b"]`.
	static func parseList(_ text: String) -> [String]? {
		if text.hasPrefix("[") {
			guard let value = try? JSONParser.parse(text),
				let items = value.stringsValue
			else { return nil }
			return items
		}
		if text.hasPrefix("{") { return nil }
		return text.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
	}

	@discardableResult
	private mutating func record(_ message: String, _ field: SettingField) -> String {
		errors[field.key] = message
		return message
	}

	// MARK: - Unknown keys

	/// Leaf paths in the file that the schema does not describe, in file order.
	public func unknownPaths() -> [String] {
		var known = schema.knownKeys
		var prefixes = Set<String>()
		for key in known {
			let components = key.split(separator: ".").map(String.init)
			for count in 1..<max(components.count, 1) {
				prefixes.insert(components.prefix(count).joined(separator: "."))
			}
		}
		known.formUnion(prefixes)

		var out: [String] = []
		SettingsEditor.walk(root, path: [], known: known, claimed: prefixes, into: &out)
		return out
	}

	private static func walk(
		_ value: JSONValue,
		path: [String],
		known: Set<String>,
		claimed: Set<String>,
		into out: inout [String]
	) {
		let key = path.joined(separator: ".")
		if !path.isEmpty, known.contains(key), !claimed.contains(key) {
			// A schema-owned leaf: not unknown, do not descend.
			return
		}
		if let object = value.objectValue, !object.isEmpty {
			if !path.isEmpty, !claimed.contains(key) {
				out.append(key)
				return
			}
			for child in object.pairs {
				walk(child.1, path: path + [child.0], known: known, claimed: claimed, into: &out)
			}
			return
		}
		if !path.isEmpty {
			// Either a key the schema does not know, or a scalar where the
			// schema expects an object. Both belong in the read-only list.
			out.append(key)
		}
	}

	/// Value of an unknown path, for the read-only "其它键" list.
	public func unknownValue(at path: String) -> JSONValue? {
		root.value(at: path.split(separator: ".").map(String.init))
	}

	public var summary: String {
		let set = schema.fields.filter { isSet($0) }.count
		return String(format: L.t("settings.summary", "已设置 %d / %d 项", table: .messages), set, schema.fields.count)
	}
}
