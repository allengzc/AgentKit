//
//  ProjectScopeMenu.swift
//  AgentKit
//
//  The project scope picker. One definition used from two places — the toolbar
//  and the sidebar chip — because two copies of a menu drift apart, and this one
//  has already been wrong once (see the note about `MenuPathText` inside).
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
		if !model.projects.menuEntries.isEmpty {
			Divider()
			ForEach(model.projects.menuEntries, id: \.path) { url in
				Button {
					model.projects.select(url)
				} label: {
					// `MenuPathText`, not a local `.frame(maxWidth:)`: inside a
					// menu a `maxWidth` frame never gets to clamp, because
					// nothing proposes less than the text's ideal width.
					// Measured: `maxWidth: 260` came out 587pt wide — the same
					// as no cap at all.
					MenuPathText(path: url.path)
				}
				.help(url.path)
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
}
