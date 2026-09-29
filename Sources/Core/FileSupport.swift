//
//  FileSupport.swift
//  AgentKit
//
//  The machinery every config mutation goes through: fingerprints for
//  detecting concurrent edits, atomic replacement, and timestamped sibling
//  backups that follow the naming convention already used in `~/.pi/agent`.
//

import Foundation
import CryptoKit

// MARK: - Fingerprint

public struct FileFingerprint: Equatable {
	public let size: Int
	public let modified: Date
	public let sha256: String

	public init(size: Int, modified: Date, sha256: String) {
		self.size = size
		self.modified = modified
		self.sha256 = sha256
	}

	public static func of(_ data: Data, at url: URL) -> FileFingerprint {
		let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
		let modified = (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
		let digest = SHA256.hash(data: data)
		let hex = digest.map { String(format: "%02x", $0) }.joined()
		return FileFingerprint(size: data.count, modified: modified, sha256: hex)
	}

	public var shortHash: String { String(sha256.prefix(7)) }
}

// MARK: - Text diff

/// A line-level diff, small enough to review in a sheet and good enough to
/// explain a single-key change without dragging in a diff library.
public struct TextDiff {
	public enum Kind {
		case equal
		case insert
		case remove
	}

	public struct Line {
		public let kind: Kind
		public let text: String
		public let oldNumber: Int?
		public let newNumber: Int?
	}

	public let lines: [Line]
	public let insertions: Int
	public let removals: Int

	public var isEmpty: Bool { insertions == 0 && removals == 0 }

	public init(before: String, after: String) {
		if before == after {
			self.lines = []
			self.insertions = 0
			self.removals = 0
			return
		}

		let oldLines = TextDiff.split(before)
		let newLines = TextDiff.split(after)
		let difference = newLines.difference(from: oldLines)

		var removedOld = Set<Int>()
		var insertedNew = Set<Int>()
		for change in difference {
			switch change {
			case .remove(let offset, _, _): removedOld.insert(offset)
			case .insert(let offset, _, _): insertedNew.insert(offset)
			}
		}

		var out: [Line] = []
		var insertCount = 0
		var removeCount = 0
		var i = 0
		var j = 0
		while i < oldLines.count || j < newLines.count {
			if i < oldLines.count, removedOld.contains(i) {
				out.append(Line(kind: .remove, text: oldLines[i], oldNumber: i + 1, newNumber: nil))
				removeCount += 1
				i += 1
				continue
			}
			if j < newLines.count, insertedNew.contains(j) {
				out.append(Line(kind: .insert, text: newLines[j], oldNumber: nil, newNumber: j + 1))
				insertCount += 1
				j += 1
				continue
			}
			if i < oldLines.count, j < newLines.count {
				out.append(Line(kind: .equal, text: oldLines[i], oldNumber: i + 1, newNumber: j + 1))
				i += 1
				j += 1
				continue
			}
			if i < oldLines.count {
				out.append(Line(kind: .remove, text: oldLines[i], oldNumber: i + 1, newNumber: nil))
				removeCount += 1
				i += 1
			} else {
				out.append(Line(kind: .insert, text: newLines[j], oldNumber: nil, newNumber: j + 1))
				insertCount += 1
				j += 1
			}
		}

		self.lines = out
		self.insertions = insertCount
		self.removals = removeCount
	}

	/// Collapses long runs of unchanged lines so the sheet stays readable.
	///
	/// A `nil` element marks elided lines, including at the head and tail, so
	/// the sheet never looks like the file simply starts at the change.
	public func condensed(context: Int = 3) -> [Line?] {
		guard !lines.isEmpty else { return [] }
		var keep = Set<Int>()
		for (index, line) in lines.enumerated() where line.kind != .equal {
			for offset in (index - context)...(index + context) where lines.indices.contains(offset) {
				keep.insert(offset)
			}
		}
		var out: [Line?] = []
		var lastKept: Int?
		for index in lines.indices where keep.contains(index) {
			if let lastKept {
				if index > lastKept + 1 { out.append(nil) }
			} else if index > 0 {
				out.append(nil)
			}
			out.append(lines[index])
			lastKept = index
		}
		if let lastKept, lastKept < lines.count - 1 { out.append(nil) }
		return out
	}

	static func split(_ text: String) -> [String] {
		text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
	}
}

// MARK: - Backups

public struct BackupPolicy {
	public var suffix: String
	public var keep: Int

	public init(suffix: String = ".bak-agentkit", keep: Int = 10) {
		self.suffix = suffix
		self.keep = keep
	}

	public static let `default` = BackupPolicy()

	public func backupURL(for url: URL, at date: Date = Date()) -> URL {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone.current
		formatter.dateFormat = "yyyyMMdd-HHmmss"
		let stamp = formatter.string(from: date)
		return url.deletingLastPathComponent()
			.appendingPathComponent(url.lastPathComponent + suffix + "-" + stamp)
	}

	public func existingBackups(for url: URL) -> [URL] {
		let directory = url.deletingLastPathComponent()
		let prefix = url.lastPathComponent + suffix + "-"
		let entries = (try? FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil
		)) ?? []
		return entries
			.filter { $0.lastPathComponent.hasPrefix(prefix) }
			.sorted { $0.lastPathComponent > $1.lastPathComponent }
	}
}

// MARK: - Preview / result

/// What a write would do, computed without touching disk.
public struct FilePreview {
	public let url: URL
	public let existed: Bool
	public let beforeText: String
	public let afterText: String
	public let diff: TextDiff
	public let backupURL: URL?
	/// True when producing `afterText` did not preserve the original formatting
	/// or comments, so the confirmation sheet can say so before writing.
	public var isLossy: Bool = false
	public var lossyNote: String?

	public var hasChanges: Bool { !diff.isEmpty }
}

public struct FileWriteResult {
	public let url: URL
	public let backupURL: URL?
}

// MARK: - Errors

public enum FileWriteError: Error, CustomStringConvertible {
	case concurrentModification(expected: String, actual: String)
	case malformedSource(String)
	case outsideScope(PathError)
	case io(String)

	public var description: String {
		switch self {
		case .concurrentModification(let expected, let actual):
			return String(
				format: L.t(
					"write.error.concurrent",
					"文件在读取之后被外部改动（读到时 %@，现在是 %@）。已中止写入，未丢失任何内容。",
					table: .messages
				),
				expected,
				actual
			)
		case .malformedSource(let path):
			return String(format: L.t("write.error.malformedSource", "%@ 的内容不合法，AgentKit 不会覆盖它。请先修复或用外部编辑器处理。", table: .messages), path)
		case .outsideScope(let error):
			return error.description
		case .io(let message):
			return String(format: L.t("write.error.io", "写入失败：%@", table: .messages), message)
		}
	}
}

// MARK: - Atomic writes

public enum AtomicFile {
	/// Replaces `url`'s contents in one step.
	///
	/// Writes a sibling temp file, fsyncs it, then `rename(2)`s over the target,
	/// so a crash or a full disk can never leave a half-written config file.
	/// The original file mode is preserved: `models.json` and `auth.json` are
	/// 0600 on this machine and must stay that way.
	@discardableResult
	public static func write(_ data: Data, to url: URL, mode: mode_t?) throws -> FileFingerprint {
		let directory = url.deletingLastPathComponent()
		let temporary = directory.appendingPathComponent(
			".\(url.lastPathComponent).agentkit-tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
		)

		let permissions = mode ?? 0o644
		let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, permissions)
		guard descriptor >= 0 else {
			throw FileWriteError.io(String(format: L.t("write.error.tempFile", "open(%@) 失败：%@", table: .messages), temporary.path, String(cString: strerror(errno))))
		}

		var failure: String?
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return }
			var written = 0
			while written < raw.count {
				let result = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
				if result <= 0 {
					failure = String(format: L.t("write.error.writeFailed", "write 失败：%@", table: .messages), String(cString: strerror(errno)))
					return
				}
				written += result
			}
		}
		if failure == nil, fsync(descriptor) != 0 {
			failure = String(format: L.t("write.error.fsyncFailed", "fsync 失败：%@", table: .messages), String(cString: strerror(errno)))
		}
		close(descriptor)

		if let failure {
			try? FileManager.default.removeItem(at: temporary)
			throw FileWriteError.io(failure)
		}

		// `rename` keeps the temp file's mode, which open() already set.
		guard rename(temporary.path, url.path) == 0 else {
			let message = String(cString: strerror(errno))
			try? FileManager.default.removeItem(at: temporary)
			throw FileWriteError.io(String(format: L.t("write.error.renameFailed", "rename 失败：%@", table: .messages), message))
		}

		// Flush the directory entry so the rename survives a power loss.
		let directoryDescriptor = open(directory.path, O_RDONLY)
		if directoryDescriptor >= 0 {
			fsync(directoryDescriptor)
			close(directoryDescriptor)
		}

		return FileFingerprint.of(data, at: url)
	}

	public static func mode(of url: URL) -> mode_t? {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			let number = attributes[.posixPermissions] as? NSNumber
		else { return nil }
		return mode_t(number.uint16Value)
	}

	/// Copies a file next to itself with a timestamp, then prunes old copies.
	@discardableResult
	public static func backup(_ url: URL, policy: BackupPolicy) throws -> URL? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		let destination = policy.backupURL(for: url)
		try? FileManager.default.removeItem(at: destination)
		do {
			try FileManager.default.copyItem(at: url, to: destination)
		} catch {
			throw FileWriteError.io(String(format: L.t("write.error.backupFailed", "备份到 %@ 失败：%@", table: .messages), destination.lastPathComponent, error.localizedDescription))
		}
		for stale in policy.existingBackups(for: url).dropFirst(max(policy.keep, 1)) {
			try? FileManager.default.removeItem(at: stale)
		}
		return destination
	}
}
