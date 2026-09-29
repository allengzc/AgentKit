//
//  MCPSurface.swift
//  AgentKit
//
//  Reading and reasoning about MCP configuration.
//
//  MCP config for pi is not one file. The adapter reads up to six layers with
//  a defined precedence, and this machine still has a `~/.pi/agent/mcp.json`
//  that the adapter stopped reading — so the surface has to show provenance,
//  resolve conflicts, and point out files that look configured but are dead.
//

import Foundation

/// How one agent spells "this server is off".
///
/// pi writes `disabled = true`; Codex writes `enabled = false`. Same idea, two
/// conventions, so the polarity is data rather than an assumption.
public struct MCPServerShape: Equatable {
	public var serverKey: String
	public var toggleKey: String?
	/// The value of `toggleKey` that means the server is disabled.
	public var toggleDisabledValue: Bool

	public init(serverKey: String = "mcpServers", toggleKey: String? = "disabled", toggleDisabledValue: Bool = true) {
		self.serverKey = serverKey
		self.toggleKey = toggleKey
		self.toggleDisabledValue = toggleDisabledValue
	}

	public static let pi = MCPServerShape()

	public static func resolve(_ surface: SurfaceSpec) -> MCPServerShape {
		MCPServerShape(
			serverKey: surface.serverKey ?? "mcpServers",
			toggleKey: surface.toggleKey ?? "disabled",
			toggleDisabledValue: surface.toggleDisabledValue ?? true
		)
	}

	public func isDisabled(_ value: JSONValue) -> Bool {
		guard let toggleKey else { return false }
		guard let flag = value.value(at: [toggleKey])?.boolValue else { return false }
		return flag == toggleDisabledValue
	}

	/// Sets the toggle, removing the key when it would just restate the default.
	public func setDisabled(_ disabled: Bool, in value: inout JSONValue) {
		guard let toggleKey else { return }
		value.setValue(.bool(disabled ? toggleDisabledValue : !toggleDisabledValue), at: [toggleKey])
	}
}

public struct MCPServerEntry: Identifiable {
	public enum Provenance: String {
		case layer
		case imported
		case legacy
	}

	public let name: String
	public let value: JSONValue
	public let layer: MCPLayer?
	public let provenance: Provenance
	public let sourceDescription: String
	public let isDisabled: Bool

	public var id: String { "\(provenance.rawValue)|\(layer?.url.path ?? "-")|\(name)" }

	public var transport: String {
		MCPShape.transport(value)
	}

	public var summary: String {
		MCPShape.summary(value)
	}
}

public struct MCPLayer: Identifiable {
	public let spec: ConfigSource
	public let url: URL
	public let document: JSONDocument
	public let serverNames: [String]
	public let shape: MCPServerShape

	public var id: String { url.path }
	public var exists: Bool { document.exists }
	public var isWritable: Bool { spec.isWritable }
	public var isProjectScoped: Bool { spec.isProjectScoped }
	public var isShared: Bool { spec.isShared }
	public var malformedReason: String? { document.malformedReason }

	public var servers: [MCPServerEntry] {
		serverNames.compactMap { name in
			guard let value = document.value(at: ["mcpServers", name]) else { return nil }
			return MCPServerEntry(
				name: name,
				value: value,
				layer: self,
				provenance: .layer,
				sourceDescription: url.path,
				isDisabled: shape.isDisabled(value)
			)
		}
	}
}

public struct MCPImportCandidate: Identifiable {
	public let kind: String
	public let url: URL
	public let exists: Bool
	public let serverCount: Int
	public let note: String?

	public var id: String { "\(kind)|\(url.path)" }
}

public struct MCPLegacyFinding: Identifiable {
	public let url: URL
	public let notice: String
	public let serverNames: [String]
	public let adapterKeys: [String]
	public let rawText: String
	public let fixTarget: URL?
	public let shape: MCPServerShape

	public init(
		url: URL,
		notice: String,
		serverNames: [String],
		adapterKeys: [String],
		rawText: String,
		fixTarget: URL?,
		shape: MCPServerShape = .pi
	) {
		self.url = url
		self.notice = notice
		self.serverNames = serverNames
		self.adapterKeys = adapterKeys
		self.rawText = rawText
		self.fixTarget = fixTarget
		self.shape = shape
	}

	public var id: String { url.path }
	public var hasAnything: Bool { !serverNames.isEmpty || !adapterKeys.isEmpty }
}

public struct MCPConflict: Identifiable {
	public let name: String
	public let contenders: [MCPLayer]
	public let winner: MCPLayer

	public var id: String { name }
}

public struct MCPEffective: Identifiable {
	public let name: String
	public let winner: MCPLayer
	public let shadowed: [MCPLayer]
	public let value: JSONValue
	public let isDisabled: Bool

	public var id: String { name }
	public var isShadowed: Bool { !shadowed.isEmpty }
}

public struct MCPSnapshot {
	public var shape: MCPServerShape = .pi
	public var layers: [MCPLayer] = []
	public var imports: [MCPImportCandidate] = []
	public var legacy: [MCPLegacyFinding] = []
	public var effective: [MCPEffective] = []
	public var conflicts: [MCPConflict] = []

	public var allServerNames: [String] { effective.map(\.name) }
	public var writableLayers: [MCPLayer] { layers.filter { $0.isWritable } }
	public var problemCount: Int {
		conflicts.count + legacy.filter(\.hasAnything).count + layers.filter { $0.malformedReason != nil }.count
	}
}

public enum MCPShape {
	public static func transport(_ value: JSONValue) -> String {
		if value.value(at: ["url"])?.stringValue != nil { return "远程" }
		if value.value(at: ["command"])?.stringValue != nil { return "stdio" }
		return "未知"
	}

	public static func summary(_ value: JSONValue) -> String {
		if let url = value.value(at: ["url"])?.stringValue { return url }
		if let command = value.value(at: ["command"])?.stringValue {
			let args = value.value(at: ["args"])?.stringsValue ?? []
			return ([command] + args).joined(separator: " ")
		}
		return "—"
	}

	public static func serverNames(in document: JSONDocument, shape: MCPServerShape = .pi) -> [String] {
		document.value(at: [shape.serverKey])?.objectValue?.keys ?? []
	}

	/// The fields the server form owns. Everything else in an entry is left alone.
	public struct MCPServerDraft: Equatable {
		public var command: String
		public var args: [String]
		public var url: String
		public var disabled: Bool

		public init(command: String = "", args: [String] = [], url: String = "", disabled: Bool = false) {
			self.command = command
			self.args = args
			self.url = url
			self.disabled = disabled
		}
	}

	/// Applies the form onto an existing entry, merging rather than replacing.
	///
	/// A server entry can carry `env`, `cwd`, `type`, `startup_timeout_sec`,
	/// `http_headers` and keys AgentKit has never heard of. Rebuilding the object
	/// from the form alone would silently delete every one of them — so the form
	/// only ever touches the four fields it displays.
	public static func mergedServer(
		existing: JSONValue?,
		draft: MCPServerDraft,
		shape: MCPServerShape
	) -> JSONValue {
		var object = existing?.objectValue ?? JSONObject()
		let url = draft.url.trimmingCharacters(in: .whitespaces)
		let command = draft.command.trimmingCharacters(in: .whitespaces)

		if url.isEmpty {
			object["command"] = .string(command)
			// Keep `args` when there is something to say, or when the file already
			// had the key. Adding `args = []` to an entry that never had one is a
			// change the user did not ask for.
			if !draft.args.isEmpty || object["args"] != nil {
				object["args"] = .array(draft.args.map { .string($0) })
			}
			_ = object.removeValue(forKey: "url")
		} else {
			object["url"] = .string(url)
			_ = object.removeValue(forKey: "command")
			_ = object.removeValue(forKey: "args")
		}

		if let toggleKey = shape.toggleKey {
			if draft.disabled {
				object[toggleKey] = .bool(shape.toggleDisabledValue)
			} else {
				// Absence is the enabled state for both pi and Codex, so writing
				// the key back just to say "on" would be noise.
				_ = object.removeValue(forKey: toggleKey)
			}
		}

		return .object(object)
	}

	/// Empty server template, in the shape the adapter expects.
	public static func emptyServer(remote: Bool) -> JSONValue {
		remote
			? .object(JSONObject([("url", .string(""))]))
			: .object(JSONObject([("command", .string("")), ("args", .array([]))]))
	}

	public static func validate(name: String, value: JSONValue) -> String? {
		if name.trimmingCharacters(in: .whitespaces).isEmpty { return "名字不能为空" }
		if name.contains("/") { return "名字里不能有斜杠" }
		let hasCommand = value.value(at: ["command"])?.stringValue?.isEmpty == false
		let hasURL = value.value(at: ["url"])?.stringValue?.isEmpty == false
		if !hasCommand && !hasURL { return "需要 command（本地）或 url（远程）之一" }
		if hasCommand && hasURL { return "command 与 url 只能有一个" }
		let args = value.value(at: ["args"])
		if let args, args.arrayValue == nil { return "args 必须是数组" }
		let env = value.value(at: ["env"])
		if let env, env.objectValue == nil { return "env 必须是对象" }
		return nil
	}
}

public enum MCPSurfaceLoader {
	public static func snapshot(
		surface: SurfaceSpec,
		resolver: PathResolver,
		policy: BackupPolicy
	) -> MCPSnapshot {
		var snapshot = MCPSnapshot()
		let shape = MCPServerShape.resolve(surface)
		snapshot.shape = shape

		// 1. Every declared layer, in precedence order.
		let ordered = (surface.layers ?? []).sorted { $0.precedence < $1.precedence }
		for spec in ordered {
			guard let url = try? resolver.expand(spec.path) else { continue }
			let document = JSONFile.load(
				url,
				policy: policy,
				format: spec.format.flatMap(ConfigFormat.init(rawValue:))
			)
			snapshot.layers.append(
				MCPLayer(
					spec: spec,
					url: url,
					document: document,
					serverNames: MCPShape.serverNames(in: document, shape: shape),
					shape: shape
				)
			)
		}

		// 2. Which layer wins each server name. Later layers win.
		var winners: [String: MCPLayer] = [:]
		for layer in snapshot.layers {
			guard layer.malformedReason == nil else { continue }
			for name in layer.serverNames { winners[name] = layer }
		}
		for name in winners.keys.sorted() {
			guard let winner = winners[name] else { continue }
			let shadowed = snapshot.layers.filter { $0.serverNames.contains(name) && $0.id != winner.id }
			let value = winner.document.value(at: [shape.serverKey, name]) ?? .null
			snapshot.effective.append(
				MCPEffective(
					name: name,
					winner: winner,
					shadowed: shadowed,
					value: value,
					isDisabled: shape.isDisabled(value)
				)
			)
			if !shadowed.isEmpty {
				snapshot.conflicts.append(
					MCPConflict(name: name, contenders: shadowed + [winner], winner: winner)
				)
			}
		}

		// 3. Host configs the adapter can import from.
		for (kind, templates) in (surface.imports ?? [:]).sorted(by: { $0.key < $1.key }) {
			for template in templates {
				guard let url = try? resolver.expand(template) else { continue }
				let exists = FileManager.default.fileExists(atPath: url.path)
				let count: Int
				var note: String?
				if url.pathExtension.lowercased() == "toml" {
					count = 0
					note = exists ? "TOML 格式，AgentKit 只做存在性检查" : nil
				} else {
					let document = JSONFile.load(url, policy: policy)
					count = MCPShape.serverNames(in: document, shape: shape).count
				}
				snapshot.imports.append(
					MCPImportCandidate(kind: kind, url: url, exists: exists, serverCount: count, note: note)
				)
			}
		}

		// 4. Files that look authoritative but are no longer read.
		for legacy in surface.legacy ?? [] {
			guard let url = try? resolver.expand(legacy.path) else { continue }
			let document = JSONFile.load(url, policy: policy)
			guard document.exists, document.malformedReason == nil else { continue }
			let servers = MCPShape.serverNames(in: document, shape: shape)
			let adapterKeys = ["settings", "imports", "claudePlugins", "mcp-servers"]
				.filter { document.value(at: [$0]) != nil }
			let target = legacy.fix?.to.flatMap { try? resolver.expand($0) }
			snapshot.legacy.append(
				MCPLegacyFinding(
					url: url,
					notice: legacy.notice ?? "这个文件已经不会被读取。",
					serverNames: servers,
					adapterKeys: adapterKeys,
					rawText: document.rawText,
					fixTarget: target,
					shape: shape
				)
			)
		}

		return snapshot
	}
}
