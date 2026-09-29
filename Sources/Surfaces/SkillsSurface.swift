//
//  SkillsSurface.swift
//  AgentKit
//
//  Discovering Agent Skills: directories containing `SKILL.md`, discovered
//  recursively, including through symlinks.
//
//  `~/.pi/agent/skills/demo-skill` on this machine is a symlink into a whole
//  repository that also contains `logs/`, `reference/` and a `.venv`. A naive
//  recursive walk would crawl all of it, so discovery prunes ignored
//  directories, stops at a fixed depth, and stops descending as soon as a
//  directory declares itself a skill.
//

import Foundation

public struct SkillEntry: Identifiable {
	public let url: URL
	public let directory: URL
	public let rootTemplate: String
	public let scope: String
	public let writable: Bool
	public let isSymlink: Bool
	public let realDirectory: URL
	public let document: TextDocument
	public let topLevel: [String]

	public var id: String { url.path }
	public var frontmatter: FrontmatterDocument { document.frontmatter }

	public var name: String {
		frontmatter.string("name") ?? directory.lastPathComponent
	}

	public var description: String { frontmatter.string("description") ?? "" }

	public var license: String? { frontmatter.string("license") }
	public var compatibility: String? { frontmatter.string("compatibility") }
	public var allowedTools: [String]? { frontmatter.stringArray("allowed-tools") }

	public var disableModelInvocation: Bool {
		frontmatter.value("disable-model-invocation")?.boolValue ?? false
	}

	public var directoryNameMatches: Bool {
		name == directory.lastPathComponent
	}

	/// Mirrors pi's own validation: malformed frontmatter or a missing
	/// description means the skill is not loaded at all.
	public var issues: [String] {
		var out: [String] = []
		if !document.isReadable { out.append(document.problemReason ?? "文件无法读取") }
		if frontmatter.string("description") == nil {
			out.append("缺少 description：pi 不会加载这个 skill")
		} else if description.count > 1024 {
			out.append("description 超过 1024 字符")
		}
		let name = self.name
		if !SkillsScanner.isValidName(name) {
			out.append("name \(name) 不符合规范：只能用小写字母、数字和连字符")
		}
		if name.count > 64 { out.append("name 超过 64 字符") }
		return out
	}

	public var warnings: [String] {
		var out: [String] = []
		if !directoryNameMatches {
			out.append("声明名 \(name) 与目录名 \(directory.lastPathComponent) 不一致；AgentKit 与其它实现都接受，但目录名一致更便于移植")
		}
		return out
	}
}

public struct SkillDirectoryWithoutManifest: Identifiable {
	public let url: URL
	public let rootTemplate: String
	public var id: String { url.path }
}

public struct SkillsSnapshot {
	public var skills: [SkillEntry] = []
	public var missingManifest: [SkillDirectoryWithoutManifest] = []
	public var missingRoots: [URL] = []
	public var disabled: [URL] = []

	public var problemCount: Int { skills.filter { !$0.issues.isEmpty }.count }
}

public enum SkillsScanner {
	/// A name pi (and the Agent Skills spec) accepts.
	public static func isValidName(_ name: String) -> Bool {
		guard !name.isEmpty, name.count <= 64 else { return false }
		return name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
	}

	public static func scan(
		roots: [(spec: RootEntry, url: URL)],
		ignore: Set<String>,
		maxDepth: Int,
		policy: BackupPolicy
	) -> SkillsSnapshot {
		var snapshot = SkillsSnapshot()
		let fileManager = FileManager.default

		for root in roots {
			var isDirectory: ObjCBool = false
			guard fileManager.fileExists(atPath: root.url.path, isDirectory: &isDirectory) else {
				snapshot.missingRoots.append(root.url)
				continue
			}
			let disabledDirectory = root.url.appendingPathComponent(".disabled", isDirectory: true)
			if let items = try? fileManager.contentsOfDirectory(at: disabledDirectory, includingPropertiesForKeys: nil) {
				snapshot.disabled.append(contentsOf: items)
			}

			// The root itself may be a symlink to a skill.
			if let entry = declareSkill(
				directory: root.url,
				rootTemplate: root.spec.path,
				scope: root.spec.scope ?? "user",
				writable: root.spec.isWritable,
				ignore: ignore,
				policy: policy
			) {
				snapshot.skills.append(entry)
				continue
			}

			let children = (try? fileManager.contentsOfDirectory(
				at: root.url,
				includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
				options: [.skipsHiddenFiles]
			)) ?? []

			for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
				guard !ignore.contains(child.lastPathComponent) else { continue }
				guard directoryExists(child) else { continue }

				if let entry = declareSkill(
					directory: child,
					rootTemplate: root.spec.path,
					scope: root.spec.scope ?? "user",
					writable: root.spec.isWritable,
					ignore: ignore,
					policy: policy
				) {
					snapshot.skills.append(entry)
					continue
				}

				// Nested layouts: walk down a few levels looking for SKILL.md.
				if let nested = findSkill(under: child, ignore: ignore, maxDepth: maxDepth, policy: policy),
					let entry = declareSkill(
						directory: nested,
						rootTemplate: root.spec.path,
						scope: root.spec.scope ?? "user",
						writable: root.spec.isWritable,
						ignore: ignore,
						policy: policy
					)
				{
					snapshot.skills.append(entry)
					continue
				}

				snapshot.missingManifest.append(
					SkillDirectoryWithoutManifest(url: child, rootTemplate: root.spec.path)
				)
			}
		}

		snapshot.skills.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
		return snapshot
	}

	private static func directoryExists(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
		return isDirectory.boolValue
	}

	/// Breadth-first search for a `SKILL.md`, pruning ignored directories.
	static func findSkill(
		under directory: URL,
		ignore: Set<String>,
		maxDepth: Int,
		policy: BackupPolicy
	) -> URL? {
		var frontier = [directory]
		var depth = 0
		while !frontier.isEmpty, depth < maxDepth {
			var next: [URL] = []
			for current in frontier {
				let manifest = current.appendingPathComponent("SKILL.md")
				if FileManager.default.fileExists(atPath: manifest.path) { return current }
				let children = (try? FileManager.default.contentsOfDirectory(
					at: current,
					includingPropertiesForKeys: [.isDirectoryKey],
					options: [.skipsHiddenFiles]
				)) ?? []
				for child in children {
					guard !ignore.contains(child.lastPathComponent) else { continue }
					guard directoryExists(child) else { continue }
					next.append(child)
				}
			}
			frontier = next
			depth += 1
		}
		return nil
	}

	private static func declareSkill(
		directory: URL,
		rootTemplate: String,
		scope: String,
		writable: Bool,
		ignore: Set<String>,
		policy: BackupPolicy
	) -> SkillEntry? {
		let manifest = directory.appendingPathComponent("SKILL.md")
		guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
		let document = TextFile.load(manifest, policy: policy)
		let realDirectory = (try? URL(resolvingAliasFileAt: directory)) ?? directory
		let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
		let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

		// A symlinked skill directory resolves to its target for listing:
		// `contentsOfDirectory` does not follow the link itself.
		let listingDirectory = directory.resolvingSymlinksInPath()
		let topLevel = ((try? FileManager.default.contentsOfDirectory(
			at: listingDirectory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		)) ?? [])
			.map(\.lastPathComponent)
			.filter { !ignore.contains($0) }
			.sorted()

		return SkillEntry(
			url: manifest,
			directory: directory,
			rootTemplate: rootTemplate,
			scope: scope,
			writable: writable,
			isSymlink: isSymlink,
			realDirectory: realDirectory,
			document: document,
			topLevel: topLevel
		)
	}

	/// The directory a new skill should be created in.
	public static func createSkill(named name: String, in root: URL, description: String) throws -> URL {
		let directory = root.appendingPathComponent(name, isDirectory: true)
		guard !FileManager.default.fileExists(atPath: directory.path) else {
			throw FileWriteError.io("\(directory.path) 已经存在")
		}
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("scripts", isDirectory: true),
			withIntermediateDirectories: true
		)

		var document = FrontmatterDocument.empty
		document.hasFrontmatter = true
		document.setRaw(FrontmatterDocument.literal(for: .string(name)), forKey: "name")
		document.setRaw(FrontmatterDocument.literal(for: .string(description)), forKey: "description")
		document.body = """

		# \(name)

		在这里写这个 skill 做什么、什么时候用，以及需要先读哪些 bundled 文件。

		脚本请用相对于本目录的路径引用，例如 `scripts/example.sh`。

		"""
		let manifest = directory.appendingPathComponent("SKILL.md")
		guard let data = document.render().data(using: .utf8) else {
			throw FileWriteError.io("无法编码 SKILL.md")
		}
		try AtomicFile.write(data, to: manifest, mode: 0o644)
		return manifest
	}

	/// AgentKit's convention for turning a skill off: move it aside.
	///
	/// pi has no per-skill off switch (only the global `enableSkillCommands`),
	/// so this is AgentKit's own, and the UI says so.
	public static func setEnabled(_ entry: SkillEntry, enabled: Bool) throws {
		let root = entry.directory.deletingLastPathComponent()
		let disabledRoot = root.appendingPathComponent(".disabled", isDirectory: true)
		let destination = enabled
			? root.appendingPathComponent(entry.directory.lastPathComponent)
			: disabledRoot.appendingPathComponent(entry.directory.lastPathComponent)
		guard !FileManager.default.fileExists(atPath: destination.path) else {
			throw FileWriteError.io("\(destination.path) 已经存在")
		}
		if !enabled {
			try FileManager.default.createDirectory(at: disabledRoot, withIntermediateDirectories: true)
		}
		try FileManager.default.moveItem(at: entry.directory, to: destination)
	}
}
