//
//  SessionsSurface.swift
//  AgentKit
//
//  Reading an agent's session files.
//
//  The layout and the file format differ per agent and both are declared in the
//  descriptor: pi writes `sessions/<cwd slug>/<stamp>.jsonl` with the session
//  fields at the top level of the first line, while Codex writes
//  `sessions/<year>/<month>/<day>/rollout-*.jsonl` with everything nested under
//  `payload` and keeps display names in a separate `session_index.jsonl`.
//
//  Only the first line is needed to list a session, so the list is filled from
//  that line alone; message counts and token totals come from a separate
//  streaming pass cached by (size, mtime).
//
//  These files are read with `JSONSerialization` rather than AgentKit's own
//  parser: nothing here is written back, so round-trip fidelity is irrelevant
//  and the C parser is far faster on the multi-megabyte files Codex produces.
//

import Foundation

public struct SessionRecord: Identifiable {
	public let url: URL
	public var fileSize: Int
	public var modified: Date

	// From the header line.
	public var sessionID: String
	public var cwd: String
	public var started: Date?
	public var parentSession: String?
	public var model: String?

	// From the streaming pass.
	public var name: String?
	public var firstUserText: String?
	public var messageCount: Int = 0
	public var totalTokens: Int = 0
	public var totalCost: Double = 0
	public var models: [String] = []
	public var statsLoaded = false

	public var id: String { url.path }

	public var displayTitle: String {
		if let name, !name.isEmpty { return name }
		if let firstUserText, !firstUserText.isEmpty { return firstUserText }
		return url.deletingPathExtension().lastPathComponent
	}

	public var projectSlug: String { url.deletingLastPathComponent().lastPathComponent }

	public var isFork: Bool { parentSession != nil }

	/// The working directory as a URL, when it still resolves.
	public var cwdURL: URL? {
		guard !cwd.isEmpty else { return nil }
		let url = URL(fileURLWithPath: cwd)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}
}

/// Everything a session listing needs, resolved from the descriptor.
public struct SessionsConfig {
	public let root: URL
	public let recursive: Bool
	public let headerType: String?
	public let headerScanLines: Int?
	public let header: SessionHeaderPaths
	public let index: SessionIndexSpec?
	public let indexURL: URL?
	public let message: SessionMessageSpec?
	public let nameEntryType: String?
	public let policy: BackupPolicy

	/// Builds the config, or nil when the descriptor did not describe sessions.
	public static func resolve(
		surface: SurfaceSpec,
		resolver: PathResolver,
		policy: BackupPolicy
	) -> SessionsConfig? {
		guard let spec = surface.sessions,
			let header = spec.header,
			let template = surface.root,
			let root = try? resolver.expand(template)
		else { return nil }

		var indexURL: URL?
		if let index = spec.index, let url = try? resolver.expand(index.file) {
			indexURL = url
		}

		return SessionsConfig(
			root: root,
			recursive: spec.recursive ?? false,
			headerType: spec.headerType,
			headerScanLines: spec.headerScanLines,
			header: header,
			index: spec.index,
			indexURL: indexURL,
			message: spec.message,
			nameEntryType: spec.nameEntryType,
			policy: policy
		)
	}
}

public enum SessionsSurface {
	public static func files(config: SessionsConfig) -> [URL] {
		let fileManager = FileManager.default
		var out: [URL] = []

		func collect(_ directory: URL, depth: Int) {
			let entries = (try? fileManager.contentsOfDirectory(
				at: directory,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)) ?? []
			for entry in entries {
				var isDirectory: ObjCBool = false
				guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
				if isDirectory.boolValue {
					if config.recursive {
						// Codex nests by date: sessions/<year>/<month>/<day>/.
						if depth < 8 { collect(entry, depth: depth + 1) }
					} else if depth == 0 {
						// pi groups by working directory: sessions/<slug>/.
						collect(entry, depth: 1)
					}
					continue
				}
				guard entry.pathExtension.lowercased() == "jsonl" else { continue }
				// pi-desktop writes `<id>.revisions.jsonl` beside its sessions.
				if entry.lastPathComponent.hasSuffix(".revisions.jsonl") { continue }
				out.append(entry)
			}
		}

		collect(config.root, depth: 0)
		return out
	}

	/// Reads just the first line and pulls the declared fields out of it.
	public static func header(of url: URL, config: SessionsConfig) -> SessionHeader? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		// Codex's first line embeds the whole system prompt, so the header can be
		// far larger than pi's; read enough for it and no more.
		let data = (try? handle.read(upToCount: 4 << 20)) ?? Data()

		// Header fields are filled across the budgeted lines, first non-nil wins.
		//
		// pi and Codex put everything on line 1, so the default budget of 1 keeps
		// the old behaviour exactly. Claude Code has no header line at all: its
		// `sessionId` rides on every entry but `cwd` only appears on some, so the
		// id and the working directory can come from different lines.
		let budget = max(config.headerScanLines ?? 1, 1)
		var scanned = 0
		var id: String?
		var cwd: String?
		var startedAt: String?
		var parent: String?
		var model: String?

		for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
			guard scanned < budget else { break }
			scanned += 1
			guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
			if let expected = config.headerType, object["type"] as? String != expected { continue }
			if id == nil { id = JSONPath.string(in: object, path: config.header.id) }
			if cwd == nil { cwd = JSONPath.string(in: object, path: config.header.cwd) }
			if startedAt == nil { startedAt = JSONPath.string(in: object, path: config.header.timestamp) }
			if parent == nil { parent = JSONPath.string(in: object, path: config.header.parent) }
			if model == nil { model = JSONPath.string(in: object, path: config.header.model) }
		}

		guard let id else { return nil }
		return SessionHeader(
			id: id,
			cwd: cwd ?? "",
			started: startedAt.flatMap(ISO8601.date),
			parent: parent,
			model: model
		)
	}

	public struct SessionHeader {
		public let id: String
		public let cwd: String
		public let started: Date?
		public let parent: String?
		public let model: String?
	}

	public static func enumerate(config: SessionsConfig) -> [SessionRecord] {
		let names = loadIndex(config: config)
		var records: [SessionRecord] = []
		for url in files(config: config) {
			// A `.jsonl` file that parses but declares another type is a sidecar
			// (Codex keeps `session_index.jsonl` beside its sessions), not a
			// session. Files that do not parse at all are still listed, so a
			// damaged session is visible rather than silently hidden.
			if let expected = config.headerType, isOtherJSONLKind(url, expected: expected) { continue }
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
			let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
			let modified = (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
			let header = header(of: url, config: config)
			let identifier = header?.id ?? url.deletingPathExtension().lastPathComponent
			records.append(
				SessionRecord(
					url: url,
					fileSize: size,
					modified: modified,
					sessionID: identifier,
					cwd: header?.cwd ?? "",
					started: header?.started,
					parentSession: header?.parent,
					model: header?.model,
					name: names[identifier]
				)
			)
		}
		return records.sorted { $0.modified > $1.modified }
	}

	/// True when the first line is JSON that is not this agent's session header.
	///
	/// A sidecar like Codex's `session_index.jsonl` has no `type` at all, while a
	/// session header always declares one, so "absent" counts as "something else".
	/// A file that is not JSON is left alone: a damaged session should stay
	/// visible rather than silently disappear from the list.
	static func isOtherJSONLKind(_ url: URL, expected: String) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
		defer { try? handle.close() }
		let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
		guard let newline = data.firstIndex(of: 0x0A) else { return false }
		guard let object = try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline]) as? [String: Any]
		else { return false }
		return (object["type"] as? String) != expected
	}

	/// Reads the sidecar index of session id → display name, when declared.
	public static func loadIndex(config: SessionsConfig) -> [String: String] {
		guard let spec = config.index, let url = config.indexURL else { return [:] }
		var map: [String: String] = [:]
		JSONL.forEachLine(url) { line in
			guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
				let key = JSONPath.string(in: object, path: spec.key),
				let value = JSONPath.string(in: object, path: spec.value)
			else { return }
			map[key] = value
		}
		return map
	}

	/// Streams a session file and fills in the derived fields.
	///
	/// Reads in chunks rather than loading the file: Codex rollouts here reach
	/// 88 MB and this runs while the window is up.
	public static func summarize(_ record: inout SessionRecord, config: SessionsConfig) {
		guard let spec = config.message else {
			record.statsLoaded = true
			return
		}

		var messageCount = 0
		var tokens = 0
		var cost = 0.0
		var models: [String] = []
		var name: String?
		var firstUserText: String?
		var firstUserMessageSeen = false
		// Some agents report a running total instead of a per-message delta.
		var cumulativeTokens: Int?

		JSONL.forEachLine(record.url) { line in
			guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
			let type = object["type"] as? String

			if let nameEntryType = config.nameEntryType, type == nameEntryType {
				if let value = object["name"] as? String { name = value }
				return
			}

			if let usageEventType = spec.usageEventType, type == usageEventType {
				let event = JSONPath.object(in: object, path: spec.usageEventPayload) ?? object
				if let value = JSONPath.int(in: event, path: spec.usageEventTokens) {
					cumulativeTokens = value
				}
				return
			}

			guard spec.matches(type: type) else { return }
			messageCount += 1
			let message = JSONPath.object(in: object, path: spec.payload) ?? object

			if let model = JSONPath.string(in: message, path: "model"), !models.contains(model) {
				models.append(model)
			}
			if let usage = JSONPath.object(in: message, path: spec.usage) {
				// A comma-separated list is a sum: Claude Code reports input,
				// output and two cache counters separately.
				for path in (spec.tokens ?? "").split(separator: ",") {
					tokens += JSONPath.int(in: usage, path: path.trimmingCharacters(in: .whitespaces)) ?? 0
				}
				cost += JSONPath.double(in: usage, path: spec.cost ?? "") ?? 0
			}

			if !firstUserMessageSeen, JSONPath.string(in: message, path: spec.role) == "user" {
				guard let text = SessionText.summarize(JSONPath.value(in: message, path: spec.text)) else { return }
				// Wrapper messages (environment context, permission preamble) are
				// not what the user asked; keep looking for the real first prompt.
				if SessionText.isWrapper(text) { return }
				firstUserMessageSeen = true
				firstUserText = text
			}
		}

		record.messageCount = messageCount
		// A cumulative source must not be summed across events.
		record.totalTokens = cumulativeTokens ?? tokens
		record.totalCost = cost
		if let name { record.name = name }
		record.firstUserText = firstUserText
		record.models = models
		record.statsLoaded = true
	}

	/// The `id` of the last entry in the file, used as `parentId` when appending.
	public static func lastEntryID(of url: URL) -> String? {
		var last: String?
		JSONL.forEachLine(url) { line in
			guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
			if let id = object["id"] as? String { last = id }
		}
		return last
	}

	/// Appends a `session_info` entry, which is how pi's `/name` renames a session.
	///
	/// Only offered for agents whose descriptor declares `nameEntryType`; Codex
	/// keeps names in its own index and has no such entry.
	public static func appendingName(_ name: String, to url: URL, config: SessionsConfig) throws {
		guard let entryType = config.nameEntryType else {
			throw FileWriteError.io(L.t("session.error.cannotRename", "这个 agent 不支持通过追加记录重命名会话", table: .messages))
		}
		let parent = lastEntryID(of: url)
		let identifier = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
		var object: [String: Any] = [
			"type": entryType,
			"id": identifier,
			"parentId": parent as Any,
			"timestamp": ISO8601.string(Date()),
			"name": name,
		]
		if parent == nil { object["parentId"] = NSNull() }

		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		guard var text = String(data: data, encoding: .utf8) else {
			throw FileWriteError.io(String(format: L.t("session.error.encodeFailed", "无法编码 %@", table: .messages), entryType))
		}
		text += "\n"

		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(text.utf8))
		try handle.synchronize()
	}
}

/// Walks a dot-separated path through decoded JSON objects.
public enum JSONPath {
	public static func value(in object: Any, path: String?) -> Any? {
		guard let path, !path.isEmpty else { return object }
		var current: Any? = object
		for component in path.split(separator: ".") {
			guard let node = current else { return nil }
			if let dictionary = node as? [String: Any] {
				current = dictionary[String(component)]
			} else if let array = node as? [Any], let index = Int(component), array.indices.contains(index) {
				current = array[index]
			} else {
				return nil
			}
		}
		return current
	}

	public static func object(in object: Any, path: String?) -> [String: Any]? {
		value(in: object, path: path) as? [String: Any]
	}

	public static func string(in object: Any, path: String?) -> String? {
		value(in: object, path: path) as? String
	}

	public static func int(in object: Any, path: String?) -> Int? {
		(value(in: object, path: path) as? NSNumber)?.intValue
	}

	public static func double(in object: Any, path: String?) -> Double? {
		(value(in: object, path: path) as? NSNumber)?.doubleValue
	}
}

public enum ISO8601 {
	private static let fractional: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	private static let plain: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime]
		return formatter
	}()

	public static func date(_ text: String) -> Date? {
		fractional.date(from: text) ?? plain.date(from: text)
	}

	public static func string(_ date: Date) -> String {
		fractional.string(from: date)
	}
}

/// Chunked line iteration for JSONL files.
public enum JSONL {
	public static func forEachLine(_ url: URL, _ body: (Data) -> Void) {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return }
		defer { try? handle.close() }

		let chunkSize = 1 << 18
		var remainder = Data()
		while true {
			let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
			guard let chunk, !chunk.isEmpty else { break }
			remainder.append(chunk)
			while let newline = remainder.firstIndex(of: 0x0A) {
				let line = remainder[remainder.startIndex..<newline]
				if !line.isEmpty { body(Data(line)) }
				remainder.removeSubrange(remainder.startIndex...newline)
			}
		}
		if !remainder.isEmpty { body(remainder) }
	}
}

public enum SessionText {
	/// Reduces a message's content to one readable line.
	///
	/// Handles plain strings, pi's `{type: "text"}` blocks and Codex's
	/// `{type: "input_text" | "output_text"}` blocks.
	public static func summarize(_ content: Any?) -> String? {
		if let text = content as? String { return clean(text) }
		guard let blocks = content as? [[String: Any]] else { return nil }
		let parts = blocks.compactMap { block -> String? in
			block["text"] as? String
		}
		let joined = parts.joined(separator: " ")
		return joined.isEmpty ? nil : clean(joined)
	}

	/// True for the machine-written preambles agents inject before the user's
	/// own first message.
	static func isWrapper(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		return trimmed.hasPrefix("<") && trimmed.contains(">")
	}

	static func clean(_ text: String) -> String {
		let collapsed = text
			.replacingOccurrences(of: "\n", with: " ")
			.split(separator: " ", omittingEmptySubsequences: true)
			.joined(separator: " ")
		return collapsed.count > 160 ? String(collapsed.prefix(160)) + "…" : collapsed
	}
}

// MARK: - Cache

/// Caches the streaming pass so reopening the app does not re-read every file.
public struct SessionIndexCache {
	public struct Entry: Codable {
		public var size: Int
		public var modified: Double
		public var name: String?
		public var firstUserText: String?
		public var messageCount: Int
		public var totalTokens: Int
		public var totalCost: Double
		public var models: [String]
	}

	public var entries: [String: Entry] = [:]

	public static func load(from url: URL) -> SessionIndexCache {
		guard let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
		else { return SessionIndexCache() }
		return SessionIndexCache(entries: decoded)
	}

	public func save(to url: URL) {
		guard let data = try? JSONEncoder().encode(entries) else { return }
		try? FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try? data.write(to: url, options: .atomic)
	}

	public func apply(to record: inout SessionRecord) -> Bool {
		guard let entry = entries[record.url.path],
			entry.size == record.fileSize,
			abs(entry.modified - record.modified.timeIntervalSince1970) < 0.5
		else { return false }
		if let name = entry.name { record.name = name }
		record.firstUserText = entry.firstUserText
		record.messageCount = entry.messageCount
		record.totalTokens = entry.totalTokens
		record.totalCost = entry.totalCost
		record.models = entry.models
		record.statsLoaded = true
		return true
	}

	public mutating func store(_ record: SessionRecord) {
		entries[record.url.path] = Entry(
			size: record.fileSize,
			modified: record.modified.timeIntervalSince1970,
			name: record.name,
			firstUserText: record.firstUserText,
			messageCount: record.messageCount,
			totalTokens: record.totalTokens,
			totalCost: record.totalCost,
			models: record.models
		)
	}
}
