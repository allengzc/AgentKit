//
//  PaneActions.swift
//  AgentKit
//
//  What the pane in the detail column offers in the window toolbar.
//
//  The toolbar's leading item used to be the project menu — a folder icon that
//  opened a list of directories. The project scope now lives on the sidebar's
//  chip (where the ✕ that clears it already was), which frees that slot for
//  something the pane itself gets to fill: an `⋯` menu whose contents change
//  with the pane you are looking at.
//
//  Three shapes were considered and this is the one that survived:
//
//  * A preference key is the usual way for a child to hand data to a parent,
//    but the payload here is closures, and preferences are diffed with `==`.
//    Boxing them and comparing by identity makes `onPreferenceChange` fire on
//    every render, which is a state write during a view update — a render loop.
//    It is also shared across the whole toolbar, so the "which pane is this
//    group for" question would have to be answered by the value anyway.
//  * Letting each pane declare its own `ToolbarItem` puts the *pane* in charge
//    of a decision that is about one shared item: whether the `⋯` exists at
//    all, and which group is inside it. Two panes on screen at once would each
//    draw their own button.
//  * An observable collector in the environment keeps the decision in one
//    place (`RootView`) and lets a pane contribute without knowing where the
//    item lands. That is what this file is.
//
//  A registration is a *builder*, not a snapshot: the pane hands over a closure
//  that reads its own state and returns the menu entries, and `RootView` calls
//  it while building the toolbar. A pane whose entries change over time (MCP
//  only offers "add server" once it has loaded the writable layers) also passes
//  a `signature`; when that value changes the pane registers again, so the menu
//  cannot show a stale group.
//

import Observation
import SwiftUI

// MARK: - Entries that are paths

/// How wide a menu entry that is a file path may get.
///
/// A menu sizes itself to its widest item, so one long path stretches the whole
/// menu — the project menu grew past the sidebar and pushed the window layout
/// around before this cap existed, and MCP's list of writable config layers has
/// the same shape. Both cap at this and truncate in the middle: the head says
/// which tree it is, the leaf says which entry, and the middle is the part two
/// paths most often share. The whole path stays available through `.help`.
let menuPathMaxWidth: CGFloat = 260

/// A menu row that shows a path without letting the menu grow to fit it.
///
/// The width has to be *fixed*, not `maxWidth`. Inside an `NSMenu` SwiftUI
/// measures an item's ideal size and a `Text` there reports the full string;
/// `.frame(maxWidth:)` never gets to clamp it, because nothing ever proposes
/// less than the ideal. Measured: with `maxWidth: 260` the menu came out
/// 587pt wide, exactly as wide as with no cap at all. Pinning the width is
/// what makes the `.lineLimit(1)` + `.middle` truncation actually run, and it
/// makes every row line up at the same width instead of following the longest
/// path.
struct MenuPathText: View {
	let path: String

	var body: some View {
		Text(path)
			.lineLimit(1)
			.truncationMode(.middle)
			.frame(width: menuPathMaxWidth, alignment: .leading)
	}
}

// MARK: - What a pane contributes

/// One row of the toolbar's `⋯` menu.
///
/// Entries with `items` render as a submenu; the rest render as a button. `id`
/// is namespaced by the pane (`mcp.addServer`) and only has to be unique within
/// one group.
struct PaneAction: Identifiable {
	let id: String
	let title: String
	let systemImage: String?
	let isEnabled: Bool
	/// Non-nil when `title` is a path: the entry is then capped at this width
	/// and truncated in the middle, so it cannot stretch the menu. See
	/// `menuPathMaxWidth`.
	let titleMaxWidth: CGFloat?
	let items: [PaneAction]
	let perform: () -> Void

	/// A menu item that does something.
	static func command(
		id: String,
		title: String,
		systemImage: String? = nil,
		isEnabled: Bool = true,
		titleMaxWidth: CGFloat? = nil,
		perform: @escaping () -> Void
	) -> PaneAction {
		PaneAction(
			id: id,
			title: title,
			systemImage: systemImage,
			isEnabled: isEnabled,
			titleMaxWidth: titleMaxWidth,
			items: [],
			perform: perform
		)
	}

	/// A command whose title is a file path.
	static func path(
		id: String,
		title: String,
		isEnabled: Bool = true,
		perform: @escaping () -> Void
	) -> PaneAction {
		command(
			id: id,
			title: title,
			isEnabled: isEnabled,
			titleMaxWidth: menuPathMaxWidth,
			perform: perform
		)
	}

	/// A menu item that opens another menu — for an action that needs a target
	/// ("new server" asks *which config layer*).
	static func submenu(
		id: String,
		title: String,
		systemImage: String? = nil,
		isEnabled: Bool = true,
		items: [PaneAction]
	) -> PaneAction {
		PaneAction(
			id: id,
			title: title,
			systemImage: systemImage,
			isEnabled: isEnabled,
			titleMaxWidth: nil,
			items: items,
			perform: {}
		)
	}
}

/// The entries one pane contributed, under the pane's own name.
struct PaneActionGroup: Identifiable {
	let id: String
	let title: String
	let actions: [PaneAction]

	/// A pane that contributes nothing gets no section — and if every group is
	/// empty, the toolbar item is not drawn at all.
	var isEmpty: Bool { actions.isEmpty }
}

// MARK: - The collector

/// What panes have registered, in registration order.
///
/// Reads are allowed from any pane body; writes happen in `onAppear` /
/// `onChange` / `onDisappear`, never during a body evaluation.
@MainActor
@Observable
final class PaneActionStore {
	private struct Registration {
		let title: String
		let build: () -> [PaneAction]
	}

	private var order: [String] = []
	private var registrations: [String: Registration] = [:]

	func register(token: String, title: String, build: @escaping () -> [PaneAction]) {
		if registrations[token] == nil { order.append(token) }
		registrations[token] = Registration(title: title, build: build)
	}

	/// Token-guarded on purpose: when the selected pane changes, SwiftUI can run
	/// the incoming pane's `onAppear` before the outgoing pane's `onDisappear`.
	/// An unconditional clear would then erase the registration that just
	/// arrived, and the menu would stay empty until something else re-rendered
	/// the toolbar.
	func unregister(token: String) {
		guard registrations.removeValue(forKey: token) != nil else { return }
		order.removeAll { $0 == token }
	}

	var groups: [PaneActionGroup] {
		order.compactMap { token in
			guard let registration = registrations[token] else { return nil }
			return PaneActionGroup(
				id: token,
				title: registration.title,
				actions: registration.build()
			)
		}
	}
}

// MARK: - The modifier a pane uses

private struct PaneActionsModifier<Signature: Equatable>: ViewModifier {
	@Environment(PaneActionStore.self) private var store

	let token: String
	let title: String
	let signature: Signature
	let build: () -> [PaneAction]

	func body(content: Content) -> some View {
		content
			.onAppear { store.register(token: token, title: title, build: build) }
			// The pane's own state decides what the menu offers; when that state
			// changes the registration is replaced. `signature` is deliberately
			// plain data so the comparison cannot touch the closures.
			.onChange(of: signature) { _, _ in
				store.register(token: token, title: title, build: build)
			}
			.onDisappear { store.unregister(token: token) }
	}
}

extension View {
	/// Registers the entries this pane wants in the window toolbar's `⋯` menu.
	///
	/// - Parameters:
	///   - token: identifies the pane; use `paneActionToken(agent:surface:)` so
	///     switching surfaces cannot leave the previous pane's group behind.
	///   - title: the section header in the menu.
	///   - signature: any `Equatable` that changes when the entries change. The
	///     default is fine for a pane whose menu is static; MCP passes the ids of
	///     its writable layers, because the submenu only exists once they load.
	///   - build: the entries, read fresh every time the menu is built.
	func paneActions<Signature: Equatable>(
		token: String,
		title: String,
		signature: Signature = 0,
		_ build: @escaping () -> [PaneAction]
	) -> some View {
		modifier(
			PaneActionsModifier(token: token, title: title, signature: signature, build: build)
		)
	}
}

/// The identity a pane registers under: the same key `RootView` gives the pane
/// with `.id(...)`.
///
/// It has to include the agent, not just the surface: Skills is a surface id
/// that exists under pi, codex and claude, and switching agents rebuilds the
/// pane with the same id. Sharing a token there would let the outgoing pane's
/// `onDisappear` unregister the pane that just replaced it.
func paneActionToken(agent: LoadedAgent, surface: SurfaceSpec) -> String {
	"\(agent.id)/\(surface.id)"
}
