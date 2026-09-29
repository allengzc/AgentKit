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

	var body: some View {
		NavigationSplitView {
			Sidebar()
		} detail: {
			detail
		}
		.navigationTitle(model.selectedAgent.map { "\($0.name) · \($0.descriptor.subtitle ?? "配置")" } ?? "AgentKit")
		.navigationSubtitle(model.selectedAgent?.descriptor.subtitle ?? "")
		.toolbar {
			ToolbarItem(placement: .navigation) {
				projectMenu
			}
			ToolbarItem(placement: .automatic) {
				if model.isSelectedAgentRunning {
					Label(
						"\(model.selectedAgent?.descriptor.detect?.cli?.name ?? "CLI") 正在运行",
						systemImage: "bolt.horizontal.circle"
					)
					.font(.caption)
					.foregroundStyle(.orange)
					.help("配置改动需要 /reload 或重启才会生效")
				}
			}
			ToolbarItem(placement: .automatic) {
				Button {
					showDiagnostics = true
				} label: {
					Label("诊断", systemImage: diagnosticCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal")
				}
				.help("描述文件与配置的诊断信息")
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

	/// Project scope: without a directory selected, every `$CWD` path in the
	/// descriptor is unreachable, and the panes that depend on them say so.
	private var projectMenu: some View {
		Menu {
			Button {
				model.projects.select(nil)
			} label: {
				Label(
					"全局（不加载项目配置）",
					systemImage: model.projectURL == nil ? "checkmark" : "globe"
				)
			}
			if !model.projects.menuEntries.isEmpty {
				Divider()
				ForEach(model.projects.menuEntries, id: \.path) { url in
					Button {
						model.projects.select(url)
					} label: {
						Text(url.path)
					}
				}
			}
			Divider()
			Button("选择目录…") { model.projects.chooseWithPanel() }
			Button("在 Finder 中显示当前项目") {
				if let project = model.projectURL { ShellActions.reveal(project) }
			}
			.disabled(model.projectURL == nil)
			if model.projects.scanning {
				Divider()
				Text("正在从会话历史中整理项目…")
			}
		} label: {
			Label(model.projects.currentLabel, systemImage: model.projectURL == nil ? "globe" : "folder")
		}
		.help("项目作用域：" + model.projects.currentDisplayPath)
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
				title: "没有可用的 Agent",
				message: "把一份描述文件 JSON 放到 ~/.config/agentkit/agents/ 就能接入一个 agent。应用内置了一份 pi 的描述文件作为例子。"
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
				Text(surface.title).font(.title3.weight(.semibold))
				StatusBadge(text: "不支持", level: .warning)
			}
			InfoBanner(
				kind: .warning,
				title: "本版本不认识面板类型 “\(kind)”",
				detail: "描述文件比这个 App 新。其余面板不受影响；升级 AgentKit，或者把该面板的类型改成本版本支持的取值。"
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
				Text("诊断").font(.headline)
				Spacer()
				Button("关闭", action: onClose)
					.keyboardShortcut(.defaultAction)
			}
			.padding(14)
			Divider()
			if issues.isEmpty {
				EmptyStateView(icon: "checkmark.seal", title: "没有发现问题")
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
										Text("面板：\(surface)")
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
