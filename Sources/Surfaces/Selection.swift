//
//  Selection.swift
//  AgentKit
//
//  Which agent, and which of its panes, the window shows.
//
//  The choice is remembered across launches, so this also decides what a
//  remembered id is worth. Ids do not survive everything: a descriptor can be
//  deleted, an agent uninstalled, a pane renamed by an update. A stale default
//  that is simply used would leave the window pointing at nothing, so an id that
//  no longer exists always falls back to the first entry.
//

import Foundation

public enum Selection {
	/// `saved` when it is still among `available`, otherwise the first entry.
	public static func resolved(saved: String?, available: [String]) -> String? {
		if let saved, available.contains(saved) { return saved }
		return available.first
	}
}
