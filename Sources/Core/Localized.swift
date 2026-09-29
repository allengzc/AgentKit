//
//  Localized.swift
//  AgentKit
//
//  Language, per-language strings, and the lookup the whole app goes through.
//
//  Three things live here:
//
//  1. `AppLanguage` — which language the app is showing.
//  2. `LocalizedText` — a value that is either one string for every language, or
//     a different string per language. Descriptors and settings schemas are data,
//     so their labels travel with the data instead of in a separate table.
//  3. `L.t(_:_:table:)` — the lookup for strings that live in code. It reads
//     `.strings` files out of the bundle, and falls back to the literal at the
//     call site, which is why a missing table can never produce an empty label.
//
//  Swapping the language re-creates the view tree (see `RootView().id(language)`),
//  so nothing here has to be observable and `L.t` can be called from any thread —
//  scans and validators run off the main actor and need these strings too.
//

import Foundation

// MARK: - Language

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
	case zhHans = "zh-Hans"
	case en = "en"

	/// What to show in a menu. Each language names itself in its own language —
	/// "Chinese (Simplified)" is not useful to someone who needs it.
	public var nativeName: String {
		switch self {
		case .zhHans: return "简体中文"
		case .en: return "English"
		}
	}

	/// The system's preference, narrowed to the languages this app ships.
	public static var systemDefault: AppLanguage {
		for identifier in Locale.preferredLanguages {
			let lower = identifier.lowercased()
			if lower.hasPrefix("zh") { return .zhHans }
			if lower.hasPrefix("en") { return .en }
		}
		return .en
	}
}

// MARK: - Per-language text

/// A string that may differ per language.
///
/// Decodes from a plain string (used for every language — what a hand-written
/// descriptor most likely contains) or from an object keyed by language code.
/// The plain form is what makes this backward compatible: every descriptor and
/// schema written before this type existed keeps working unchanged.
public struct LocalizedText: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
	private let plain: String?
	private let values: [String: String]

	public init(_ plain: String) {
		self.plain = plain
		self.values = [:]
	}

	public init(_ values: [AppLanguage: String]) {
		self.plain = nil
		self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
	}

	public init(stringLiteral value: String) {
		self.init(value)
	}

	/// The convenient spelling at a call site: `LocalizedText.both(zh: "会话", en: "Sessions")`.
	public static func both(zh: String, en: String) -> LocalizedText {
		LocalizedText([.zhHans: zh, .en: en])
	}

	/// True when the value is the same in every language.
	///
	/// A test asserts the built-in schemas and descriptors are *not* plain: a
	/// forgotten translation would otherwise show Chinese in English mode and
	/// nothing would complain.
	public var isPlain: Bool { plain != nil }

	public init(from decoder: Decoder) throws {
		let single = try decoder.singleValueContainer()
		if let text = try? single.decode(String.self) {
			self.plain = text
			self.values = [:]
			return
		}
		let map = try single.decode([String: String].self)
		self.plain = nil
		self.values = map
	}

	public func encode(to encoder: Encoder) throws {
		var single = encoder.singleValueContainer()
		if let plain {
			try single.encode(plain)
		} else {
			try single.encode(values)
		}
	}

	public func text(for language: AppLanguage) -> String {
		if let plain { return plain }
		if let exact = values[language.rawValue] { return exact }
		// A language we have no entry for falls back to the other shipped one
		// rather than to an empty label.
		for candidate in AppLanguage.allCases where candidate != language {
			if let fallback = values[candidate.rawValue] { return fallback }
		}
		return values.values.sorted().first ?? ""
	}

	/// Convenience for the common case of needing the string right now.
	public var current: String { text(for: Localization.shared.language) }
}

// MARK: - Tables

public enum StringTable: String, CaseIterable, Sendable {
	/// Strings that belong to the interface: Views and App.
	case ui = "UI"
	/// Strings the user reads when something goes wrong, produced in Core and
	/// Surfaces — validation, diagnostics, refused writes.
	case messages = "Messages"
}

/// The app's language, the loaded `.strings` tables, and the lookup.
///
/// Not `@MainActor`: scanners and the file layer build user-facing messages off
/// the main thread, and they must be able to call `L.t`. SwiftUI gets its redraw
/// from an `.id()` on the root view instead of from observation.
public final class Localization: @unchecked Sendable {
	public static let shared = Localization()

	private let lock = NSLock()
	private var _language: AppLanguage
	private var _resourceDirectory: URL?
	private var tables: [String: [String: String]] = [:]

	private init() {
		_language = .systemDefault
	}

	public var language: AppLanguage {
		get { lock.lock(); defer { lock.unlock() }; return _language }
		set {
			lock.lock()
			_language = newValue
			// Cached tables are per language, so a switch has to drop them.
			tables.removeAll()
			lock.unlock()
		}
	}

	/// Where to read `.strings` from, overriding the bundle.
	///
	/// The test binary has no `.lproj` directories at all, so tests point this at
	/// a fixture; the app leaves it nil and uses `Bundle.main`.
	public var resourceDirectory: URL? {
		get { lock.lock(); defer { lock.unlock() }; return _resourceDirectory }
		set { lock.lock(); _resourceDirectory = newValue; tables.removeAll(); lock.unlock() }
	}

	/// `key` → value for one table in one language. Empty when the table is absent.
	public func table(_ name: String, language: AppLanguage) -> [String: String] {
		let cacheKey = "\(language.rawValue)/\(name)"
		lock.lock()
		if let cached = tables[cacheKey] { lock.unlock(); return cached }
		let directory = _resourceDirectory
		lock.unlock()

		var loaded: [String: String] = [:]
		for url in candidateURLs(name: name, language: language, override: directory) {
			if let dictionary = NSDictionary(contentsOf: url) as? [String: String], !dictionary.isEmpty {
				loaded = dictionary
				break
			}
		}

		lock.lock()
		tables[cacheKey] = loaded
		lock.unlock()
		return loaded
	}

	private func candidateURLs(name: String, language: AppLanguage, override: URL?) -> [URL] {
		var urls: [URL] = []
		if let override {
			urls.append(override.appendingPathComponent("\(language.rawValue)/\(name).strings"))
			urls.append(override.appendingPathComponent("\(language.rawValue).lproj/\(name).strings"))
		}
		// A bundle assembled by hand has no resource catalog, so ask for the
		// localization explicitly — this is the only lookup that honours `.lproj`.
		if let path = Bundle.main.path(
			forResource: name, ofType: "strings", inDirectory: nil, forLocalization: language.rawValue
		) {
			urls.append(URL(fileURLWithPath: path))
		}
		return urls
	}
}

/// The lookup every call site uses.
///
/// `L.t("pane.skills.title", "Skills")` — the second argument is the string that
/// shows when the table is missing or the key is not in it yet. Keys are dotted
/// and grouped by area (`pane.`, `button.`, `mcp.`, `write.`).
public enum L {
	@discardableResult
	public static func t(_ key: String, _ fallback: String = "", table: StringTable = .ui) -> String {
		let value = Localization.shared.table(table.rawValue, language: Localization.shared.language)[key]
		if let value, !value.isEmpty { return value }
		return fallback.isEmpty ? key : fallback
	}

	/// A parameterised message: `String(format: L.t("x.y", "已跳过 %d 项"), count)`.
	/// The key stays parameter-free so the table stays readable.
}
