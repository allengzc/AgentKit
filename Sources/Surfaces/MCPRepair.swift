//
//  MCPRepair.swift
//  AgentKit
//
//  The one-click fix for a legacy MCP file.
//
//  Planned as a pure function so the exact set of steps the user is about to
//  approve can be asserted in the offline tests before it ever runs.
//

import Foundation

public struct MCPRepairPlan {
	public struct Step: Identifiable {
		public enum Kind: Equatable {
			case writeJSON
			case rename(to: URL)
		}

		public let id = UUID()
		public let title: String
		public let url: URL
		public let kind: Kind
		/// Nil for steps that only move a file.
		public let value: JSONValue?
		public let preview: FilePreview?
	}

	public let steps: [Step]
	public let notes: [String]

	public var isEmpty: Bool { steps.isEmpty }
}

public enum MCPRepair {
	/// Builds the steps that retire a file the adapter no longer reads.
	///
	/// - Parameters:
	///   - finding: the legacy file, as discovered by `MCPSurfaceLoader`.
	///   - includeServers: also merge the dead file's `mcpServers` into the
	///     effective shared layer. Off means those servers are simply reported.
	///   - sharedLayerURL: where to merge the servers, normally `~/.config/mcp/mcp.json`.
	public static func plan(
		finding: MCPLegacyFinding,
		includeServers: Bool,
		sharedLayerURL: URL?,
		policy: BackupPolicy,
		stamp: Date = Date()
	) -> MCPRepairPlan {
		var steps: [MCPRepairPlan.Step] = []
		var notes: [String] = []

		// The plan is computed from the bytes that were discovered, not by
		// re-reading the file, so what the user approves is exactly what runs.
		let legacyValue = (try? JSONParser.parse(finding.rawText))?.objectValue

		// 1. Adapter-only keys belong in the adapter config file.
		if !finding.adapterKeys.isEmpty, let target = finding.fixTarget, target != finding.url {
			let targetDocument = JSONFile.load(target, policy: policy)
			var merged = targetDocument.editableValue
			var carried: [String] = []
			for key in finding.adapterKeys {
				guard let value = legacyValue?[key] else { continue }
				merged.setValue(value, at: [key])
				carried.append(key)
			}
			let preview = JSONFile.preview(merged, for: targetDocument, policy: policy)
			steps.append(
				MCPRepairPlan.Step(
					title: String(
						format: L.t("mcp.repair.step.carryKeys", "把 %@ 迁到 %@", table: .messages),
						carried.joined(separator: L.t("list.separator", "、", table: .messages)),
						target.lastPathComponent
					),
					url: target,
					kind: .writeJSON,
					value: merged,
					preview: preview
				)
			)
		} else if !finding.adapterKeys.isEmpty {
			notes.append(
				String(
					format: L.t("mcp.repair.note.noTargetForKey", "描述文件没有给出这些键的去处，已跳过：%@", table: .messages),
					finding.adapterKeys.joined(separator: L.t("list.separator", "、", table: .messages))
				)
			)
		}

		// 2. The servers themselves belong in a layer that is actually read.
		if !finding.serverNames.isEmpty {
			if includeServers, let sharedLayerURL {
				let targetDocument = JSONFile.load(sharedLayerURL, policy: policy)
				var merged = targetDocument.editableValue
				var added: [String] = []
				var kept: [String] = []
				for name in finding.serverNames {
					guard let value = legacyValue?[finding.shape.serverKey]?.objectValue?[name] else { continue }
					if merged.value(at: [finding.shape.serverKey, name]) != nil {
						kept.append(name)
						continue
					}
					merged.setValue(value, at: [finding.shape.serverKey, name])
					added.append(name)
				}
				let preview = JSONFile.preview(merged, for: targetDocument, policy: policy)
				steps.append(
					MCPRepairPlan.Step(
						title: String(
							format: L.t("mcp.repair.step.mergeServers", "把 %d 个服务器并入 %@（合并时已存在的以目标文件为准）", table: .messages),
							added.count,
							sharedLayerURL.path
						),
						url: sharedLayerURL,
						kind: .writeJSON,
						value: merged,
						preview: preview
					)
				)
				if !kept.isEmpty {
					notes.append(
						String(
							format: L.t("mcp.repair.note.targetWins", "目标层里已有同名服务器，保留目标层的定义：%@", table: .messages),
							kept.joined(separator: L.t("list.separator", "、", table: .messages))
						)
					)
				}
			} else if !includeServers {
				notes.append(
					String(
						format: L.t("mcp.repair.note.serversNotMoved", "%d 个服务器（%@）不会被搬运，它们会随文件一起被重命名。", table: .messages),
						finding.serverNames.count,
						finding.serverNames.joined(separator: L.t("list.separator", "、", table: .messages))
					)
				)
			} else {
				notes.append(L.t("mcp.repair.note.noSharedLayer", "找不到可用的共享层，服务器不会被搬运。", table: .messages))
			}
		}

		// 3. Move the dead file aside, the way every other change is kept.
		let destination = renameDestination(for: finding.url, policy: policy, stamp: stamp)
		steps.append(
			MCPRepairPlan.Step(
				title: String(
					format: L.t("mcp.repair.step.rename", "把 %@ 重命名为 %@", table: .messages),
					finding.url.lastPathComponent,
					destination.lastPathComponent
				),
				url: finding.url,
				kind: .rename(to: destination),
				value: nil,
				preview: nil
			)
		)

		return MCPRepairPlan(steps: steps, notes: notes)
	}

	static func renameDestination(for url: URL, policy: BackupPolicy, stamp: Date) -> URL {
		let base = policy.backupURL(for: url, at: stamp)
		if !FileManager.default.fileExists(atPath: base.path) { return base }
		for index in 2...99 {
			let candidate = URL(fileURLWithPath: base.path + "-\(index)")
			if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
		}
		return URL(fileURLWithPath: base.path + "-\(UUID().uuidString.prefix(4))")
	}

	/// Executes a plan in order. Returns a per-step report.
	public struct Outcome {
		public var step: String
		public var succeeded: Bool
		public var detail: String
	}

	@discardableResult
	public static func run(
		_ plan: MCPRepairPlan,
		scope: PathResolver,
		policy: BackupPolicy
	) -> [Outcome] {
		var outcomes: [Outcome] = []
		for step in plan.steps {
			do {
				switch step.kind {
				case .writeJSON:
					guard let value = step.value else { continue }
					let document = JSONFile.load(step.url, policy: policy)
					_ = try JSONFile.write(value, document: document, scope: scope, policy: policy)
					outcomes.append(
						Outcome(
							step: step.title,
							succeeded: true,
							detail: L.t("mcp.repair.outcome.written", "已写入", table: .messages)
						)
					)
				case .rename(let destination):
					try FileManager.default.moveItem(at: step.url, to: destination)
					outcomes.append(Outcome(step: step.title, succeeded: true, detail: destination.lastPathComponent))
				}
			} catch {
				let detail = (error as? FileWriteError)?.description ?? error.localizedDescription
				outcomes.append(Outcome(step: step.title, succeeded: false, detail: detail))
				// Stop on the first failure: later steps assume earlier ones ran.
				break
			}
		}
		return outcomes
	}
}
