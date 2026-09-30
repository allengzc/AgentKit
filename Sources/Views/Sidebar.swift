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
		VStack(spacing: 0) {
			agentHeader
			Divider()
			// The binding exists because `List` needs one; the model stays the
			// source of truth so the choice can be remembered (`selectSurface`).
			List(selection: Binding(
				get: { model.selectedSurfaceID },
				set: { model.selectSurface(id: $0) }
			)) {
				Section(L.t("sidebar.section.panels", "面板")) {
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
				AgentBadge(descriptor: model.selectedAgent?.descriptor)
				if model.agents.count > 1 {
					Picker("", selection: Binding(
						get: { model.selectedAgentID ?? "" },
						set: { model.selectAgent(id: $0) }
					)) {
						ForEach(model.agents) { agent in
							Text(agent.name).tag(agent.id)
						}
					}
					.labelsHidden()
					.pickerStyle(.menu)
				} else {
					Text(model.selectedAgent?.name ?? L.t("sidebar.noAgent", "未检测到 Agent"))
						.font(.headline)
				}
				Spacer(minLength: 0)
			}

			if let agent = model.selectedAgent {
				// Skipped entirely when there is nothing to badge: an empty
				// HStack still costs a `spacing`-sized gap above the version
				// row, and the version moved out of this row.
				if agent.origin == .user || !agent.rootExists {
					HStack(spacing: 5) {
						if agent.origin == .user {
							StatusBadge(text: L.t("badge.customDescriptor", "自定义描述"), level: .info)
						}
						if !agent.rootExists {
							StatusBadge(text: L.t("badge.notInstalled", "未安装"), level: .warning)
						}
					}
				}
				versionRow(agent)
				PathChip(path: agent.rootURL.path)
				// The scope chip is the project menu now. It already showed which
				// project is in scope and the ✕ that clears it, so selecting one
				// belongs here rather than in the toolbar — and the toolbar slot
				// is free to be about the pane instead (see `PaneActions.swift`).
				//
				// It is enabled in global scope too, unlike the button this
				// replaced: that button existed only to clear a scope that was
				// not set, while this one is how you set it in the first place.
				Menu {
					ProjectScopeMenu()
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
					.contentShape(Rectangle())
				}
				.menuStyle(.borderlessButton)
				.menuIndicator(.hidden)
				// A Menu with a hand-built label gets no accessibility name from
				// SwiftUI — this control came out of the AX tree unnamed, which
				// is also how a screen reader would have met it.
				.accessibilityLabel(
					Text(
						String(
							format: L.t("help.projectScope", "项目作用域：%@"),
							model.projects.currentDisplayPath
						)
					)
				)
				.help(
					model.projectURL == nil
						? L.t("help.projectGlobalScope", "当前是全局作用域，点一下选择项目")
						: L.t("help.projectScopeMenu", "点一下切换项目作用域")
				)
			} else {
				Text(
					L.t(
						"sidebar.addAgentHint",
						"把一份描述文件 JSON 放进 ~/.config/agentkit/agents/ 即可接入新的 agent"
					)
				)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
	}

	/// The CLI version line: `版本  0.87.1  ⟳`.
	///
	/// This replaces a bare muted badge that only existed once a version had been
	/// read, so "we could not read it", "the lookup is still running" and "this
	/// agent has no CLI at all" all looked like the header simply had no version.
	/// A label, an always-present value and a refresh button make it an answer to
	/// a question the user asked, and the raw `--version` output stays one hover
	/// away — the parenthesised product name (`2.1.283 (Claude Code)`) is what
	/// tells two installs apart, and the row itself only has 210pt to work with.
	private func versionRow(_ agent: LoadedAgent) -> some View {
		HStack(spacing: 5) {
			Text(L.t("sidebar.version.label", "版本"))
				.font(.caption)
				.foregroundStyle(.secondary)
			if let number = parsedVersionNumber(agent.cliVersion) {
				Text(number)
					.font(.system(.caption, design: .monospaced))
					.lineLimit(1)
					.truncationMode(.middle)
			} else if model.cliResolving {
				// Separate from 未知 on purpose: a lookup is in flight, and the
				// answer is not in yet rather than absent.
				Text(L.t("badge.lookingUpCLI", "查找 CLI…"))
					.font(.caption)
					.lineLimit(1)
			} else {
				Text(L.t("sidebar.version.unknown", "未知"))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer(minLength: 0)
			Button {
				model.refreshCLIVersion(for: agent.id)
			} label: {
				Image(systemName: "arrow.clockwise")
					.font(.caption2)
			}
			.buttonStyle(.borderless)
			// Enabled even when nothing was found: a lookup that came back empty
			// is exactly when the user wants to try again. The spinner-free
			// feedback is the row switching to 查找 CLI….
			.help(L.t("sidebar.version.refreshHelp", "重新查询 CLI 版本"))
		}
		// The label and the button are fixed width and the number is `lineLimit(1)`
		// with middle truncation, which is what keeps this on one line at the
		// sidebar's 210pt minimum instead of wrapping the version to a second row.
		.help(versionHoverText(agent))
	}

	/// The version number inside `--version` output.
	///
	/// An unparseable line falls back to the raw first line rather than to
	/// nothing: `L.t("sidebar.version.unknown")` should mean "no CLI answered",
	/// not "the CLI answered in a shape we did not expect" — the raw text is
	/// still the most useful thing to show.
	private func parsedVersionNumber(_ raw: String?) -> String? {
		guard let raw, !raw.isEmpty else { return nil }
		if let number = CLILocator.parseVersion(from: raw)?.number { return number }
		return raw
	}

	/// What the hover shows: the raw `--version` line and which binary answered,
	/// e.g. `0.87.1\n/Users/…/bin/pi`.
	private func versionHoverText(_ agent: LoadedAgent) -> String {
		var lines: [String] = []
		if let raw = agent.cliVersion, !raw.isEmpty {
			lines.append(raw)
		} else {
			lines.append(L.t("sidebar.version.unknown", "未知"))
		}
		if let url = agent.cliURL { lines.append(url.path) }
		return lines.joined(separator: "\n")
	}

	/// The scope menu behind the chip.
	///
	/// A menu is as wide as its widest row, and rows here are file paths, so the
	/// menu followed the longest project in the list: measured at 587pt with an
	/// 82-character path in it, against 235pt of sidebar it drops out of.
	/// `MenuPathText` is what puts a ceiling on that; see its note for why the
	/// ceiling has to be a fixed width rather than a `maxWidth`. Truncating in
	/// the middle keeps the head (which tree) and the leaf (which project) and
	/// drops what two paths most often share; `.help` keeps the whole path one
	/// hover away.
	private func surfaceRow(_ surface: SurfaceSpec) -> some View {
		HStack(spacing: 8) {
			Image(systemName: surface.icon ?? "square.dashed")
				.frame(width: 18)
				.foregroundStyle(surface.isSupported ? Color.accentColor : Color.secondary)
			Text(surface.titleText)
				.lineLimit(1)
			Spacer(minLength: 0)
			if !surface.isSupported {
				Image(systemName: "questionmark.circle")
					.font(.caption2)
					.foregroundStyle(.orange)
					.help(L.t("help.unsupportedPane", "本版本不支持这个面板类型"))
			}
			if SurfacePaths.requiresProject(surface) && model.projectURL == nil {
				Image(systemName: "folder.badge.questionmark")
					.font(.caption2)
					.foregroundStyle(.tertiary)
					.help(L.t("help.needsProject", "需要先选择一个项目目录"))
			}
		}
	}

	private var footer: some View {
		VStack(alignment: .leading, spacing: 6) {
			if model.isSelectedAgentRunning {
				// The only place this is shown. It used to appear in the toolbar
				// too, where macOS grouped it with the ⋯ button into one capsule
				// — the same sentence twice, and an odd-looking control.
				Label(
					String(
						format: L.t("agent.running", "%@ 正在运行"),
						model.selectedAgent?.descriptor.detect?.cli?.name ?? "CLI"
					),
					systemImage: "bolt.horizontal.circle"
				)
					.font(.caption2)
					.foregroundStyle(.orange)
					.help(L.t("help.reloadNeeded", "配置改动需要 /reload 或重启才会生效"))
			}
			let issues = (model.selectedAgent?.issues ?? []) + model.globalIssues
			let problems = issues.filter { $0.severity >= .warning }
			if !problems.isEmpty {
				Label(
					String(format: L.t(problems.count == 1 ? "sidebar.diagnosticsCount.one" : "sidebar.diagnosticsCount", "%d 条诊断"), problems.count),
					systemImage: "exclamationmark.triangle"
				)
					.font(.caption2)
					.foregroundStyle(.orange)
			}
			HStack {
				Text("\(L.t("sidebar.reloadedAt", "重新载入于")) \(model.lastReload, style: .time)")
					.font(.caption2)
					.foregroundStyle(.tertiary)
				Spacer()
				Button {
					model.reloadDescriptors()
				} label: {
					Image(systemName: "arrow.clockwise")
				}
				.buttonStyle(.borderless)
				.help(L.t("menu.reload", "重新载入描述文件与配置"))
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}
}
