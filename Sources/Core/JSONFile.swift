//
//  JSONFile.swift
//  AgentKit
//
//  Load / preview / write for the JSON config files we do not own.
//
//  Two properties matter more than anything else here:
//    1. A file AgentKit cannot parse is never overwritten.
//    2. A file that changed since we read it is never overwritten blindly.
//

import Foundation

public enum FileStatus: Equatable {
	case ok
	case missing
	case malformed(String)
	case unreadable(String)

	public var isWritable: Bool {
		switch self {
		case .ok, .missing: return true
		case .malformed, .unreadable: return false
		}
	}
}

public final class JSONDocument {
	/// The path as the descriptor declared it.
	public let url: URL
	/// The path actually read/written, after following a symlink.
	public let realURL: URL
	public let isSymlink: Bool
	public let status: FileStatus
	public let rawText: String
	public let value: JSONValue?
	public let style: JSONStyle
	public let fingerprint: FileFingerprint?
	public let mode: mode_t?
	public let backups: [URL]
	/// Byte ranges of every value in `rawText`, for surgical edits.
	public let source: JSONSource?
	/// Which parser produced this document.
	public let format: ConfigFormat
	/// For TOML: the byte range of each table, so a structural edit can replace
	/// one table instead of rewriting the file.
	public let tableRanges: [String: Range<Int>]
	/// For TOML: whether the file has comments, which a rewrite would drop.
	public let hasComments: Bool

	public init(
		url: URL,
		realURL: URL,
		isSymlink: Bool,
		status: FileStatus,
		rawText: String,
		value: JSONValue?,
		style: JSONStyle,
		fingerprint: FileFingerprint?,
		mode: mode_t?,
		backups: [URL],
		source: JSONSource? = nil,
		format: ConfigFormat = .json,
		tableRanges: [String: Range<Int>] = [:],
		hasComments: Bool = false
	) {
		self.url = url
		self.realURL = realURL
		self.isSymlink = isSymlink
		self.status = status
		self.rawText = rawText
		self.value = value
		self.style = style
		self.fingerprint = fingerprint
		self.mode = mode
		self.backups = backups
		self.source = source
		self.format = format
		self.tableRanges = tableRanges
		self.hasComments = hasComments
	}

	public var exists: Bool {
		if case .missing = status { return false }
		return true
	}

	public var isMalformed: Bool {
		if case .malformed = status { return true }
		return false
	}

	/// The parse failure message, when there is one.
	public var malformedReason: String? {
		if case .malformed(let reason) = status { return reason }
		return nil
	}

	public var unreadableReason: String? {
		if case .unreadable(let reason) = status { return reason }
		return nil
	}

	/// A copy of the tree safe to mutate. Missing files start from `{}`.
	public var editableValue: JSONValue {
		value ?? .object(JSONObject())
	}

	public var objectValue: JSONObject {
		value?.objectValue ?? JSONObject()
	}

	public func value(at path: String) -> JSONValue? {
		guard let value else { return nil }
		return value.value(at: path.split(separator: ".").map(String.init))
	}

	public func value(at path: [String]) -> JSONValue? {
		value?.value(at: path)
	}
}

public enum JSONFile {
	public static func load(
		_ url: URL,
		policy: BackupPolicy = .default,
		format: ConfigFormat? = nil
	) -> JSONDocument {
		let resolvedFormat = ConfigFormat.detect(url: url, override: format?.rawValue)
		let realURL = PathResolver.writeTarget(for: url)
		let isSymlink = realURL != url
		let backups = policy.existingBackups(for: url)

		guard FileManager.default.fileExists(atPath: realURL.path) else {
			return JSONDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .missing,
				rawText: "",
				value: nil,
				style: .standard,
				fingerprint: nil,
				mode: nil,
				backups: backups
			)
		}

		let data: Data
		do {
			data = try Data(contentsOf: realURL)
		} catch {
			return JSONDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .unreadable(error.localizedDescription),
				rawText: "",
				value: nil,
				style: .standard,
				fingerprint: nil,
				mode: AtomicFile.mode(of: realURL),
				backups: backups
			)
		}

		let fingerprint = FileFingerprint.of(data, at: realURL)
		guard let text = JSONFile.decode(data) else {
			return JSONDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .unreadable("文件不是合法的 UTF-8"),
				rawText: "",
				value: nil,
				style: .standard,
				fingerprint: fingerprint,
				mode: AtomicFile.mode(of: realURL),
				backups: backups
			)
		}

		do {
			// Both parsers hand back the same four things, which is what lets the
			// rest of AgentKit stay format-agnostic.
			let parsedValue: JSONValue
			let parsedSource: JSONSource
			let parsedStyle: JSONStyle
			var tableRanges: [String: Range<Int>] = [:]
			var hasComments = false

			if resolvedFormat == .toml {
				let result = try TOMLParser.parseWithSource(text)
				parsedValue = result.value
				parsedSource = result.source
				parsedStyle = result.style
				tableRanges = result.tableRanges
				hasComments = result.hasComments
			} else {
				let result = try JSONParser.parseWithSource(text)
				parsedValue = result.value
				parsedSource = result.source
				parsedStyle = JSONStyle.detect(in: text)
			}

			return JSONDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .ok,
				rawText: text,
				value: parsedValue,
				style: parsedStyle,
				fingerprint: fingerprint,
				mode: AtomicFile.mode(of: realURL),
				backups: backups,
				source: parsedSource,
				format: resolvedFormat,
				tableRanges: tableRanges,
				hasComments: hasComments
			)
		} catch {
			let reason = (error as? JSONParseError)?.description ?? error.localizedDescription
			return JSONDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .malformed(reason),
				rawText: text,
				value: nil,
				style: JSONStyle.detect(in: text),
				fingerprint: fingerprint,
				mode: AtomicFile.mode(of: realURL),
				backups: backups
			)
		}
	}

	/// UTF-8 decode that strips a BOM and rejects invalid sequences instead of
	/// replacing them with U+FFFD (which would corrupt the file on write-back).
	static func decode(_ data: Data) -> String? {
		var bytes = data
		if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
			bytes = bytes.dropFirst(3)
		}
		return String(data: bytes, encoding: .utf8)
	}

	// MARK: - Writing

	public typealias Preview = FilePreview
	public typealias Result = FileWriteResult

	/// Serializes `value` with the document's own style and returns what the
	/// file would become, without touching disk.
	public static func preview(
		_ value: JSONValue,
		for document: JSONDocument,
		policy: BackupPolicy = .default
	) -> FilePreview {
		let rendered = ConfigPatch.render(value, from: document)
		let before = document.rawText
		return FilePreview(
			url: document.url,
			existed: document.exists,
			beforeText: before,
			afterText: rendered.text,
			diff: TextDiff(before: before, after: rendered.text),
			backupURL: document.exists ? policy.backupURL(for: document.url) : nil,
			isLossy: rendered.isLossy,
			lossyNote: rendered.note
		)
	}

	/// Writes `value` to `document`, refusing when the file moved under us.
	@discardableResult
	public static func write(
		_ value: JSONValue,
		document: JSONDocument,
		scope: PathResolver? = nil,
		policy: BackupPolicy = .default
	) throws -> FileWriteResult {
		guard document.status.isWritable else {
			throw FileWriteError.malformedSource(document.url.path)
		}

		if let scope {
			do {
				try scope.assertAllowed(document.realURL)
			} catch let error as PathError {
				throw FileWriteError.outsideScope(error)
			}
		}

		// Re-read immediately before writing: pi may have rewritten the file
		// while the user was editing the form.
		if let expected = document.fingerprint {
			guard FileManager.default.fileExists(atPath: document.realURL.path) else {
				throw FileWriteError.concurrentModification(expected: expected.shortHash, actual: "文件已被删除")
			}
			let current = (try? Data(contentsOf: document.realURL)) ?? Data()
			let actual = FileFingerprint.of(current, at: document.realURL)
			guard actual.sha256 == expected.sha256 else {
				throw FileWriteError.concurrentModification(expected: expected.shortHash, actual: actual.shortHash)
			}
		}

		var backupURL: URL?
		if document.exists {
			backupURL = try AtomicFile.backup(document.realURL, policy: policy)
		}

		let text = ConfigPatch.render(value, from: document).text
		guard let data = text.data(using: .utf8) else {
			throw FileWriteError.io("无法把内容编码成 UTF-8")
		}
		try AtomicFile.write(data, to: document.realURL, mode: document.mode)

		return FileWriteResult(url: document.realURL, backupURL: backupURL)
	}
}
