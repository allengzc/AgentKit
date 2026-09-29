//
//  InstructionsPane.swift
//  AgentKit
//
//  全局指令：AGENTS.md、AGENTS.override.md、SYSTEM.md、APPEND_SYSTEM.md，
//  以及当前项目目录沿途会命中的项目级指令文件。
//

import SwiftUI

struct InstructionsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var selectedPath: String?
	@State private var discovered: [DiscoveredInstruction] = []
	@State private var token = UUID()

	struct DiscoveredInstruction: Identifiable {
		let url: URL
		let content: String
		var id: String { url.path }
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	private var entries: [(spec: InstructionFileSpec, url: URL)] {
		(surface.files ?? []).compactMap { spec in
			guard let url = try? resolver.expand(spec.path) else { return nil }
			return (spec, url)
		}
	}

	private var activeURL: URL? {
		if let selectedPath { return URL(fileURLWithPath: selectedPath) }
		// Default to a file that actually exists; the first declared slot is
		// often an unused override.
		return entries.first { FileManager.default.fileExists(atPath: $0.url.path) }?.url
			?? entries.first?.url
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			HStack(spacing: 0) {
				fileList
				Divider()
				editor
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.task(id: token) { discover() }
		.onChange(of: model.projectURL) { _, _ in discover() }
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Text(surface.title).font(.title3.weight(.semibold))
				StatusBadge(text: "同目录下 override 覆盖 instructions", level: .info)
				Spacer()
				Button {
					discover()
				} label: {
					Label("重新读取", systemImage: "arrow.clockwise")
				}
				.controlSize(.small)
			}
			Text("这些文件对所有工作目录生效。\(resolver.cwd == nil ? "选中一个项目后，还会列出沿途命中的项目级指令。" : "当前项目：\(resolver.cwd!.path)")")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(14)
	}

	private var fileList: some View {
		List(selection: $selectedPath) {
			Section("全局") {
				ForEach(entries, id: \.spec.path) { entry in
					row(
						url: entry.url,
						role: entry.spec.role ?? "instructions",
						tag: entry.url.path
					)
				}
			}
			if !discovered.isEmpty {
				Section("项目（只读展示）") {
					ForEach(discovered) { item in
						row(url: item.url, role: "project", tag: item.url.path)
					}
				}
			}
		}
		.frame(width: 260)
		.listStyle(.sidebar)
	}

	private func row(url: URL, role: String, tag: String) -> some View {
		let exists = FileManager.default.fileExists(atPath: url.path)
		return HStack(spacing: 7) {
			Image(systemName: exists ? "doc.text.fill" : "doc.text")
				.font(.caption)
				.foregroundStyle(exists ? Color.accentColor : Color.secondary)
			VStack(alignment: .leading, spacing: 1) {
				Text(url.lastPathComponent)
					.font(.callout)
					.lineLimit(1)
				Text(roleLabel(role))
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
			Spacer(minLength: 0)
			if !exists {
				Text("缺失").font(.caption2).foregroundStyle(.tertiary)
			}
		}
		.tag(tag as String?)
	}

	private func roleLabel(_ role: String) -> String {
		switch role {
		case "override": return "覆盖同目录的 AGENTS.md / CLAUDE.md"
		case "instructions": return "全局指令"
		case "system-replace": return "替换系统提示"
		case "system-append": return "追加到系统提示"
		case "project": return "项目级指令（只读）"
		default: return role
		}
	}

	@ViewBuilder
	private var editor: some View {
		if let url = activeURL {
			if discovered.contains(where: { $0.url == url }) {
				VStack(alignment: .leading, spacing: 8) {
					InfoBanner(
						kind: .info,
						title: "项目级指令只读展示",
						detail: "它属于项目本身，AgentKit 不在这里改它。需要修改请用下面的按钮。"
					)
					HStack {
						Button("用默认应用打开") { ShellActions.openExternally(url) }
						Button("在 Finder 中显示") { ShellActions.reveal(url) }
						Spacer()
					}
					ScrollView {
						MarkdownPreview(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
							.padding(12)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
				}
				.padding(14)
			} else {
				MarkdownEditorView(url: url, resolver: resolver, policy: policy)
					.padding(14)
					.id(url.path)
			}
		} else {
			EmptyStateView(icon: "text.book.closed", title: "没有可编辑的指令文件")
		}
	}

	/// Walks up from the project directory collecting AGENTS.md / CLAUDE.md.
	private func discover() {
		guard let start = resolver.cwd,
			let names = surface.discovery?.filenames, !names.isEmpty
		else {
			discovered = []
			return
		}
		var found: [DiscoveredInstruction] = []
		var directory = start
		var depth = 0
		while depth < 12 {
			for name in names {
				let candidate = directory.appendingPathComponent(name)
				if FileManager.default.fileExists(atPath: candidate.path) {
					let content = (try? String(contentsOf: candidate, encoding: .utf8)) ?? ""
					found.append(DiscoveredInstruction(url: candidate, content: content))
				}
			}
			let parent = directory.deletingLastPathComponent()
			if parent.path == directory.path { break }
			// Stop at the repository root when there is one.
			if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { break }
			directory = parent
			depth += 1
		}
		discovered = found
		if selectedPath == nil {
			selectedPath = entries.first { FileManager.default.fileExists(atPath: $0.url.path) }?.url.path
				?? entries.first?.url.path
		}
	}
}
