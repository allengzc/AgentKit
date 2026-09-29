//
//  JSONEditController.swift
//  AgentKit
//
//  The single write path for every pane.
//
//  Keeping this in one place is the point: whichever surface a mutation comes
//  from, it goes through the same load → diff → confirm → atomic write →
//  backup sequence, with the same refusal rules.
//

import Foundation
import Observation

@MainActor
@Observable
public final class JSONEditController {
	public struct Pending: Identifiable {
		public let id = UUID()
		public let preview: FilePreview
		public let value: JSONValue
		public let note: String?
		let document: JSONDocument
		let policy: BackupPolicy
		let resolver: PathResolver
	}

	public private(set) var document: JSONDocument?
	public var pending: Pending?
	public var banner: String?
	public var errorText: String?
	public private(set) var url: URL?
	public private(set) var loading = false

	private var policy: BackupPolicy = .default
	private var resolver: PathResolver?

	public init() {}

	public var exists: Bool { document?.exists ?? false }

	public var isMalformed: Bool { document?.isMalformed ?? false }

	public var malformedReason: String? { document?.malformedReason }

	public var editable: JSONValue { document?.editableValue ?? .object(JSONObject()) }

	/// Reads the file. Safe to call repeatedly; keeps `url` when it fails.
	public func load(url: URL, resolver: PathResolver, policy: BackupPolicy) {
		self.url = url
		self.resolver = resolver
		self.policy = policy
		loading = true
		let loaded = JSONFile.load(url, policy: policy)
		document = loaded
		loading = false
		if loaded.isMalformed {
			errorText = nil
		}
	}

	public func reload() {
		guard let url, let resolver else { return }
		load(url: url, resolver: resolver, policy: policy)
	}

	public func clearMessages() {
		banner = nil
		errorText = nil
	}

	/// Stages a write. Returns false when there is nothing to do.
	@discardableResult
	public func stage(
		_ value: JSONValue,
		note: String? = nil,
		title: String? = nil
	) -> Bool {
		guard let document, let resolver else { return false }
		_ = title
		let preview = JSONFile.preview(value, for: document, policy: policy)
		guard preview.hasChanges else {
			banner = "没有需要写入的改动"
			return false
		}
		pending = Pending(
			preview: preview,
			value: value,
			note: note,
			document: document,
			policy: policy,
			resolver: resolver
		)
		return true
	}

	public func cancel() {
		pending = nil
	}

	public func confirm() {
		guard let pending else { return }
		do {
			let result = try JSONFile.write(
				pending.value,
				document: pending.document,
				scope: pending.resolver,
				policy: pending.policy
			)
			self.pending = nil
			let reloaded = JSONFile.load(result.url, policy: pending.policy)
			document = reloaded
			let backupName = result.backupURL?.lastPathComponent
			banner = backupName.map { "已写入，备份 \($0)" } ?? "已写入 \(result.url.path)"
			errorText = nil
		} catch {
			self.pending = nil
			banner = nil
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	/// Trash a file this controller points at, keeping the controller in sync.
	public func trash() throws {
		guard let document else { return }
		try TextFile.trash(document.realURL)
		reload()
	}

	// MARK: - Convenience mutations

	/// Applies a mutation to the current tree and stages the result.
	@discardableResult
	public func mutate(_ body: (inout JSONValue) -> Void) -> Bool {
		var value = editable
		body(&value)
		return stage(value)
	}
}
