//
//  Descriptor.swift
//  AgentKit
//
//  The agent descriptor: one JSON file describes where an agent keeps its
//  model list, MCP servers, skills, sessions, instructions, sub-agents,
//  settings and resources. Adding support for a new agent is adding a file.
//
//  Descriptors are data; the `kind` of each surface selects one of a small,
//  closed set of handlers. A descriptor that names a kind this build does not
//  implement degrades to a placeholder instead of failing to load.
//

import Foundation

// MARK: - Surfaces

public enum SurfaceKind: Equatable, CustomStringConvertible {
	case models
	case mcp
	case skills
	case sessions
	case instructions
	case subagents
	case settings
	case resources
	case unsupported(String)

	public init(rawValue: String) {
		switch rawValue {
		case "models": self = .models
		case "mcp": self = .mcp
		case "skills": self = .skills
		case "sessions": self = .sessions
		case "instructions": self = .instructions
		case "subagents": self = .subagents
		case "settings": self = .settings
		case "resources": self = .resources
		default: self = .unsupported(rawValue)
		}
	}

	public var rawValue: String {
		switch self {
		case .models: return "models"
		case .mcp: return "mcp"
		case .skills: return "skills"
		case .sessions: return "sessions"
		case .instructions: return "instructions"
		case .subagents: return "subagents"
		case .settings: return "settings"
		case .resources: return "resources"
		case .unsupported(let raw): return raw
		}
	}

	public var description: String { rawValue }
}

extension SurfaceKind: Codable {
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		self.init(rawValue: try container.decode(String.self))
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

// MARK: - Supporting specs

public struct CLISpec: Codable {
	public var name: String
	public var candidates: [String]?
	public var package: String?
	public var loginShellLookup: Bool?
	public var versionArgs: [String]?
	public var authCheckArgs: [String]?
}

public struct BackupSpec: Codable {
	public var suffix: String?
	public var keep: Int?
}

public struct WriteSpec: Codable {
	public var backup: BackupSpec?
	public var scopeGuard: [String]?
	public var allowOutsideHome: Bool?
}

public struct RootSpec: Codable {
	public var env: String?
	public var `default`: String
}

public struct ProjectsSpec: Codable {
	public var trustFile: String?
	public var sources: [String]?
}

public struct DetectSpec: Codable {
	public var paths: [String]?
	public var cli: CLISpec?
}

/// A directory a surface reads from or writes to.
public struct RootEntry: Codable {
	public var path: String
	public var scope: String?
	public var writable: Bool?
	public var shared: Bool?
	public var type: String?

	public var isProjectScoped: Bool { scope == "project" }
	public var isWritable: Bool { writable ?? true }
}

extension SurfaceSpec {
	/// The title in the language in effect right now.
	public var titleText: String { title.current }
}

/// One layer of an MCP-style stacked configuration.
public struct ConfigSource: Codable {
	public var path: String
	public var scope: String?
	public var precedence: Int
	public var shared: Bool?
	public var writable: Bool?
	/// Overrides the parser chosen from the file extension.
	public var format: String? = nil
	/// A per-language sentence about this layer, for a descriptor that has to say
	/// more than the path does. Optional and defaulted, so a descriptor written
	/// before this key existed still loads: `~/.claude.json` carries a long note
	/// because every `claude` run rewrites it, and the pane would otherwise show
	/// the same Chinese sentence in English mode.
	public var note: LocalizedText? = nil

	public var isProjectScoped: Bool { scope == "project" }
	public var isWritable: Bool { writable ?? true }
	public var isShared: Bool { shared ?? false }
}

public struct LegacyFixSpec: Codable {
	/// Currently only `"rename"`: relocate a file that is no longer read.
	public var action: String
	public var to: String?
	public var onlyKeys: [String]?
}

public struct LegacySpec: Codable {
	public var path: String
	public var notice: LocalizedText?
	public var fix: LegacyFixSpec?
}

public struct InstructionFileSpec: Codable {
	public var path: String
	public var role: String?
	public var precedence: Int?
}

public struct DiscoverySpec: Codable {
	public var filenames: [String]?
	public var walkUpFromCwd: Bool?
}

public struct FrontmatterSpec: Codable {
	public var required: [String]?
	public var fields: [String]?
}

/// Where a session's fields live inside its first JSONL line.
///
/// pi puts them at the top level; Codex nests them under `payload`. Paths are
/// dot-separated and may point anywhere in the object.
public struct SessionHeaderPaths: Codable {
	public var id: String
	public var cwd: String?
	public var timestamp: String?
	public var parent: String?
	public var model: String?
}

/// A sidecar file that maps a session id to a display name.
public struct SessionIndexSpec: Codable {
	public var file: String
	public var key: String
	public var value: String
}

/// How to find messages and usage inside a session entry.
public struct SessionMessageSpec: Codable {
	/// The entry type that carries a message. Optional because an agent may use
	/// several (`types`) instead of one.
	public var type: String?
	/// Every entry type that carries a message.
	///
	/// pi and Codex write one (`message`, `response_item`); Claude Code writes
	/// both `user` and `assistant` entries, and a spec that could only name one
	/// of them would either lose the user's first prompt or lose the token counts.
	public var types: [String]?

	/// True when this line's `type` is a message for this agent.
	public func matches(type entryType: String?) -> Bool {
		if let types { return entryType.map(types.contains) ?? false }
		return entryType == type
	}
	/// Dotted path to the message object; nil means the entry itself is it.
	public var payload: String?
	public var role: String?
	public var text: String?
	/// Path (inside the message) to a `usage` object, and the fields worth reading.
	public var usage: String?
	/// Path to a token count. A comma-separated list is summed, because agents
	/// report totals differently: pi writes one number, Claude Code splits it into
	/// input, output and two cache counters.
	public var tokens: String?
	public var cost: String?
	/// Some agents record usage on a separate event carrying a running total.
	public var usageEventType: String?
	public var usageEventPayload: String?
	public var usageEventTokens: String?
}

public struct SessionsSpec: Codable {
	/// Walk every directory under the root rather than exactly one level.
	public var recursive: Bool?
	public var headerType: String?
	/// How many leading lines to search for the header. Defaults to 1.
	///
	/// pi and Codex put it on the first line; Claude Code has no header line at
	/// all, and its `sessionId` and `cwd` ride along on whichever entry happens to
	/// be first, which may be an attachment or a queue operation.
	public var headerScanLines: Int?
	/// Entry type that renames the session inline (pi's `session_info`).
	public var nameEntryType: String?
	public var header: SessionHeaderPaths?
	public var index: SessionIndexSpec?
	public var message: SessionMessageSpec?
}

/// Field names inside a provider entry.
///
/// pi writes `baseUrl` / `api` / `apiKey`; Codex writes `base_url` / `wire_api` /
/// `env_key`. The pane is the same either way, so the spelling is data.
public struct ModelProviderKeys: Codable {
	public var name: String?
	public var baseUrl: String?
	public var api: String?
	public var apiKey: String?
	public var models: String?

	public static let pi = ModelProviderKeys(
		name: "name", baseUrl: "baseUrl", api: "api", apiKey: "apiKey", models: "models"
	)
}

/// A reference to a value inside another file, e.g. `settings.json` → `defaultModel`.
public struct PointerRef: Codable {
	public var file: String
	public var path: String
}

public struct SurfaceSpec: Codable {
	public var id: String
	public var kind: SurfaceKind
	/// Per-language. A plain string means the same in every language, which is
	/// what a hand-written descriptor contains.
	public var title: LocalizedText
	public var icon: String?
	public var shape: String?

	// Single-file surfaces
	public var file: String?
	public var providerFile: String?
	public var catalogFile: String?
	public var authFile: String?

	// Directory surfaces
	public var root: String?
	public var roots: [RootEntry]?

	// Instructions
	public var files: [InstructionFileSpec]?
	public var discovery: DiscoverySpec?

	// MCP
	public var layers: [ConfigSource]?
	public var legacy: [LegacySpec]?
	public var imports: [String: [String]]?

	// Models
	public var defaults: [String: PointerRef]?
	public var cli: [String: [String]]?

	// Settings / resources
	public var schema: String?
	public var settingsKeys: [String: String]?

	// Skills
	public var ignore: [String]?
	public var maxDepth: Int?
	public var spec: String?

	// Sub-agents
	public var frontmatter: FrontmatterSpec?

	// Sessions
	public var sessions: SessionsSpec? = nil

	// Shape knobs. Defaults follow pi; a descriptor only sets what differs.
	/// MCP: the map holding servers. pi and the shared MCP files use `mcpServers`,
	/// Codex uses `mcp_servers`.
	public var serverKey: String? = nil
	/// MCP: which boolean marks a server as off, and which value means off.
	/// pi writes `disabled = true`; Codex writes `enabled = false`.
	public var toggleKey: String? = nil
	public var toggleDisabledValue: Bool? = nil
	/// Models: the map holding providers. pi uses `providers`, Codex `model_providers`.
	public var providersKey: String? = nil
	public var providerKeys: ModelProviderKeys? = nil
	/// Force a parser instead of inferring it from the file extension.
	public var format: String? = nil

	public var isSupported: Bool {
		if case .unsupported = kind { return false }
		return true
	}
}

// MARK: - Descriptor

public struct AgentDescriptor: Codable {
	public var descriptorVersion: Int
	public var id: String
	public var name: LocalizedText
	public var subtitle: LocalizedText?
	public var icon: String?
	public var homepage: String?
	public var root: RootSpec
	public var detect: DetectSpec?
	public var surfaces: [SurfaceSpec]
	public var projects: ProjectsSpec?
	public var write: WriteSpec?

	public static let supportedVersion = 1

	public var backupPolicy: BackupPolicy {
		let spec = write?.backup
		return BackupPolicy(
			suffix: spec?.suffix ?? ".bak-agentkit",
			keep: spec?.keep ?? 10
		)
	}

	public func surface(id: String) -> SurfaceSpec? {
		surfaces.first { $0.id == id }
	}
}

// MARK: - Diagnostics

public struct DescriptorIssue: Identifiable, Hashable {
	public enum Severity: Int, Comparable, Hashable {
		case info
		case warning
		case error

		public static func < (lhs: Severity, rhs: Severity) -> Bool {
			lhs.rawValue < rhs.rawValue
		}
	}

	public let id = UUID()
	public var severity: Severity
	public var agentID: String?
	public var surfaceID: String?
	public var message: String
	public var detail: String?

	public init(
		severity: Severity,
		agentID: String? = nil,
		surfaceID: String? = nil,
		message: String,
		detail: String? = nil
	) {
		self.severity = severity
		self.agentID = agentID
		self.surfaceID = surfaceID
		self.message = message
		self.detail = detail
	}
}

/// A descriptor plus everything that had to be resolved to make it usable.
public struct LoadedAgent: Identifiable {
	public enum Origin: String {
		case builtin
		case user
	}

	public var descriptor: AgentDescriptor
	public var rootURL: URL
	public var rootExists: Bool
	public var cliURL: URL?
	public var cliVersion: String?
	public var issues: [DescriptorIssue]
	/// Nil for the copy shipped inside the app bundle.
	public var descriptorURL: URL?
	public var origin: Origin = .builtin

	public var id: String { descriptor.id }
	/// The agent's display name, in the language in effect right now.
	public var name: String { descriptor.name.current }
	public var subtitle: String? { descriptor.subtitle?.current }

	public var installed: Bool { rootExists }

	public var errorCount: Int { issues.filter { $0.severity == .error }.count }
	public var warningCount: Int { issues.filter { $0.severity == .warning }.count }

	/// True when the descriptor itself is loadable but the agent is not present
	/// on this machine.
	public var isMissing: Bool { !rootExists }
}

// MARK: - Validation

public enum DescriptorValidator {
	/// Checks a descriptor for problems that would break a surface at runtime.
	public static func validate(_ descriptor: AgentDescriptor) -> [DescriptorIssue] {
		var issues: [DescriptorIssue] = []
		let id = descriptor.id

		if descriptor.descriptorVersion != AgentDescriptor.supportedVersion {
			issues.append(DescriptorIssue(
				severity: .error,
				agentID: id,
				message: String(format: L.t("descriptor.issue.version", "描述文件版本 %d 不受支持", table: .messages), descriptor.descriptorVersion),
				detail: String(format: L.t("descriptor.issue.versionDetail", "本版本只认识 descriptorVersion = %d。", table: .messages), AgentDescriptor.supportedVersion)
			))
		}

		if descriptor.id.isEmpty {
			issues.append(DescriptorIssue(severity: .error, agentID: id, message: L.t("descriptor.issue.missingID", "描述文件缺少 id", table: .messages)))
		}
		if descriptor.root.default.isEmpty {
			issues.append(DescriptorIssue(severity: .error, agentID: id, message: L.t("descriptor.issue.missingRoot", "描述文件缺少 root.default", table: .messages)))
		}

		var seen = Set<String>()
		for surface in descriptor.surfaces {
			if !seen.insert(surface.id).inserted {
				issues.append(DescriptorIssue(
					severity: .warning,
					agentID: id,
					surfaceID: surface.id,
					message: String(format: L.t("descriptor.issue.duplicateSurface", "面板 id %@ 重复，只有第一个会生效", table: .messages), surface.id)
				))
			}
			if case .unsupported(let raw) = surface.kind {
				issues.append(DescriptorIssue(
					severity: .warning,
					agentID: id,
					surfaceID: surface.id,
					message: String(format: L.t("descriptor.issue.unknownKind", "本版本不认识面板类型 “%@”", table: .messages), raw),
					detail: L.t("descriptor.issue.unknownKindDetail", "这个面板会显示为占位符，其余面板不受影响。", table: .messages)
				))
				continue
			}
			issues.append(contentsOf: validateSurface(surface, agentID: id))
		}

		return issues
	}

	private static func validateSurface(_ surface: SurfaceSpec, agentID: String) -> [DescriptorIssue] {
		var issues: [DescriptorIssue] = []
		func missing(_ field: String) {
			issues.append(DescriptorIssue(
				severity: .error,
				agentID: agentID,
				surfaceID: surface.id,
				message: String(format: L.t("descriptor.issue.missingField", "面板 %@ 缺少 %@", table: .messages), surface.id, field)
			))
		}

		switch surface.kind {
		case .models:
			if surface.providerFile == nil { missing("providerFile") }
		case .mcp:
			if (surface.layers ?? []).isEmpty { missing("layers") }
		case .skills, .subagents:
			if (surface.roots ?? []).isEmpty { missing("roots") }
		case .sessions:
			if surface.root == nil { missing("root") }
		case .instructions:
			if (surface.files ?? []).isEmpty { missing("files") }
		case .settings:
			if surface.file == nil { missing("file") }
			if surface.schema == nil {
				issues.append(DescriptorIssue(
					severity: .warning,
					agentID: agentID,
					surfaceID: surface.id,
					message: String(format: L.t("descriptor.issue.noSchema", "面板 %@ 没有指定 schema，将退化为原始 JSON 编辑器", table: .messages), surface.id)
				))
			}
		case .resources:
			if (surface.roots ?? []).isEmpty { missing("roots") }
		case .unsupported:
			break
		}

		return issues
	}
}
