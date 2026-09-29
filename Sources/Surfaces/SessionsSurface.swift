//
//  SessionsSurface.swift
//  AgentKit
//
//  Reading pi's session files.
//
//  Sessions are JSONL with one `session` header line followed by a tree of
//  entries. Only the header is needed to list a session, so the list is filled
//  from the first line of each file; the message count, token and cost totals
//  come from a separate streaming pass that is cached by (size, mtime).
//
//  These are read with `JSONSerialization` rather than AgentKit's own parser:
//  nothing here is written back, so round-trip fidelity is irrelevant and the
//  C parser is far faster on multi-megabyte files.
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
		let url = URL(fileURLWithPath: cwd)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}
}

public enum SessionsSurface {
	public static func files(root: URL) -> [URL] {
		let fileManager = FileManager.default
		guard let groups = try? fileManager.contentsOfDirectory(
			at: root,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else { return [] }

		var out: [URL] = []
		for group in groups {
			var isDirectory: ObjCBool = false
			guard fileManager.fileExists(atPath: group.path, isDirectory: &isDirectory),
				isDirectory.boolValue
			else { continue }
			let files = (try? fileManager.contentsOfDirectory(
				at: group,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)) ?? []
			for file in files where file.pathExtension.lowercased() == "jsonl" {
				// pi-desktop writes `<id>.revisions.jsonl` alongside its sessions.
				if file.lastPathComponent.hasSuffix(".revisions.jsonl") { continue }
				out.append(file)
			}
		}
		return out
	}

	/// Reads just the header line of a session file.
	public static func header(of url: URL) -> (sessionID: String, cwd: String, started: Date?, parent: String?)? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
		guard let newline = data.firstIndex(of: 0x0A) else { return nil }
		let line = data[data.startIndex..<newline]
		guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
			let id = object["id"] as? String
		else { return nil }
		let timestamp = (object["timestamp"] as? String).flatMap(ISO8601.date)
		return (id, object["cwd"] as? String ?? "", timestamp, object["parentSession"] as? String)
	}

	public static func enumerate(root: URL) -> [SessionRecord] {
		var records: [SessionRecord] = []
		for url in files(root: root) {
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
			let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
			let modified = (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
			let header = header(of: url)
			records.append(
				SessionRecord(
					url: url,
					fileSize: size,
					modified: modified,
					sessionID: header?.sessionID ?? url.deletingPathExtension().lastPathComponent,
					cwd: header?.cwd ?? "",
					started: header?.started,
					parentSession: header?.parent
				)
			)
		}
		return records.sorted { $0.modified > $1.modified }
	}

	/// Streams a session file and fills in the derived fields.
	///
	/// Reads in chunks rather than loading the file: some sessions are tens of
	/// megabytes and this runs while the window is up.
	public static func summarize(_ record: inout SessionRecord) {
		var messageCount = 0
		var tokens = 0
		var cost = 0.0
		var name: String?
		var firstUserText: String?
		var models: [String] = []
		var firstUserMessageSeen = false

		JSONL.forEachLine(record.url) { line in
			guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
			switch object["type"] as? String {
			case "session_info":
				if let value = object["name"] as? String { name = value }
			case "message":
				messageCount += 1
				guard let message = object["message"] as? [String: Any] else { return }
				if let model = message["model"] as? String, !models.contains(model) {
					models.append(model)
				}
				if let usage = message["usage"] as? [String: Any] {
					tokens += (usage["totalTokens"] as? NSNumber)?.intValue ?? 0
					if let costObject = usage["cost"] as? [String: Any] {
						cost += (costObject["total"] as? NSNumber)?.doubleValue ?? 0
					}
				}
				if !firstUserMessageSeen, message["role"] as? String == "user" {
					firstUserMessageSeen = true
					firstUserText = SessionText.summarize(message["content"])
				}
			default:
				break
			}
		}

		record.messageCount = messageCount
		record.totalTokens = tokens
		record.totalCost = cost
		record.name = name
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

	/// Appends a `session_info` entry, which is how `/name` renames a session.
	public static func appendingName(_ name: String, to url: URL) throws {
		let parent = lastEntryID(of: url)
		let identifier = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
		var object: [String: Any] = [
			"type": "session_info",
			"id": identifier,
			"parentId": parent as Any,
			"timestamp": ISO8601.string(Date()),
			"name": name,
		]
		if parent == nil { object["parentId"] = NSNull() }

		let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		guard var text = String(data: data, encoding: .utf8) else {
			throw FileWriteError.io("无法编码 session_info")
		}
		text += "\n"

		let handle = try FileHandle(forWritingTo: url)
		defer { try? handle.close() }
		try handle.seekToEnd()
		try handle.write(contentsOf: Data(text.utf8))
		try handle.synchronize()
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
	public static func summarize(_ content: Any?) -> String? {
		if let text = content as? String { return clean(text) }
		guard let blocks = content as? [[String: Any]] else { return nil }
		let parts = blocks.compactMap { block -> String? in
			guard block["type"] as? String == "text" else { return nil }
			return block["text"] as? String
		}
		let joined = parts.joined(separator: " ")
		return joined.isEmpty ? nil : clean(joined)
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
		record.name = entry.name
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
