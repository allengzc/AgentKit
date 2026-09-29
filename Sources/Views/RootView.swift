//
//  RootView.swift
//  AgentKit
//
//  Window shell: sidebar plus the pane for the selected surface.
//

import SwiftUI

struct RootView: View {
	@Environment(AppModel.self) private var model
	@State private var showDiagnostics = false
	/// What the pane on screen contributes to the toolbar; see `PaneActions.swift`.
	@State private var paneActions = PaneActionStore()

	var body: some View {
		// Read here, not inside the toolbar item: this is what registers the
		// dependency on the pane's state, so a menu entry that turns enabled or
		// disabled while the pane loads is redrawn.
		let groups = paneActions.groups.filter { !$0.isEmpty }
		// The ⋯ item exists only when it has something to offer: this pane's
		// actions, or diagnostics that are actually complaining. A pane that
		// contributes nothing and has nothing to report leaves the toolbar
		// without the item at all, instead of offering an empty menu.
		let showsOverflow = !groups.isEmpty || diagnosticCount > 0
		return NavigationSplitView {
			Sidebar()
		} detail: {
			detail
		}
		.environment(paneActions)
		.navigationTitle(model.selectedAgent.map { "\($0.name) · \($0.subtitle ?? L.t("agent.subtitle.fallback", "配置"))" } ?? "AgentKit")
		.navigationSubtitle(model.selectedAgent?.subtitle ?? "")
		.toolbar {
			ToolbarItem(placement: .navigation) {
				projectMenu
			}
			ToolbarItem(placement: .automatic) {
				if showsOverflow {
					overflowMenu(groups)
				}
			}
		}
		.sheet(isPresented: $showDiagnostics) {
			DiagnosticsSheet(
				issues: (model.selectedAgent?.issues ?? []) + model.globalIssues,
				onClose: { showDiagnostics = false }
			)
		}
		.task {
			model.applyLaunchSelectionIfNeeded()
			model.resolveCLIIfNeeded()
			model.startRunningPoll()
		}
	}

	/// The `⋯` item.
	///
	/// It carries pane actions only. Project scope used to live here; it moved to
	/// the sidebar's scope chip, which already showed the current scope and the
	/// ✕ that cleared it — the two things a scope control has to do. The toolbar
	/// slot is now free to be about *this pane*, which is why it can disappear
	/// when the pane has nothing to offer instead of being a permanent button
	/// that opens a menu of things the user rarely wants.
	/// The overflow menu: what this pane can do, plus the app-wide extras that
	/// used to sit in the toolbar as a button of their own.
	///
	/// It replaced a standalone diagnostics button at the right edge, which was a
	/// permanent icon for something rarely needed. Nothing here is specific to a
	/// pane except the groups, so the button stays available on every pane.
	private func overflowMenu(_ groups: [PaneActionGroup]) -> some View {
		Menu {
			ForEach(groups) { group in
				Section(group.title) {
					ForEach(group.actions) { action in
						menuEntry(action)
					}
				}
			}
			if !groups.isEmpty { Divider() }
			Button {
				showDiagnostics = true
			} label: {
				Label(
					diagnosticCount > 0
						? String(
							format: L.t("pane.diagnostics.titleWithCount", "诊断（%d 个问题）"),
							diagnosticCount
						)
						: L.t("pane.diagnostics.title", "诊断"),
					systemImage: diagnosticCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal"
				)
			}
		} label: {
			Label(L.t("menu.paneActions", "面板操作"), systemImage: "ellipsis.circle")
				.labelStyle(.iconOnly)
		}
		// No `.menuIndicator(.hidden)`: the project menu on the left shows the
		// standard chevron, and a menu button that hides it reads as a plain
		// button that does something on click rather than opening a list.
		.help(L.t("help.paneActions", "这个面板提供的操作，以及诊断信息"))
	}

	/// The project scope picker, back in the toolbar where it was.
	private var projectMenu: some View {
		Menu {
			ProjectScopeMenu()
		} label: {
			Label(model.projects.currentShortLabel, systemImage: model.projectURL == nil ? "globe" : "folder")
				.labelStyle(.titleAndIcon)
				.lineLimit(1)
		}
		.help(
			String(
				format: L.t("help.projectScope", "项目作用域：%@"),
				model.projects.currentDisplayPath
			)
		)
	}

	/// One entry, or one submenu. Nesting stops at two levels on purpose: the
	/// only action that needs a second level today is MCP's "add server", which
	/// has to ask which config layer to write to.
	@ViewBuilder
	private func menuEntry(_ action: PaneAction) -> some View {
		if action.items.isEmpty {
			Button {
				action.perform()
			} label: {
				menuLabel(action)
			}
			.disabled(!action.isEnabled)
		} else {
			Menu {
				ForEach(action.items) { item in
					Button {
						item.perform()
					} label: {
						menuLabel(item)
					}
					.disabled(!item.isEnabled)
				}
			} label: {
				menuLabel(action)
			}
			.disabled(!action.isEnabled)
		}
	}

	/// An entry names an SF Symbol or it does not, and it is either a human
	/// label or a path. Project and config paths get the capped, middle-truncated
	/// treatment and a tooltip; inventing an icon for them would be noise, and
	/// letting them size the menu is what broke the layout.
	@ViewBuilder
	private func menuLabel(_ action: PaneAction) -> some View {
		if let systemImage = action.systemImage {
			Label(action.title, systemImage: systemImage)
		} else if action.titleMaxWidth != nil {
			MenuPathText(path: action.title)
				.help(action.title)
		} else {
			Text(action.title)
		}
	}

	private var diagnosticCount: Int {
		((model.selectedAgent?.issues ?? []) + model.globalIssues)
			.filter { $0.severity >= .warning }
			.count
	}

	@ViewBuilder
	private var detail: some View {
		if let agent = model.selectedAgent, let surface = model.selectedSurface {
			switch surface.kind {
			case .settings:
				SettingsPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .mcp:
				MCPPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .instructions:
				InstructionsPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .subagents:
				SubagentsPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .sessions:
				SessionsPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .skills:
				SkillsPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .models:
				ModelsPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .resources:
				ResourcesPane(agent: agent, surface: surface)
					.id("\(agent.id)/\(surface.id)")
			case .unsupported(let raw):
				UnsupportedPane(kind: raw, surface: surface)
			}
		} else {
			EmptyStateView(
				icon: "square.stack.3d.up.slash",
				title: L.t("empty.noAgents.title", "没有可用的 Agent"),
				message: L.t(
					"empty.noAgents.message",
					"把一份描述文件 JSON 放到 ~/.config/agentkit/agents/ 就能接入一个 agent。应用内置了一份 pi 的描述文件作为例子。"
				)
			)
		}
	}
}

/// A surface kind this build does not implement.
struct UnsupportedPane: View {
	let kind: String
	let surface: SurfaceSpec

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				StatusBadge(text: L.t("badge.unsupported", "不支持"), level: .warning)
			}
			InfoBanner(
				kind: .warning,
				title: String(format: L.t("pane.unsupported.title", "本版本不认识面板类型 “%@”"), kind),
				detail: L.t(
					"pane.unsupported.detail",
					"描述文件比这个 App 新。其余面板不受影响；升级 AgentKit，或者把该面板的类型改成本版本支持的取值。"
				)
			)
			Spacer()
		}
		.padding(16)
	}
}

struct DiagnosticsSheet: View {
	let issues: [DescriptorIssue]
	let onClose: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Text(L.t("pane.diagnostics.title", "诊断")).font(.headline)
				Spacer()
				Button(L.t("button.close", "关闭"), action: onClose)
					.keyboardShortcut(.defaultAction)
			}
			.padding(14)
			Divider()
			if issues.isEmpty {
				EmptyStateView(icon: "checkmark.seal", title: L.t("empty.noIssues", "没有发现问题"))
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 10) {
						ForEach(issues) { issue in
							HStack(alignment: .top, spacing: 9) {
								Image(systemName: icon(for: issue.severity))
									.foregroundStyle(color(for: issue.severity))
								VStack(alignment: .leading, spacing: 3) {
									Text(issue.message).font(.callout.weight(.medium))
									if let detail = issue.detail {
										Text(detail)
											.font(.caption)
											.foregroundStyle(.secondary)
											.textSelection(.enabled)
											.fixedSize(horizontal: false, vertical: true)
									}
									if let surface = issue.surfaceID {
										Text(String(format: L.t("diagnostics.paneLabel", "面板：%@"), surface))
											.font(.caption2)
											.foregroundStyle(.tertiary)
									}
								}
								Spacer(minLength: 0)
							}
							.padding(10)
							.background(
								RoundedRectangle(cornerRadius: 8, style: .continuous)
									.fill(color(for: issue.severity).opacity(0.08))
							)
						}
					}
					.padding(14)
				}
			}
		}
		.frame(minWidth: 520, minHeight: 380)
	}

	private func icon(for severity: DescriptorIssue.Severity) -> String {
		switch severity {
		case .info: return "info.circle.fill"
		case .warning: return "exclamationmark.triangle.fill"
		case .error: return "xmark.octagon.fill"
		}
	}

	private func color(for severity: DescriptorIssue.Severity) -> Color {
		switch severity {
		case .info: return .accentColor
		case .warning: return .orange
		case .error: return .red
		}
	}
}
