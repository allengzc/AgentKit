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

/// One project the scope menu can offer, with where it came from.
///
/// The menu shows the *union* of every agent's projects, and that is deliberate:
/// project scope answers "where do you work", not "which agent is working", and
/// the same repository often carries both a `.pi/` and a `.codex/` directory.
/// Filtering by agent would make a project disappear when the user switches
/// agents, even though the project is still right there.
///
/// What the union was missing is provenance. Before this change the menu on the
/// machine it was written for held 41 rows — the raw history is 55 paths, of
/// which 41 still exist — and the agent on screen had run in at most 24 of
/// them, with no way to tell which. `agentIDs` is that missing column; the
/// ordering that uses it happens at render time, because only the view knows
/// which agent is on screen.
public struct ProjectSuggestion: Identifiable, Equatable, Sendable {
	/// Stable identity for `ForEach`. Paths are already unique in the list.
	public var id: String { url.path }
	public let url: URL
	/// Newest activity seen for this project, across every agent.
	public let last: Date
	/// Ids of the agents that have this project in their session history or in
	/// their trust file. Empty for a project the user picked by hand that no
	/// agent has touched yet — that is a real answer, not a missing one.
	public let agentIDs: Set<String>

	public init(url: URL, last: Date, agentIDs: Set<String>) {
		self.url = url
		self.last = last
		self.agentIDs = agentIDs
	}

	/// How wide a project row is allowed to get, in menu columns.
	///
	/// A budget on the *string*, because that is the only thing a menu row can
	/// carry on this system: macOS 26.6.2 flattens a SwiftUI `Menu` item's
	/// custom label to plain text before AppKit draws it — the fixed-width
	/// frame, the font and a second `Text` in the row are all dropped.
	/// Measured: a 52-character path rendered in full and stretched the menu to
	/// 412pt, the same shape as the 587pt bug the fixed width was meant to
	/// kill. Shortening the string bounds the row whatever the OS does with the
	/// label; `MenuPathText` still wraps it, and its middle truncation keeps
	/// head and tail if a later macOS hosts the label as a view again.
	public static let menuRowBudget = 40

	/// The row as the menu renders it: a shortened path, then who has used it.
	///
	/// The badges come first in the budget — a row that silently dropped them
	/// would be the flat union again — so the path gives up as many columns as
	/// the agent list needs, and a machine with more agents than can be spelled
	/// out counts the rest instead of growing the menu.
	public var menuLabel: String {
		let ids = agentIDs.sorted()
		guard !ids.isEmpty else {
			return Self.shortenedPath(url.path, columns: Self.menuRowBudget)
		}
		var badge = ids.prefix(Self.menuLabelAgentLimit).joined(separator: ", ")
		if ids.count > Self.menuLabelAgentLimit {
			badge += " +\(ids.count - Self.menuLabelAgentLimit)"
		}
		let separator = " · "
		let taken = Self.displayColumns(separator) + Self.displayColumns(badge)
		let forPath = max(12, Self.menuRowBudget - taken)
		return Self.shortenedPath(url.path, columns: forPath) + separator + badge
	}

	/// How many agent names a row spells out before it starts counting them.
	public static let menuLabelAgentLimit = 3

	/// Middle-elides a path to a column budget.
	///
	/// The head says which tree it is, the tail says which project, and which
	/// project is the part people scan for — so a leaf that fits inside the
	/// budget is kept whole rather than cut in half, and only the directories
	/// above it are dropped. Paths that already fit are returned untouched:
	/// this is not allowed to abbreviate a short path.
	public nonisolated static func shortenedPath(_ path: String, columns: Int) -> String {
		guard displayColumns(path) > columns, columns > 1 else { return path }
		let room = columns - 1
		let leaf = (path as NSString).lastPathComponent
		let leafColumns = displayColumns(leaf)
		if leafColumns <= room, room - leafColumns >= 3 {
			return prefix(path, columns: room - leafColumns) + "…" + leaf
		}
		// The leaf alone does not fit; split what is left, one extra column to
		// the head because a leading `/` or `~` carries more meaning per column
		// than the last character of a long leaf.
		let head = (room + 1) / 2
		return prefix(path, columns: head) + "…" + suffix(path, columns: room - head)
	}

	/// Width in menu columns: a CJK character or an emoji occupies two, a Latin
	/// one occupies one. Without this a 40-column budget would mean 40 Chinese
	/// characters — twice the width the cap promises.
	public nonisolated static func displayColumns(_ text: String) -> Int {
		text.reduce(0) { $0 + ($1.unicodeScalars.contains(where: isWide) ? 2 : 1) }
	}

	private nonisolated static func isWide(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
			0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
			0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
			0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
			return true
		default:
			return false
		}
	}

	private nonisolated static func prefix(_ text: String, columns: Int) -> String {
		var out = ""
		var used = 0
		for character in text {
			let width = displayColumns(String(character))
			guard used + width <= columns else { break }
			used += width
			out.append(character)
		}
		return out
	}

	private nonisolated static func suffix(_ text: String, columns: Int) -> String {
		var out = ""
		var used = 0
		for character in text.reversed() {
			let width = displayColumns(String(character))
			guard used + width <= columns else { break }
			used += width
			out.insert(character, at: out.startIndex)
		}
		return out
	}
}

/// A run of menu rows that share a reason for being in the menu.
///
/// The sections are what makes a 55-row union readable: the hand-picked ones,
/// the ones the agent on screen has run in, and everything else.
public struct ProjectMenuSection: Identifiable, Equatable {
	public enum Kind: String, Sendable {
		/// Picked by hand; this is the list `state.json` persists.
		case picked
		/// Used by the agent currently selected.
		case mine
		/// Used by another agent, or listed because it was trusted somewhere.
		case others
	}

	public let kind: Kind
	public let entries: [ProjectSuggestion]
	public var id: String { kind.rawValue }

	public init(kind: Kind, entries: [ProjectSuggestion]) {
		self.kind = kind
		self.entries = entries
	}
}

@MainActor
@Observable
public final class ProjectStore {
	/// Directories the user picked by hand, most recent first.
	public private(set) var recent: [URL] = []
	/// Directories the agents have actually run in, newest first, each carrying
	/// the set of agents that account for it.
	public private(set) var suggested: [ProjectSuggestion] = []
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

	/// Directories the agents have run in, newest first, with their provenance.
	///
	/// Taken from session headers rather than from the session directory names:
	/// pi encodes the path into a slug by replacing `/` with `-`, which cannot be
	/// reversed when a real directory name contains a hyphen.
	///
	/// One row per path, not one row per (path, agent): the same repository shows
	/// up in two agents' histories all the time, and instead of dropping the
	/// second sighting (which is what the flat `Set<String>` here used to do) the
	/// row collects both agent ids and keeps the newest timestamp.
	public func refreshSuggestions(for agents: [LoadedAgent], appSupport: URL) {
		guard !scanning else { return }
		scanning = true

		Task.detached(priority: .utility) {
			var found: [ProjectSuggestion] = []
			var indexByPath: [String: Int] = [:]

			/// Fold one sighting into the row for its path.
			func note(_ url: URL, at last: Date, agent agentID: String) {
				if let index = indexByPath[url.path] {
					let existing = found[index]
					found[index] = ProjectSuggestion(
						url: existing.url,
						last: max(existing.last, last),
						agentIDs: existing.agentIDs.union([agentID])
					)
				} else {
					indexByPath[url.path] = found.count
					found.append(ProjectSuggestion(url: url, last: last, agentIDs: [agentID]))
				}
			}

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
					note(url, at: record.modified, agent: agent.id)
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
						guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
						note(candidate, at: Date(timeIntervalSince1970: 0), agent: agent.id)
					}
				}
			}

			// Newest first. Paths break ties so two rows that both came only from
			// a trust file (all stamped with the epoch) keep a stable order
			// instead of following dictionary iteration.
			let sorted = found.sorted {
				if $0.last != $1.last { return $0.last > $1.last }
				return $0.url.path < $1.url.path
			}
			await MainActor.run {
				self.suggested = sorted
				self.scanning = false
			}
		}
	}

	/// The menu, grouped and ordered for the agent on screen, current one removed.
	///
	/// Ordered here rather than when the scan lands, because the scan runs once
	/// for every agent at once and has no idea which one the user is looking at:
	/// the sort key *is* "is this the selected agent". Within a group the rows
	/// keep the newest-first order from `suggested`.
	///
	/// Nothing is filtered out. A project another agent has used is still a place
	/// this user works, and hiding it would make switching agents look like it
	/// deleted their projects.
	public func menuSections(for agentID: String?) -> [ProjectMenuSection] {
		Self.menuSections(recent: recent, suggested: suggested, current: current, agentID: agentID)
	}

	/// The same ordering with everything passed in, so the rule can be asserted
	/// without a scan and without a window. `nonisolated` because it only looks
	/// at its arguments — the pure part of what the menu shows.
	public nonisolated static func menuSections(
		recent: [URL],
		suggested: [ProjectSuggestion],
		current: URL?,
		agentID: String?
	) -> [ProjectMenuSection] {
		var known: [String: ProjectSuggestion] = [:]
		for suggestion in suggested { known[suggestion.url.path] = suggestion }

		var seen = Set<String>()
		if let current { seen.insert(current.path) }

		var picked: [ProjectSuggestion] = []
		for url in recent where seen.insert(url.path).inserted {
			// A hand-picked project is often one an agent has run in too; carry
			// the provenance over so the badge does not depend on which list the
			// row came from.
			let provenance = known[url.path]
			picked.append(
				ProjectSuggestion(
					url: url,
					last: provenance?.last ?? .distantPast,
					agentIDs: provenance?.agentIDs ?? []
				)
			)
		}

		var mine: [ProjectSuggestion] = []
		var others: [ProjectSuggestion] = []
		for suggestion in suggested {
			guard seen.insert(suggestion.url.path).inserted else { continue }
			if let agentID, suggestion.agentIDs.contains(agentID) {
				mine.append(suggestion)
			} else {
				others.append(suggestion)
			}
		}

		return [
			ProjectMenuSection(kind: .picked, entries: picked),
			ProjectMenuSection(kind: .mine, entries: mine),
			ProjectMenuSection(kind: .others, entries: others),
		].filter { !$0.entries.isEmpty }
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
