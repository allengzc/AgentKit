//
//  Sidebar.swift
//  AgentKit
//
//  Agent picker plus the list of surfaces the selected descriptor declares.
//

import SwiftUI

struct Sidebar: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model

		return VStack(spacing: 0) {
			agentHeader
			Divider()
			List(selection: $model.selectedSurfaceID) {
				Section("面板") {
					ForEach(model.selectedAgent?.descriptor.surfaces ?? [], id: \.id) { surface in
						surfaceRow(surface)
							.tag(surface.id as String?)
					}
				}
			}
			.listStyle(.sidebar)
			Divider()
			footer
		}
		.frame(minWidth: 210, idealWidth: 235)
	}

	private var agentHeader: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Image(systemName: model.selectedAgent?.descriptor.icon ?? "cpu")
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(.tint)
				if model.agents.count > 1 {
					Picker("", selection: Binding(
						get: { model.selectedAgentID ?? "" },
						set: { newValue in
							model.selectedAgentID = newValue
							model.selectedSurfaceID = model.selectedAgent?.descriptor.surfaces.first?.id
						}
					)) {
						ForEach(model.agents) { agent in
							Text(agent.name).tag(agent.id)
						}
					}
					.labelsHidden()
					.pickerStyle(.menu)
				} else {
					Text(model.selectedAgent?.name ?? "未检测到 Agent")
						.font(.headline)
				}
				Spacer(minLength: 0)
			}

			if let agent = model.selectedAgent {
				HStack(spacing: 5) {
					if agent.origin == .user {
						StatusBadge(text: "自定义描述", level: .info)
					}
					if !agent.rootExists {
						StatusBadge(text: "未安装", level: .warning)
					}
					if let version = agent.cliVersion {
						StatusBadge(text: version, level: .muted)
					} else if model.cliResolving {
						StatusBadge(text: "查找 CLI…", level: .muted)
					}
				}
				PathChip(path: agent.rootURL.path)
				Button {
					model.projects.select(nil)
				} label: {
					HStack(spacing: 5) {
						Image(systemName: model.projectURL == nil ? "globe" : "folder")
							.font(.caption2)
						Text(model.projects.currentDisplayPath)
							.font(.caption2)
							.lineLimit(1)
							.truncationMode(.head)
						if model.projectURL != nil {
							Image(systemName: "xmark.circle.fill")
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
					.foregroundStyle(model.projectURL == nil ? Color.secondary : Color.accentColor)
				}
				.buttonStyle(.plain)
				.disabled(model.projectURL == nil)
				.help(model.projectURL == nil ? "当前是全局作用域，项目级配置不会被加载" : "点一下回到全局作用域")
			} else {
				Text("把一份描述文件 JSON 放进 ~/.config/agentkit/agents/ 即可接入新的 agent")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
	}

	private func surfaceRow(_ surface: SurfaceSpec) -> some View {
		HStack(spacing: 8) {
			Image(systemName: surface.icon ?? "square.dashed")
				.frame(width: 18)
				.foregroundStyle(surface.isSupported ? Color.accentColor : Color.secondary)
			Text(surface.title)
				.lineLimit(1)
			Spacer(minLength: 0)
			if !surface.isSupported {
				Image(systemName: "questionmark.circle")
					.font(.caption2)
					.foregroundStyle(.orange)
					.help("本版本不支持这个面板类型")
			}
			if SurfacePaths.requiresProject(surface) && model.projectURL == nil {
				Image(systemName: "folder.badge.questionmark")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.help("需要先选择一个项目目录")
			}
		}
	}

	private var footer: some View {
		VStack(alignment: .leading, spacing: 6) {
			if model.isSelectedAgentRunning {
				Label("\(model.selectedAgent?.descriptor.detect?.cli?.name ?? "CLI") 正在运行", systemImage: "bolt.horizontal.circle")
					.font(.caption2)
					.foregroundStyle(.orange)
					.help("配置改动需要 /reload 或重启才会生效")
			}
			let issues = (model.selectedAgent?.issues ?? []) + model.globalIssues
			let problems = issues.filter { $0.severity >= .warning }
			if !problems.isEmpty {
				Label("\(problems.count) 条诊断", systemImage: "exclamationmark.triangle")
					.font(.caption2)
					.foregroundStyle(.orange)
			}
			HStack {
				Text("重新载入于 \(model.lastReload, style: .time)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				Spacer()
				Button {
					model.reloadDescriptors()
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.help("重新读取描述文件与配置")
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}
}
