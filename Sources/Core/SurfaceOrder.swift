//
//  SurfaceOrder.swift
//  AgentKit
//
//  The order the panes appear in, for every agent.
//
//  A descriptor lists its surfaces in declaration order, and the three built-in
//  descriptors declared them differently: pi opened on 模型与 Provider, Claude
//  Code on 通用设置, Codex in between. The same app therefore had a different
//  sidebar depending on which agent was picked — the panes you use most moved
//  under the pointer when you switched. Order is a property of the interface,
//  not of a data file, so it is decided here and applied when descriptors are
//  read.
//
//  Ranking is by `kind`: surface ids are free-form (a descriptor may name its
//  settings pane anything), while `kind` is the closed set this build
//  implements. An unknown kind sorts last and keeps its declared position among
//  its peers, so a descriptor for a future pane appears at the bottom instead of
//  jumping to the top.
//

import Foundation

public enum SurfaceOrder {
	/// Grouped by what the pane is for: configuration first, then the run's own
	/// record, then the app-level extras.
	private static let ranks: [String: Int] = [
		"settings": 10,
		"models": 20,
		"mcp": 30,
		"skills": 40,
		"subagents": 50,
		"instructions": 60,
		"sessions": 70,
		"resources": 80,
	]

	/// Unknown kinds share one rank (last) so the sort stays stable for them.
	public static let unknownRank = Int.max

	public static func rank(of kind: SurfaceKind) -> Int {
		ranks[kind.rawValue] ?? unknownRank
	}

	public static func ordered(_ surfaces: [SurfaceSpec]) -> [SurfaceSpec] {
		// `sorted(by:)` is not documented as stable, so equal ranks keep their
		// declared order explicitly rather than by luck.
		surfaces.enumerated()
			.sorted { left, right in
				let leftRank = rank(of: left.element.kind)
				let rightRank = rank(of: right.element.kind)
				if leftRank != rightRank { return leftRank < rightRank }
				return left.offset < right.offset
			}
			.map(\.element)
	}
}
