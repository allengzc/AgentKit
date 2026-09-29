//
//  TextFile.swift
//  AgentKit
//
//  Plain-text (Markdown) counterpart to JSONFile, with the same guarantees:
//  never overwrite something we could not read, never overwrite a file that
//  changed since we read it, always keep a timestamped sibling backup.
//

import Foundation

public final class TextDocument {
	public let url: URL
	public let realURL: URL
	public let isSymlink: Bool
	public let status: FileStatus
	public let text: String
	public let fingerprint: FileFingerprint?
	public let mode: mode_t?
	public let backups: [URL]

	public init(
		url: URL,
		realURL: URL,
		isSymlink: Bool,
		status: FileStatus,
		text: String,
		fingerprint: FileFingerprint?,
		mode: mode_t?,
		backups: [URL]
	) {
		self.url = url
		self.realURL = realURL
		self.isSymlink = isSymlink
		self.status = status
		self.text = text
		self.fingerprint = fingerprint
		self.mode = mode
		self.backups = backups
	}

	public var exists: Bool {
		if case .missing = status { return false }
		return true
	}

	public var isReadable: Bool {
		switch status {
		case .ok, .missing: return true
		case .malformed, .unreadable: return false
		}
	}

	public var problemReason: String? {
		switch status {
		case .malformed(let reason), .unreadable(let reason): return reason
		default: return nil
		}
	}

	public var frontmatter: FrontmatterDocument {
		FrontmatterDocument.parse(text)
	}

	public var lineCount: Int {
		text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
	}
}

public enum TextFile {
	public static func load(_ url: URL, policy: BackupPolicy = .default) -> TextDocument {
		let realURL = PathResolver.writeTarget(for: url)
		let isSymlink = realURL != url
		let backups = policy.existingBackups(for: url)

		guard FileManager.default.fileExists(atPath: realURL.path) else {
			return TextDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .missing,
				text: "",
				fingerprint: nil,
				mode: nil,
				backups: backups
			)
		}

		let data: Data
		do {
			data = try Data(contentsOf: realURL)
		} catch {
			return TextDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .unreadable(error.localizedDescription),
				text: "",
				fingerprint: nil,
				mode: AtomicFile.mode(of: realURL),
				backups: backups
			)
		}

		let fingerprint = FileFingerprint.of(data, at: realURL)
		guard let text = JSONFile.decode(data) else {
			return TextDocument(
				url: url,
				realURL: realURL,
				isSymlink: isSymlink,
				status: .unreadable(L.t("file.notUTF8", "文件不是合法的 UTF-8", table: .messages)),
				text: "",
				fingerprint: fingerprint,
				mode: AtomicFile.mode(of: realURL),
				backups: backups
			)
		}

		return TextDocument(
			url: url,
			realURL: realURL,
			isSymlink: isSymlink,
			status: .ok,
			text: text,
			fingerprint: fingerprint,
			mode: AtomicFile.mode(of: realURL),
			backups: backups
		)
	}

	public static func preview(_ text: String, for document: TextDocument, policy: BackupPolicy = .default) -> FilePreview {
		FilePreview(
			url: document.url,
			existed: document.exists,
			beforeText: document.text,
			afterText: text,
			diff: TextDiff(before: document.text, after: text),
			backupURL: document.exists ? policy.backupURL(for: document.url) : nil
		)
	}

	@discardableResult
	public static func write(
		_ text: String,
		document: TextDocument,
		scope: PathResolver? = nil,
		policy: BackupPolicy = .default
	) throws -> FileWriteResult {
		guard document.isReadable else {
			throw FileWriteError.malformedSource(document.url.path)
		}

		if let scope {
			do {
				try scope.assertAllowed(document.realURL)
			} catch let error as PathError {
				throw FileWriteError.outsideScope(error)
			}
		}

		if let expected = document.fingerprint {
			guard FileManager.default.fileExists(atPath: document.realURL.path) else {
				throw FileWriteError.concurrentModification(expected: expected.shortHash, actual: L.t("file.deleted", "文件已被删除", table: .messages))
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

		guard let data = text.data(using: .utf8) else {
			throw FileWriteError.io(L.t("write.error.encodeUTF8", "无法把内容编码成 UTF-8", table: .messages))
		}
		try AtomicFile.write(data, to: document.realURL, mode: document.mode)
		return FileWriteResult(url: document.realURL, backupURL: backupURL)
	}

	/// Trashes rather than unlinks, so a mistake stays recoverable.
	public static func trash(_ url: URL) throws {
		var resulting: NSURL?
		do {
			try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
		} catch {
			throw FileWriteError.io(String(format: L.t("write.error.trashFailed", "移到废纸篓失败：%@", table: .messages), error.localizedDescription))
		}
	}
}
