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
	/// True while any CLI lookup is in flight — the initial batch or a
	/// user-triggered refresh of one agent.
	public private(set) var cliResolving = false
	public var statusMessage: String?
	public var errorMessage: String?
	public private(set) var lastReload = Date()

	private var watcher: DirectoryWatcher?
	private var runningTimer: Timer?

	public let appSupport: URL

	/// Where the remembered agent and pane live.
	///
	/// The app opens on what you left it on instead of on the first agent every
	/// time. `AGENTKIT_OPEN` still overrides for a single run, and is deliberately
	/// *not* written back: that variable belongs to scripts and screenshots, not
	/// to the user's choice.
	private let defaults: UserDefaults

	private enum DefaultsKey {
		static let agent = "AgentKitSelectedAgent"
		/// Per agent, because switching pi → Claude → pi should come back to the
		/// pane you had open on pi, not to one shared "last pane".
		static func surface(_ agentID: String) -> String { "AgentKitSurface.\(agentID)" }
	}

	public init(appSupport: URL = PathResolver.defaultAppSupport, defaults: UserDefaults = .standard) {
		self.appSupport = appSupport
		self.defaults = defaults
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
			selectedAgentID = Selection.resolved(
				saved: selectedAgentID ?? defaults.string(forKey: DefaultsKey.agent),
				available: agents.map(\.id)
			)
		}
		if selectedSurfaceID == nil || selectedAgent?.descriptor.surface(id: selectedSurfaceID ?? "") == nil {
			selectedSurfaceID = Selection.resolved(
				saved: selectedSurfaceID ?? selectedAgent.flatMap { defaults.string(forKey: DefaultsKey.surface($0.id)) },
				available: selectedAgent?.descriptor.surfaces.map(\.id) ?? []
			)
		}
		rememberSelection()
		restartWatcher()
		Log.app.info("loaded \(self.agents.count, privacy: .public) agent(s)")
	}

	/// Writes the current choice back, so the next launch opens here.
	private func rememberSelection() {
		if let selectedAgentID { defaults.set(selectedAgentID, forKey: DefaultsKey.agent) }
		if let selectedAgentID, let selectedSurfaceID {
			defaults.set(selectedSurfaceID, forKey: DefaultsKey.surface(selectedAgentID))
		}
	}

	/// The agent picker: remembers the choice and restores *this* agent's pane.
	public func selectAgent(id: String) {
		guard agents.contains(where: { $0.id == id }) else { return }
		selectedAgentID = id
		selectedSurfaceID = Selection.resolved(
			saved: defaults.string(forKey: DefaultsKey.surface(id)),
			available: selectedAgent?.descriptor.surfaces.map(\.id) ?? []
		)
		rememberSelection()
	}

	/// The pane list: `nil` is a legitimate value for `List(selection:)` (the
	/// click that clears the highlight) and must not be remembered as a choice.
	public func selectSurface(id: String?) {
		selectedSurfaceID = id
		rememberSelection()
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
		rememberSelection()
	}

	public func resolver(for agent: LoadedAgent) -> PathResolver {
		DescriptorLoader.resolver(for: agent, project: projectURL, appSupport: appSupport)
	}

	// MARK: - CLI resolution

	/// Lookups in flight, fed by both the startup batch and the sidebar's
	/// refresh button.
	///
	/// A single Bool could not express that: the batch and a refresh can overlap,
	/// and whichever finished first would clear the flag under the other one —
	/// the sidebar would claim the lookup is settled while a process is still
	/// running, and the next refresh would look like it did nothing.
	private var cliLookupsInFlight = 0
	/// Guards the startup batch on its own, so a refresh in flight cannot make
	/// `resolveCLIIfNeeded` skip the one lookup that fills in every agent's
	/// `cliURL` (the panes stay disabled until that happens).
	private var cliBatchRunning = false

	private func beginCLILookup() {
		cliLookupsInFlight += 1
		cliResolving = true
	}

	private func endCLILookup() {
		cliLookupsInFlight = max(0, cliLookupsInFlight - 1)
		cliResolving = cliLookupsInFlight > 0
	}

	/// Resolving the CLI spawns a login shell, so it happens once in the
	/// background instead of blocking the first paint.
	public func resolveCLIIfNeeded() {
		guard !cliBatchRunning else { return }
		let pending = agents.filter { $0.cliURL == nil && $0.descriptor.detect?.cli != nil }
		guard !pending.isEmpty else { return }
		cliBatchRunning = true
		beginCLILookup()

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
				self.cliBatchRunning = false
				self.endCLILookup()
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

	/// Re-reads one agent's `<cli> --version`, in the background.
	///
	/// The version is the one field in that header that goes stale without
	/// AgentKit doing anything: upgrading the CLI in a terminal leaves the number
	/// from the last launch on screen. Re-running the lookup is therefore a
	/// refresh the user asks for, not something a directory watcher could infer.
	///
	/// The task is shaped exactly like `resolveCLIIfNeeded`'s — `Task.detached`
	/// plus `MainActor.run` — because `CLILocator.version` spawns a process with
	/// a 15s timeout and `locate` may spawn a login shell; either on the main
	/// thread would freeze the window for as long as the CLI takes to answer.
	public func refreshCLIVersion(for agentID: String) {
		guard let agent = agents.first(where: { $0.id == agentID }),
			let spec = agent.descriptor.detect?.cli
		else { return }

		// A path already known is reused as-is: the point of the refresh is the
		// version, and re-running the login-shell lookup here would turn a fast
		// query into a slow one (and fail outright when the CLI moved).
		let known = agent.cliURL
		let support = appSupport
		beginCLILookup()

		Task.detached(priority: .utility) {
			let url = known ?? CLILocator.locate(
				spec: spec,
				resolver: DescriptorLoader.resolver(for: agent, appSupport: support)
			)
			let version = url.flatMap { CLILocator.version(of: $0, arguments: spec.versionArgs) }
			await MainActor.run {
				// Logged because this is the one place the app spawns a process
				// on the user's behalf outside the startup batch: when the row
				// does not change, the log is what says whether the CLI answered
				// the same thing or never answered at all.
				Log.app.info("refreshed \(agentID, privacy: .public) CLI version: \(version ?? "none", privacy: .public)")
				// Matched by id rather than by the index captured above: a
				// descriptor reload can replace the whole array while the
				// process runs, and a stale index would write the version onto
				// whichever agent happens to sit there now.
				if let index = self.agents.firstIndex(where: { $0.id == agentID }) {
					if let url { self.agents[index].cliURL = url }
					self.agents[index].cliVersion = version
				}
				self.endCLILookup()
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

	/// The paths in the most recent change batch.
	///
	/// Kept, not just counted, so a pane can ask whether the batch concerned
	/// *its* files: the watcher reports everything under an agent's root,
	/// including the agent's own session and log traffic while it runs, and a
	/// pane that reloads on all of that reloads continuously.
	public private(set) var externalChangePaths: [String] = []

	/// True when the latest batch touched any of `urls`.
	public func externalChangeTouches(_ urls: [URL]) -> Bool {
		ExternalChange.touches(urls, changed: externalChangePaths)
	}

	private func handleExternalChange(paths: [String]) {
		guard !paths.isEmpty else { return }
		Log.app.debug("external change under \(paths.count, privacy: .public) path(s)")
		externalChangePaths = paths
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
