//
//  ProjectScopeMenu.swift
//  AgentKit
//
//  The project scope picker. One definition used from two places — the toolbar
//  and the sidebar chip — because two copies of a menu drift apart, and this one
//  has already been wrong once (see the note about `MenuPathText` inside).
//
//  The list is the union of every agent's projects, which is the right set: the
//  same repository carries a `.pi/` and a `.codex/` directory more often than
//  not, so filtering by agent makes projects vanish when the user switches
//  agents. What was wrong was that the union said nothing about where each row
//  came from: 55 rows sorted by activity, 30 of them never touched by the agent
//  on screen. Each row now names the agents that used it, and the rows are
//  grouped and ordered for the agent in scope — see `ProjectStore.menuSections`.
//

import SwiftUI

/// The contents of the project scope menu.
///
/// A `View` rather than a `Menu`: the toolbar wants a labelled menu and the
/// sidebar wants a chip, and only the contents are shared.
struct ProjectScopeMenu: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		Button {
			model.projects.select(nil)
		} label: {
			Label(
				L.t("project.scope.global", "全局（不加载项目配置）"),
				systemImage: model.projectURL == nil ? "checkmark" : "globe"
			)
		}
		if !sections.isEmpty {
			ForEach(sections) { section in
				Section {
					ForEach(section.entries) { entry in
						Button {
							model.projects.select(entry.url)
						} label: {
							// One string, not an `HStack` of path + badge.
							//
							// Measured on macOS 26.6.2: a SwiftUI `Menu` flattens a
							// custom `Button` label to plain text before AppKit draws
							// the item. `.frame(width:)`, `.font()`,
							// `.foregroundStyle()` and a second `Text` in the row all
							// disappear — a row labelled with `MenuPathText` plus a
							// badge rendered as the full 52-character path with no
							// badge and stretched the menu to 412pt. So the path is
							// shortened and the agents appended *in the string* (see
							// `ProjectSuggestion.menuLabel`), which bounds the row no
							// matter what the OS does with the label. `MenuPathText`
							// still wraps it: today its fixed width is a no-op, and if
							// a later macOS hosts the label as a view again its middle
							// truncation keeps the head and the badge at the tail.
							MenuPathText(path: entry.menuLabel)
						}
						.help(entry.url.path)
					}
				} header: {
					Text(header(for: section.kind))
				}
			}
		}
		Divider()
		Button(L.t("button.chooseDirectory", "选择目录…")) { model.projects.chooseWithPanel() }
		Button(L.t("button.revealCurrentProject", "在 Finder 中显示当前项目")) {
			if let project = model.projectURL { ShellActions.reveal(project) }
		}
		.disabled(model.projectURL == nil)
		if model.projects.scanning {
			Divider()
			Text(L.t("project.scanning", "正在从会话历史中整理项目…"))
		}
	}

	/// Recomputed on every render, which is the point: the order depends on
	/// which agent is selected right now, and the scan that fills `suggested`
	/// ran once for all of them.
	private var sections: [ProjectMenuSection] {
		model.projects.menuSections(for: model.selectedAgent?.id)
	}

	/// What a group of rows has in common, in words.
	///
	/// Without these three the menu is the flat 55-row list again: the badges say
	/// who used a project, the headers say why the rows are in this order.
	private func header(for kind: ProjectMenuSection.Kind) -> String {
		switch kind {
		case .picked:
			return L.t("project.menu.picked", "最近选择")
		case .mine:
			return String(
				format: L.t("project.menu.mine", "%@ 用过"),
				model.selectedAgent?.name ?? ""
			)
		case .others:
			return L.t("project.menu.others", "其他项目")
		}
	}
}
