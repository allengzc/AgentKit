//
//  SessionsPane.swift
//  AgentKit
//
//  会话：浏览、搜索、在终端恢复、导出 HTML、重命名、删除。
//
//  统计信息（消息数、token、成本）在后台流式计算并缓存，列表本身只用每个
//  文件的第一行，所以打开 100 多个会话不会卡住窗口。
//

import SwiftUI

struct SessionsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var records: [SessionRecord] = []
	@State private var query = ""
	@State private var selectedID: String?
	@State private var grouping: Grouping = .project
	@State private var indexing = false
	@State private var indexed = 0
	@State private var banner: String?
	@State private var errorText: String?
	@State private var renaming: SessionRecord?
	@State private var renameText = ""
	@State private var confirmDelete: SessionRecord?
	@State private var exportTarget: SessionRecord?
	@State private var token = UUID()

	enum Grouping: String, CaseIterable, Identifiable {
		case project
		case time
		var id: String { rawValue }
		var title: String {
			self == .project
				? L.t("sessions.grouping.project", "按项目")
				: L.t("sessions.grouping.time", "按时间")
		}
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	private var config: SessionsConfig? {
		SessionsConfig.resolve(surface: surface, resolver: resolver, policy: policy)
	}

	/// Renaming works by appending a record, which only agents that declare a
	/// name entry type support.
	private var supportsRename: Bool { config?.nameEntryType != nil }

	/// File size in the app's language. A plain `ByteCountFormatter` would follow
	/// the system locale, which in English mode still reads "1.2 MB" in Chinese.
	private func sizeText(_ bytes: Int) -> String {
		Int64(bytes).formatted(
			ByteCountFormatStyle(style: .file).locale(Locale(identifier: Localization.shared.language.rawValue))
		)
	}

	/// True when names live in a sidecar index (Codex), rather than nowhere
	/// (Claude Code). Both disable renaming, for different reasons.
	private var hasIndex: Bool { config?.indexURL != nil }

	private var renameHelp: String {
		if !supportsRename {
			return hasIndex
				? String(
					format: L.t(
						"sessions.rename.unavailableIndex",
						"%@ 的会话名存在索引文件里，AgentKit 不支持在这里改写"
					),
					agent.name
				)
				: String(
					format: L.t(
						"sessions.rename.unavailableNoName",
						"%@ 不在会话文件里保存名字，AgentKit 不支持在这里改写"
					),
					agent.name
				)
		}
		if model.isSelectedAgentRunning {
			return L.t("sessions.rename.agentRunning", "agent 正在运行，改写会话文件不安全")
		}
		return L.t("sessions.rename.append", "追加一条重命名记录")
	}

	private var filtered: [SessionRecord] {
		guard !query.isEmpty else { return records }
		let needle = query.lowercased()
		return records.filter { record in
			record.displayTitle.lowercased().contains(needle)
				|| record.cwd.lowercased().contains(needle)
				|| record.sessionID.lowercased().contains(needle)
				|| record.projectSlug.lowercased().contains(needle)
				|| (record.name?.lowercased().contains(needle) ?? false)
		}
	}

	private var selected: SessionRecord? {
		guard let selectedID else { return filtered.first }
		return filtered.first { $0.id == selectedID } ?? filtered.first
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			HStack(spacing: 0) {
				list
				Divider()
				detail
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.task(id: token) { load() }
		.sheet(item: $renaming) { record in renameSheet(record) }
		.sheet(item: $exportTarget) { record in exportSheet(record) }
		.alert(L.t("sessions.delete.title", "删除这个会话？"), isPresented: Binding(
			get: { confirmDelete != nil },
			set: { if !$0 { confirmDelete = nil } }
		), presenting: confirmDelete) { record in
			Button(L.t("button.moveToTrash", "移到废纸篓"), role: .destructive) {
				do {
					try TextFile.trash(record.url)
					banner = String(
						format: L.t("banner.movedToTrash", "已把 %@ 移到废纸篓"),
						record.url.lastPathComponent
					)
					confirmDelete = nil
					load()
				} catch {
					errorText = error.localizedDescription
					confirmDelete = nil
				}
			}
			Button(L.t("button.cancel", "取消"), role: .cancel) { confirmDelete = nil }
		} message: { record in
			Text(
				String(
					format: L.t("sessions.delete.message", "%@\n\n会移到废纸篓，可以恢复。"),
					record.url.path
				)
			)
		}
	}

	// MARK: - Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				StatusBadge(
					text: String(
						format: L.t(records.count == 1 ? "sessions.badge.sessionCount.one" : "sessions.badge.sessionCount", "%d 个会话"),
						records.count
					),
					level: .info
				)
				if indexing {
					HStack(spacing: 5) {
						ProgressView().controlSize(.mini)
						Text(
							String(
								format: L.t("sessions.indexing", "统计中 %d/%d"),
								indexed,
								records.count
							)
						)
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
				Spacer()
				Picker("", selection: $grouping) {
					ForEach(Grouping.allCases) { option in
						Text(option.title).tag(option)
					}
				}
				.labelsHidden()
				.pickerStyle(.segmented)
				.frame(width: 150)
				Button {
					load()
				} label: {
					Label(L.t("button.reload", "重新读取"), systemImage: "arrow.clockwise")
				}
				.controlSize(.small)
			}
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
				TextField(
					L.t("sessions.searchPlaceholder", "搜索会话名、首条消息、项目路径或 id"),
					text: $query
				)
					.textFieldStyle(.roundedBorder)
			}
			if let banner { InfoBanner(kind: .info, title: banner) }
			if let errorText { InfoBanner(kind: .error, title: errorText) }
		}
		.padding(14)
	}

	// MARK: - List

	private var list: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
				if grouping == .project {
					ForEach(projects, id: \.key) { project in
						Section {
							ForEach(project.records) { record in
								row(record)
							}
						} header: {
							projectHeader(project)
						}
					}
				} else {
					ForEach(filtered) { record in
						row(record)
					}
				}
			}
			.padding(.vertical, 6)
		}
		.frame(width: 380)
		.background(Color(nsColor: .controlBackgroundColor))
	}

	private struct ProjectGroup {
		let key: String
		let cwd: String
		let records: [SessionRecord]
	}

	private var projects: [ProjectGroup] {
		let grouped = Dictionary(grouping: filtered) { record in
			record.cwd.isEmpty ? record.projectSlug : record.cwd
		}
		return grouped
			.map { key, records in
				ProjectGroup(
					key: key,
					cwd: key,
					records: records.sorted { $0.modified > $1.modified }
				)
			}
			.sorted { lhs, rhs in
				(lhs.records.first?.modified ?? .distantPast) > (rhs.records.first?.modified ?? .distantPast)
			}
	}

	private func projectHeader(_ group: ProjectGroup) -> some View {
		VStack(alignment: .leading, spacing: 1) {
			Text(group.cwd)
				.font(.system(size: 11, weight: .semibold, design: .monospaced))
				.lineLimit(1)
				.truncationMode(.head)
			Text(String(format: L.t(group.records.count == 1 ? "sessions.badge.sessionCount.one" : "sessions.badge.sessionCount", "%d 个会话"), group.records.count))
				.font(.caption2)
				.foregroundStyle(.tertiary)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, 4)
		.padding(.horizontal, 8)
		.background(.bar)
	}

	private func row(_ record: SessionRecord) -> some View {
		let isSelected = selected?.id == record.id
		return Button {
			selectedID = record.id
		} label: {
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Text(record.displayTitle)
						.font(.callout)
						.lineLimit(1)
					if record.isFork {
						Image(systemName: "arrow.triangle.branch")
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.help(L.t("sessions.forkedFrom", "从别的会话 fork 而来"))
					}
					Spacer(minLength: 0)
					if record.statsLoaded, record.totalCost > 0 {
						Text(String(format: "$%.3f", record.totalCost))
							.font(.system(size: 10, design: .monospaced))
							.foregroundStyle(.tertiary)
					}
				}
				HStack(spacing: 8) {
					Text(record.modified, format: .dateTime.month(.abbreviated).day().hour().minute())
					if record.statsLoaded {
						Text(String(format: L.t(record.messageCount == 1 ? "sessions.messageCount.one" : "sessions.messageCount", "%d 条消息"), record.messageCount))
						if record.totalTokens > 0 {
							Text("\(formatTokens(record.totalTokens)) tokens")
						}
					} else {
						Text(L.t("sessions.indexingShort", "统计中…"))
					}
					Text(sizeText(record.fileSize))
				}
				.font(.caption2)
				.foregroundStyle(.tertiary)
			}
			.padding(.vertical, 5)
			.padding(.horizontal, 8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	// MARK: - Detail

	@ViewBuilder
	private var detail: some View {
		if let record = selected {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					VStack(alignment: .leading, spacing: 6) {
						Text(record.displayTitle).font(.title3.weight(.semibold))
						if let name = record.name, !name.isEmpty, name != record.firstUserText {
							Text(record.firstUserText ?? "")
								.font(.callout)
								.foregroundStyle(.secondary)
								.lineLimit(3)
						}
						PathChip(path: record.url.path)
					}

					Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
						detailRow(L.t("sessions.detail.id", "会话 id"), record.sessionID, monospaced: true)
						detailRow(
							L.t("sessions.detail.cwd", "工作目录"),
							record.cwd.isEmpty ? "—" : record.cwd,
							monospaced: true
						)
						detailRow(
							L.t("sessions.detail.started", "开始时间"),
							record.started.map { Self.dateFormatter.string(from: $0) } ?? "—"
						)
						detailRow(
							L.t("sessions.detail.modified", "最后修改"),
							Self.dateFormatter.string(from: record.modified)
						)
						detailRow(
							L.t("sessions.detail.messages", "消息数"),
							record.statsLoaded
								? "\(record.messageCount)"
								: L.t("sessions.indexingShort", "统计中…")
						)
						detailRow(
							"Token",
							record.statsLoaded
								? formatTokens(record.totalTokens)
								: L.t("sessions.indexingShort", "统计中…")
						)
						detailRow(
							L.t("sessions.detail.cost", "成本"),
							record.statsLoaded
								? String(format: "$%.4f", record.totalCost)
								: L.t("sessions.indexingShort", "统计中…")
						)
						detailRow(
							L.t("sessions.detail.models", "模型"),
							record.models.isEmpty
								? (record.model ?? "—")
								: record.models.joined(separator: L.t("listSeparator", "、")),
							monospaced: true
						)
						detailRow(
							L.t("sessions.detail.fileSize", "文件大小"),
							ByteCountFormatter.string(fromByteCount: Int64(record.fileSize), countStyle: .file)
						)
						if let parent = record.parentSession {
							detailRow(L.t("sessions.detail.forkedFrom", "fork 自"), parent, monospaced: true)
						}
					}

					Divider()

					HStack(spacing: 8) {
						Button {
							resume(record)
						} label: {
							Label(L.t("button.terminal", "终端"), systemImage: "terminal")
						}
						.disabled(agent.cliURL == nil)

						Button {
							exportTarget = record
						} label: {
							Label(L.t("button.exportHTML", "导出 HTML"), systemImage: "square.and.arrow.up")
						}
						.disabled(agent.cliURL == nil)

						Button {
							renameText = record.name ?? ""
							renaming = record
						} label: {
							Label(L.t("button.rename", "重命名"), systemImage: "pencil")
						}
						.disabled(model.isSelectedAgentRunning || !supportsRename)
						.help(renameHelp)

						Button {
							ShellActions.reveal(record.url)
						} label: {
							Label("Finder", systemImage: "folder")
						}

						Button(role: .destructive) {
							confirmDelete = record
						} label: {
							Label(L.t("button.deleteWithConfirm", "删除"), systemImage: "trash")
						}
					}

					if !supportsRename {
						// Two different reasons, and saying the wrong one is worse
						// than saying nothing: Codex keeps names in a sidecar index
						// that is only read, while Claude Code does not record a
						// renameable name anywhere.
						InfoBanner(
							kind: .info,
							title: L.t(
								"sessions.noRename.title",
								"这个 agent 的会话名不由会话文件保存"
							),
							detail: hasIndex
								? L.t(
									"sessions.noRename.indexDetail",
									"它的名字来自单独的索引文件，AgentKit 只读取，不代写。"
								)
								: L.t(
									"sessions.noRename.noNameDetail",
									"这个 agent 不在会话文件里保存名字，所以 AgentKit 不能替你改名。"
								)
						)
					} else if model.isSelectedAgentRunning {
						InfoBanner(
							kind: .warning,
							title: String(
								format: L.t("sessions.agentRunning.title", "%@ 正在运行"),
								agent.name
							),
							detail: L.t(
								"sessions.agentRunning.detail",
								"重命名会向会话文件追加内容，运行中的 agent 可能同时写这个文件，所以这里先禁用了。"
							)
						)
					}
				}
				.padding(16)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		} else {
			EmptyStateView(
				icon: "clock.arrow.circlepath",
				title: records.isEmpty
					? L.t("empty.noSessions", "还没有会话")
					: L.t("empty.noMatchingSessions", "没有匹配的会话"),
				message: records.isEmpty
					? String(
						format: L.t("empty.noSessions.message", "在 %@ 下没有找到 .jsonl 会话文件。"),
						config?.root.path ?? L.t("sessions.directoryFallback", "会话目录")
					)
					: nil
			)
		}
	}

	private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
		GridRow {
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
				.gridColumnAlignment(.trailing)
			Text(value)
				.font(monospaced ? .system(.caption, design: .monospaced) : .caption)
				.textSelection(.enabled)
				.lineLimit(2)
				.truncationMode(.middle)
		}
	}

	private func formatTokens(_ count: Int) -> String {
		if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
		if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
		return "\(count)"
	}

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return formatter
	}()

	// MARK: - Load / index

	private func load() {
		guard let config else {
			errorText = L.t(
				"error.sessionsLayout",
				"描述文件没有描述这个 agent 的会话布局（缺少 sessions 映射）"
			)
			return
		}
		records = SessionsSurface.enumerate(config: config)
		errorText = nil
		if selectedID == nil || !records.contains(where: { $0.id == selectedID }) {
			selectedID = records.first?.id
		}
		startIndexing()
	}

	private func startIndexing() {
		guard let config else { return }
		let cacheURL = PathResolver.defaultAppSupport.appendingPathComponent("cache/sessions-\(agent.id).json")
		var cache = SessionIndexCache.load(from: cacheURL)
		var pending: [SessionRecord] = []

		for index in records.indices {
			if cache.apply(to: &records[index]) {
				continue
			}
			pending.append(records[index])
		}
		guard !pending.isEmpty else { return }

		indexing = true
		indexed = records.count - pending.count

		Task.detached(priority: .utility) {
			var updated: [String: SessionRecord] = [:]
			var completed = 0
			for var record in pending {
				SessionsSurface.summarize(&record, config: config)
				updated[record.id] = record
				completed += 1
				if completed % 5 == 0 || completed == pending.count {
					let snapshot = updated
					let count = completed
					await MainActor.run {
						for index in self.records.indices {
							if let replacement = snapshot[self.records[index].id] {
								self.records[index] = replacement
							}
						}
						self.indexed = self.records.count - pending.count + count
					}
				}
			}
			await MainActor.run {
				for record in self.records where record.statsLoaded {
					cache.store(record)
				}
				cache.save(to: cacheURL)
				self.indexing = false
			}
		}
	}

	// MARK: - Actions

	private func resume(_ record: SessionRecord) {
		guard let cli = agent.cliURL else { return }
		let command = ShellActions.quote(cli.path) + " --session " + ShellActions.quote(record.url.path)
		ShellActions.openTerminal(
			command: command,
			workingDirectory: record.cwdURL ?? PathResolver.homeDirectory()
		)
	}

	private func exportSheet(_ record: SessionRecord) -> some View {
		let destination = record.url.deletingLastPathComponent()
		return VStack(alignment: .leading, spacing: 12) {
			Text(L.t("sessions.export.title", "导出会话为 HTML")).font(.headline)
			Text(
				String(
					format: L.t("sessions.export.detail", "执行 `%@ --export <会话文件>`，输出目录为："),
					agent.descriptor.detect?.cli?.name ?? "agent"
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
			PathChip(path: destination.path)
			Text(
				L.t(
					"sessions.export.note",
					"文件名由命令行工具生成，导出完成后会自动在 Finder 中显示。"
				)
			)
				.font(.caption2)
				.foregroundStyle(.tertiary)
			HStack {
				Spacer()
				Button(L.t("button.cancel", "取消")) { exportTarget = nil }
				Button(L.t("button.export", "导出")) { runExport(record, to: destination) }
					.buttonStyle(.borderedProminent)
			}
		}
		.padding(16)
		.frame(minWidth: 520)
	}

	private func runExport(_ record: SessionRecord, to destination: URL) {
		exportTarget = nil
		guard let cli = agent.cliURL else { return }
		let executable = cli
		let path = record.url.path
		Task.detached(priority: .userInitiated) {
			let result = AgentProcess.run(
				executable: executable,
				arguments: ["--export", path],
				workingDirectory: destination,
				environment: LoginShell.environment(),
				timeout: 120
			)
			let output = result.combinedOutput
			let exported = output
				.split(separator: "\n")
				.first { $0.hasPrefix("Exported to:") }
				.map { String($0.dropFirst("Exported to:".count)).trimmingCharacters(in: .whitespaces) }
			await MainActor.run {
				if result.succeeded, let exported {
					let url = destination.appendingPathComponent(exported)
					banner = String(format: L.t("sessions.export.banner", "已导出到 %@"), url.path)
					errorText = nil
					ShellActions.reveal(url)
				} else {
					errorText = String(
						format: L.t("sessions.export.error", "导出失败：%@"),
						output.trimmingCharacters(in: .whitespacesAndNewlines)
					)
				}
			}
		}
	}

	private func renameSheet(_ record: SessionRecord) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(L.t("sessions.rename.title", "重命名会话")).font(.headline)
			PathChip(path: record.url.path)
			TextField(L.t("sessions.rename.placeholder", "会话名"), text: $renameText)
				.textFieldStyle(.roundedBorder)
			Text(
				L.t(
					"sessions.rename.detail",
					"这是往会话文件末尾追加一条重命名记录，不改动已有内容。写入前会先在同目录生成一份备份。"
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer()
				Button(L.t("button.cancel", "取消")) { renaming = nil }
				Button(L.t("button.saveImmediate", "保存")) { applyRename(record) }
					.buttonStyle(.borderedProminent)
					.disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
			}
		}
		.padding(16)
		.frame(minWidth: 520)
	}

	private func applyRename(_ record: SessionRecord) {
		guard let config else { return }
		let name = renameText.trimmingCharacters(in: .whitespaces)
		renaming = nil
		do {
			_ = try AtomicFile.backup(record.url, policy: policy)
			try SessionsSurface.appendingName(name, to: record.url, config: config)
			banner = String(format: L.t("sessions.rename.banner", "已重命名为「%@」"), name)
			errorText = nil
			load()
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}
}
