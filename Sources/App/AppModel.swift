//
//  AppModel.swift
//  AgentKit
//
//  Root state: which agents exist, which one and which surface are selected,
//  and the background work that resolves the CLI and watches for external
//  changes.
//

import Foundation
import AppKit
import Observation

@MainActor
@Observable
public final class AppModel {
	// MARK: - Loaded state

	public private(set) var agents: [LoadedAgent] = []
	public private(set) var globalIssues: [DescriptorIssue] = []
	public var selectedAgentID: String?
	public var selectedSurfaceID: String?

	/// The project directory that `$CWD` resolves to. Selecting one is what makes
	/// a repo's own `.pi/` or `.codex/` configuration reachable.
	public let projects: ProjectStore

	/// The interface language. Changing it re-creates the root view, which is how
	/// every `L.t` call gets re-evaluated.
	public let languages = LanguageStore()
	public var projectURL: URL? { projects.current }

	// MARK: - Runtime state

	public private(set) var runningProcesses: [RunningProcess] = []
	public private(set) var cliResolving = false
	public var statusMessage: String?
	public var errorMessage: String?
	public private(set) var lastReload = Date()

	private var watcher: DirectoryWatcher?
	private var runningTimer: Timer?

	public let appSupport: URL

	public init(appSupport: URL = PathResolver.defaultAppSupport) {
		self.appSupport = appSupport
		self.projects = ProjectStore(appSupport: appSupport)
		reloadDescriptors()
	}

	private var appliedLaunchSelection = false

	/// `AGENTKIT_OPEN=pi/settings` opens a specific surface directly.
	///
	/// Applied when the window appears rather than in `init`: `@State` may build
	/// a throwaway model during the first body pass, and setting the selection
	/// there left the sidebar and the detail disagreeing for one run.
	/// Never changes anything on disk.
	public func applyLaunchSelectionIfNeeded() {
		guard !appliedLaunchSelection else { return }
		appliedLaunchSelection = true
		guard let request = ProcessInfo.processInfo.environment["AGENTKIT_OPEN"],
			!request.isEmpty
		else { return }
		Log.app.info("AGENTKIT_OPEN=\(request, privacy: .public)")
		let parts = request.split(separator: "/", maxSplits: 1).map(String.init)
		if let agentID = parts.first, agents.contains(where: { $0.id == agentID }) {
			selectedAgentID = agentID
		}
		if parts.count > 1, selectedAgent?.descriptor.surface(id: parts[1]) != nil {
			selectedSurfaceID = parts[1]
			Log.app.info("opened surface \(parts[1], privacy: .public)")
		} else {
			Log.app.info("surface \(parts.count > 1 ? parts[1] : "-", privacy: .public) not found; agents=\(self.agents.map(\.id).joined(separator: ","), privacy: .public)")
		}
	}

	// MARK: - Descriptors

	public func reloadDescriptors() {
		let outcome = DescriptorLoader.loadAll(appSupport: appSupport, locateCLI: false)
		agents = outcome.agents
		globalIssues = outcome.issues
		lastReload = Date()

		if selectedAgentID == nil || !agents.contains(where: { $0.id == selectedAgentID }) {
			selectedAgentID = agents.first?.id
		}
		if selectedSurfaceID == nil {
			selectedSurfaceID = selectedAgent?.descriptor.surfaces.first?.id
		}
		restartWatcher()
		Log.app.info("loaded \(self.agents.count, privacy: .public) agent(s)")
	}

	public var selectedAgent: LoadedAgent? {
		guard let selectedAgentID else { return nil }
		return agents.first { $0.id == selectedAgentID }
	}

	public var selectedSurface: SurfaceSpec? {
		guard let agent = selectedAgent, let selectedSurfaceID else { return nil }
		return agent.descriptor.surface(id: selectedSurfaceID)
	}

	public func select(agent: LoadedAgent, surface: SurfaceSpec) {
		selectedAgentID = agent.id
		selectedSurfaceID = surface.id
	}

	public func resolver(for agent: LoadedAgent) -> PathResolver {
		DescriptorLoader.resolver(for: agent, project: projectURL, appSupport: appSupport)
	}

	// MARK: - CLI resolution

	/// Resolving the CLI spawns a login shell, so it happens once in the
	/// background instead of blocking the first paint.
	public func resolveCLIIfNeeded() {
		guard !cliResolving else { return }
		let pending = agents.filter { $0.cliURL == nil && $0.descriptor.detect?.cli != nil }
		guard !pending.isEmpty else { return }
		cliResolving = true

		let snapshot = agents
		let support = appSupport
		Task.detached(priority: .utility) {
			var collected: [String: (URL, String?)] = [:]
			for agent in snapshot {
				guard let spec = agent.descriptor.detect?.cli else { continue }
				let resolver = DescriptorLoader.resolver(for: agent, appSupport: support)
				if let url = CLILocator.locate(spec: spec, resolver: resolver) {
					collected[agent.id] = (url, CLILocator.version(of: url, arguments: spec.versionArgs))
				}
			}
			let updated = collected
			await MainActor.run {
				for index in self.agents.indices {
					if let found = updated[self.agents[index].id] {
						self.agents[index].cliURL = found.0
						self.agents[index].cliVersion = found.1
					}
				}
				self.cliResolving = false
				if let agent = self.selectedAgent, agent.cliURL == nil {
					self.statusMessage = String(
						format: L.t("app.cliMissing", "找不到 %@，依赖命令行的功能已停用"),
						agent.descriptor.detect?.cli?.name ?? "CLI"
					)
				}
				self.projects.refreshSuggestions(for: self.agents, appSupport: support)
			}
		}
	}

	// MARK: - Running agents

	public func startRunningPoll() {
		refreshRunning()
		runningTimer?.invalidate()
		runningTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
			Task { @MainActor in self?.refreshRunning() }
		}
	}

	public func refreshRunning() {
		let names = agents.compactMap { $0.descriptor.detect?.cli?.name }
		guard !names.isEmpty else { return }
		let scanned = RunningAgents.scan(names: names)
		if scanned.map(\.pid) != runningProcesses.map(\.pid) {
			runningProcesses = scanned
		}
	}

	public var isSelectedAgentRunning: Bool { !runningProcesses.isEmpty }

	// MARK: - Watching

	private func restartWatcher() {
		watcher?.stop()
		guard let agent = selectedAgent else { return }
		let resolver = resolver(for: agent)
		var paths: [URL] = [agent.rootURL]
		for surface in agent.descriptor.surfaces {
			for template in SurfacePaths.candidatePaths(for: surface) {
				if let url = try? resolver.expand(template) { paths.append(url) }
			}
		}
		let watcher = DirectoryWatcher { [weak self] changed in
			Task { @MainActor in self?.handleExternalChange(paths: changed) }
		}
		watcher.start(paths: paths)
		self.watcher = watcher
	}

	public var externalChangeToken = UUID()

	private func handleExternalChange(paths: [String]) {
		guard !paths.isEmpty else { return }
		Log.app.debug("external change under \(paths.count, privacy: .public) path(s)")
		externalChangeToken = UUID()
	}

	public func watch(paths: [URL]) {
		watcher?.stop()
		let watcher = DirectoryWatcher { [weak self] changed in
			Task { @MainActor in self?.handleExternalChange(paths: changed) }
		}
		watcher.start(paths: paths)
		self.watcher = watcher
	}
}
