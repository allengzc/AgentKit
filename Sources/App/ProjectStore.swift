//
//  ProjectStore.swift
//  AgentKit
//
//  The project directory: which one is selected, which ones were used before,
//  and which ones the agent's own history suggests.
//
//  Project scope is what makes a config editor useful on a repo with a
//  `.pi/` or `.codex/` directory, and it is deliberately explicit rather than
//  inferred from the process's working directory — a GUI app has no working
//  directory that means anything.
//

import Foundation
import AppKit
import Observation

@MainActor
@Observable
public final class ProjectStore {
	/// Directories the user picked by hand, most recent first.
	public private(set) var recent: [URL] = []
	/// Directories the agent has actually run in, derived from session history.
	public private(set) var suggested: [URL] = []
	public private(set) var current: URL?
	public private(set) var scanning = false

	private let storeURL: URL

	private struct State: Codable {
		var recent: [String] = []
		var current: String?
	}

	public init(appSupport: URL = PathResolver.defaultAppSupport) {
		self.storeURL = appSupport.appendingPathComponent("state.json")
		load()
		applyEnvironmentOverride()
	}

	/// `AGENTKIT_PROJECT=/path` pins the project scope for one run, the same way
	/// `AGENTKIT_OPEN` pins the surface. Used by scripted checks.
	///
	/// Applied after `load()`, not inside it: the first run has no state file, and
	/// an override must not depend on one existing.
	private func applyEnvironmentOverride() {
		guard let override = ProcessInfo.processInfo.environment["AGENTKIT_PROJECT"],
			!override.isEmpty
		else { return }
		let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
		if FileManager.default.fileExists(atPath: url.path) {
			current = url
		} else {
			Log.app.info("AGENTKIT_PROJECT points at a missing directory; ignoring")
		}
	}

	// MARK: - Persistence

	private func load() {
		guard let data = try? Data(contentsOf: storeURL),
			let state = try? JSONDecoder().decode(State.self, from: data)
		else { return }
		recent = state.recent
			.map { URL(fileURLWithPath: $0) }
			.filter { FileManager.default.fileExists(atPath: $0.path) }
		if let path = state.current {
			let url = URL(fileURLWithPath: path)
			// A directory that disappeared since last run should not be restored.
			if FileManager.default.fileExists(atPath: url.path) { current = url }
		}
	}

	private func save() {
		let state = State(recent: recent.map(\.path), current: current?.path)
		guard let data = try? JSONEncoder().encode(state) else { return }
		try? FileManager.default.createDirectory(
			at: storeURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try? data.write(to: storeURL, options: .atomic)
	}

	// MARK: - Selection

	public func select(_ url: URL?) {
		current = url
		if let url {
			recent.removeAll { $0.path == url.path }
			recent.insert(url, at: 0)
			recent = Array(recent.prefix(12))
		}
		save()
	}

	public func chooseWithPanel() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.prompt = L.t("project.choose.prompt", "选择项目")
		panel.message = L.t(
			"project.choose.message",
			"AgentKit 会读取这个目录下的项目级配置（例如 .pi/ 或 .codex/）"
		)
		panel.directoryURL = current ?? PathResolver.homeDirectory()
		if panel.runModal() == .OK, let url = panel.url {
			select(url)
		}
	}

	// MARK: - Suggestions

	/// Directories the agents have run in, newest first.
	///
	/// Taken from session headers rather than from the session directory names:
	/// pi encodes the path into a slug by replacing `/` with `-`, which cannot be
	/// reversed when a real directory name contains a hyphen.
	public func refreshSuggestions(for agents: [LoadedAgent], appSupport: URL) {
		guard !scanning else { return }
		scanning = true

		Task.detached(priority: .utility) {
			var seen = Set<String>()
			var found: [(url: URL, last: Date)] = []

			for agent in agents {
				guard let surface = agent.descriptor.surfaces.first(where: { $0.kind == .sessions })
				else { continue }
				let resolver = DescriptorLoader.resolver(for: agent, appSupport: appSupport)
				guard let config = SessionsConfig.resolve(
					surface: surface,
					resolver: resolver,
					policy: agent.descriptor.backupPolicy
				) else { continue }

				for record in SessionsSurface.enumerate(config: config) {
					guard let url = record.cwdURL else { continue }
					guard url.path != agent.rootURL.path else { continue }
					if seen.insert(url.path).inserted {
						found.append((url, record.modified))
					} else if let index = found.firstIndex(where: { $0.url.path == url.path }),
						record.modified > found[index].last
					{
						found[index].last = record.modified
					}
				}

				// pi records trusted projects explicitly; those are worth offering
				// even before any session exists.
				if let template = agent.descriptor.projects?.trustFile,
					let url = try? resolver.expand(template)
				{
					let document = JSONFile.load(url, policy: agent.descriptor.backupPolicy)
					for key in document.value?.objectValue?.keys ?? [] {
						let candidate = URL(fileURLWithPath: key)
						guard candidate.path != agent.rootURL.path else { continue }
						let exists = FileManager.default.fileExists(atPath: candidate.path)
						guard exists, seen.insert(candidate.path).inserted else { continue }
						found.append((candidate, Date(timeIntervalSince1970: 0)))
					}
				}
			}

			let sorted = found
				.sorted { $0.last > $1.last }
				.map(\.url)
			await MainActor.run {
				self.suggested = sorted
				self.scanning = false
			}
		}
	}

	/// Everything worth showing in the menu, with the current one removed.
	public var menuEntries: [URL] {
		var seen = Set<String>()
		var out: [URL] = []
		if let current { seen.insert(current.path) }
		for url in recent + suggested where seen.insert(url.path).inserted {
			out.append(url)
		}
		return out
	}

	/// A short label for the toolbar: the folder name, or "全局".
	///
	/// The full `currentDisplayPath` spells out what the scope means, which is
	/// right in the sidebar and far too long for a toolbar button.
	public var currentShortLabel: String {
		guard let current else { return L.t("project.scope.globalShort", "全局") }
		return current.lastPathComponent
	}

	/// A shorter form for the sidebar: the last two path components.
	public var currentDisplayPath: String {
		guard let current else {
			return L.t("project.scope.globalLong", "全局作用域（不加载项目配置）")
		}
		let parts = current.pathComponents
		return parts.count >= 2 ? parts.suffix(2).joined(separator: "/") : current.path
	}
}
