//
//  InstructionsPane.swift
//  AgentKit
//
//  全局指令：AGENTS.md、AGENTS.override.md、SYSTEM.md、APPEND_SYSTEM.md，
//  以及当前项目目录沿途会命中的项目级指令文件。
//
//  The list selects a *declared slot*, not a filesystem path. That distinction is
//  the whole point: a path string round-trips through SwiftUI's selection and then
//  gets handed to `URL(fileURLWithPath:)`, which resolves a relative path against
//  the process working directory — and a GUI app's working directory is `/`. The
//  pane therefore used to open `/AGENTS.MD` when the uppercase slot was picked.
//  Selecting by slot means the editor's URL can only ever come from the resolver.
//

import SwiftUI

struct InstructionsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var selection: Slot?
	@State private var discovered: [DiscoveredInstruction] = []
	@State private var token = UUID()

	/// Which row is selected. Never a resolved URL, so a stale or malformed
	/// selection falls back to a real entry instead of inventing a path.
	private enum Slot: Hashable {
		/// A slot declared by the descriptor, identified by its path template.
		case declared(String)
		/// A file found by walking up from the project directory.
		case project(String)
	}

	private struct Declaration {
		let spec: InstructionFileSpec
		let url: URL
		/// The last path component of an earlier slot that resolves to this same
		/// file, or nil. On a case-insensitive volume `AGENTS.md` and `AGENTS.MD`
		/// are one file, and showing it twice without saying so is confusing.
		let duplicateOf: String?
	}

	struct DiscoveredInstruction: Identifiable {
		let url: URL
		var id: String { url.path }
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	// MARK: - Entries

	private var declared: [Declaration] {
		let resolved = (surface.files ?? []).compactMap { spec -> (InstructionFileSpec, URL)? in
			guard let url = try? resolver.expand(spec.path) else { return nil }
			return (spec, url)
		}
		return resolved.enumerated().map { index, item in
			let earlier = resolved.prefix(index).first { PathResolver.isSameFile($0.1, item.1) }
			return Declaration(spec: item.0, url: item.1, duplicateOf: earlier?.1.lastPathComponent)
		}
	}

	/// The selected slot, or the first one that makes sense when nothing is
	/// selected — preferring a file that exists, since the first declared slot is
	/// often an unused override.
	private var activeSlot: Slot? {
		switch selection {
		case .declared(let template) where declared.contains(where: { $0.spec.path == template }):
			return selection
		case .project(let path) where discovered.contains(where: { $0.url.path == path }):
			return selection
		default:
			let existing = declared.first { FileManager.default.fileExists(atPath: $0.url.path) }
			return (existing ?? declared.first).map { Slot.declared($0.spec.path) }
		}
	}

	private var activeDeclaration: Declaration? {
		guard case .declared(let template) = activeSlot else { return nil }
		return declared.first { $0.spec.path == template }
	}

	private var activeProject: DiscoveredInstruction? {
		guard case .project(let path) = activeSlot else { return nil }
		return discovered.first { $0.url.path == path }
	}

	// MARK: - Body

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
				Text(surface.titleText).font(.title3.weight(.semibold))
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
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 1) {
				sectionLabel("全局")
				ForEach(declared, id: \.spec.path) { item in
					declaredRow(item)
				}
				if !discovered.isEmpty {
					sectionLabel("项目（只读展示）")
					ForEach(discovered) { item in
						projectRow(item)
					}
				}
			}
			.padding(.vertical, 6)
			.padding(.horizontal, 6)
		}
		.frame(width: 268)
		.background(Color(nsColor: .controlBackgroundColor))
	}

	private func sectionLabel(_ text: String) -> some View {
		Text(text)
			.font(.caption2.weight(.semibold))
			.foregroundStyle(.tertiary)
			.padding(.horizontal, 6)
			.padding(.top, 6)
			.padding(.bottom, 2)
	}

	private func declaredRow(_ item: Declaration) -> some View {
		let exists = FileManager.default.fileExists(atPath: item.url.path)
		let isSelected = activeSlot == .declared(item.spec.path)
		return Button {
			selection = .declared(item.spec.path)
		} label: {
			HStack(spacing: 7) {
				Image(systemName: exists ? "doc.text.fill" : "doc.text")
					.font(.caption)
					.foregroundStyle(exists ? Color.accentColor : Color.secondary)
				VStack(alignment: .leading, spacing: 1) {
					Text(item.url.lastPathComponent)
						.font(.callout)
						.lineLimit(1)
					Text(roleLabel(item.spec.role ?? "instructions"))
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(1)
				}
				Spacer(minLength: 0)
				if let duplicate = item.duplicateOf {
					StatusBadge(text: "同 \(duplicate)", level: .muted)
				} else if !exists {
					Text("缺失").font(.caption2).foregroundStyle(.tertiary)
				}
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 7)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(item.url.path)
	}

	private func projectRow(_ item: DiscoveredInstruction) -> some View {
		let isSelected = activeSlot == .project(item.url.path)
		return Button {
			selection = .project(item.url.path)
		} label: {
			HStack(spacing: 7) {
				Image(systemName: "doc.text")
					.font(.caption)
					.foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 1) {
					Text(item.url.lastPathComponent)
						.font(.callout)
						.lineLimit(1)
					Text(item.url.deletingLastPathComponent().path)
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.lineLimit(1)
						.truncationMode(.head)
				}
				Spacer(minLength: 0)
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 7)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(item.url.path)
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

	// MARK: - Editor

	@ViewBuilder
	private var editor: some View {
		if let item = activeDeclaration {
			VStack(alignment: .leading, spacing: 0) {
				if let duplicate = item.duplicateOf {
					InfoBanner(
						kind: .info,
						title: "和 \(duplicate) 是同一个文件",
						detail: "描述文件里声明了两个名字，但这个卷不区分大小写，它们指向同一个文件。改哪一个都一样。"
					)
					.padding(.horizontal, 14)
					.padding(.top, 12)
				}
				MarkdownEditorView(url: item.url, resolver: resolver, policy: policy)
					.padding(14)
					.id(item.url.path)
			}
		} else if let item = activeProject {
			VStack(alignment: .leading, spacing: 8) {
				InfoBanner(
					kind: .info,
					title: "项目级指令只读展示",
					detail: "它属于项目本身，AgentKit 不在这里改它。需要修改请用下面的按钮。"
				)
				HStack {
					Button("用默认应用打开") { ShellActions.openExternally(item.url) }
					Button("在 Finder 中显示") { ShellActions.reveal(item.url) }
					Spacer()
				}
				ScrollView {
					MarkdownPreview(text: (try? String(contentsOf: item.url, encoding: .utf8)) ?? "")
						.padding(12)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
			}
			.padding(14)
		} else {
			EmptyStateView(icon: "text.book.closed", title: "没有可编辑的指令文件")
		}
	}

	// MARK: - Discovery

	/// Walks up from the project directory collecting the declared filenames.
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
				guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
				// The same file can be reachable by two declared names; keep one.
				if found.contains(where: { PathResolver.isSameFile($0.url, candidate) }) { continue }
				if declared.contains(where: { PathResolver.isSameFile($0.url, candidate) }) { continue }
				found.append(DiscoveredInstruction(url: candidate))
			}
			let parent = directory.deletingLastPathComponent()
			if parent.path == directory.path { break }
			// Stop at the repository root when there is one.
			if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { break }
			directory = parent
			depth += 1
		}
		discovered = found
	}
}
