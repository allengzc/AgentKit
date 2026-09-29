//
//  SubagentsPane.swift
//  AgentKit
//
//  子 Agents：`<agent 根>/agents/*.md` 与项目 `.pi/agents/*.md` 的
//  frontmatter 表单 + 正文编辑。
//

import SwiftUI

struct SubagentEntry: Identifiable {
	let url: URL
	let scope: String
	let writable: Bool
	let document: TextDocument

	var id: String { url.path }
	var frontmatter: FrontmatterDocument { document.frontmatter }
	var name: String { frontmatter.string("name") ?? url.deletingPathExtension().lastPathComponent }
	var description: String { frontmatter.string("description") ?? "" }
	var model: String? { frontmatter.string("model") }
	var tools: [String] { frontmatter.stringArray("tools") ?? [] }

	/// Problems that would stop pi from discovering this agent.
	var issues: [String] {
		var out: [String] = []
		if frontmatter.string("name") == nil {
			out.append(L.t("subagents.issue.missingName", "缺少 name，pi 会跳过这个文件"))
		}
		if frontmatter.string("description") == nil {
			out.append(L.t("subagents.issue.missingDescription", "缺少 description，pi 会跳过这个文件"))
		}
		if !document.isReadable {
			out.append(document.problemReason ?? L.t("error.fileUnreadable", "文件无法读取"))
		}
		if !document.exists {
			out.append(L.t("subagents.issue.missingFile", "文件不存在"))
		}
		return out
	}
}

struct SubagentsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var entries: [SubagentEntry] = []
	@State private var selectedID: String?
	@State private var draft: Draft?
	@State private var pending: PendingWrite?
	@State private var banner: String?
	@State private var errorText: String?
	@State private var creating: CreateRequest?
	@State private var confirmDelete: SubagentEntry?
	@State private var token = UUID()

	private struct Draft {
		var name: String
		var description: String
		var model: String
		var toolsText: String
		var body: String
	}

	private struct CreateRequest: Identifiable {
		let id = UUID()
		let root: URL
		var name = ""
		var description = ""
	}

	private struct PendingWrite: Identifiable {
		let id = UUID()
		let url: URL
		let preview: FilePreview
		let document: TextDocument
		let text: String
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	private var roots: [(root: RootEntry, url: URL)] {
		(surface.roots ?? []).compactMap { entry in
			guard let url = try? resolver.expand(entry.path) else { return nil }
			return (entry, url)
		}
	}

	private var selected: SubagentEntry? {
		guard let selectedID else { return entries.first }
		return entries.first { $0.id == selectedID } ?? entries.first
	}

	private var modelIdentifiers: [String] {
		guard let models = agent.descriptor.surfaces.first(where: { $0.kind == .models }) else { return [] }
		return ModelsSurfaceLoader.modelIdentifiers(surface: models, resolver: resolver, policy: policy)
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			HStack(spacing: 0) {
				list
				Divider()
				editor
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.task(id: token) { reload() }
		.onChange(of: model.externalChangeToken) { _, _ in reload() }
		.onChange(of: model.projectURL) { _, _ in reload() }
		.sheet(item: $pending) { write in
			DiffSheet(
				preview: write.preview,
				backup: write.preview.backupURL,
				onCancel: { pending = nil },
				onConfirm: { confirm(write) }
			)
		}
		.sheet(item: $creating) { request in
			createSheet(request)
		}
		.alert(L.t("subagents.delete.title", "删除这个子 agent？"), isPresented: Binding(
			get: { confirmDelete != nil },
			set: { if !$0 { confirmDelete = nil } }
		), presenting: confirmDelete) { entry in
			Button(L.t("button.moveToTrash", "移到废纸篓"), role: .destructive) {
				do {
					try TextFile.trash(entry.url)
					banner = String(
						format: L.t("banner.movedToTrash", "已把 %@ 移到废纸篓"),
						entry.url.lastPathComponent
					)
					confirmDelete = nil
					reload()
				} catch {
					errorText = error.localizedDescription
					confirmDelete = nil
				}
			}
			Button(L.t("button.cancel", "取消"), role: .cancel) { confirmDelete = nil }
		} message: { entry in
			Text(
				String(
					format: L.t("subagents.delete.message", "%@\n\n会移到废纸篓，可以恢复。"),
					entry.url.path
				)
			)
		}
	}

	// MARK: - Header / list

	private var header: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				StatusBadge(
					text: String(format: L.t(entries.count == 1 ? "subagents.badge.count.one" : "subagents.badge.count", "%d 个"), entries.count),
					level: .info
				)
				Spacer()
				Menu {
					ForEach(Array(roots.enumerated()), id: \.offset) { _, entry in
						Button(entry.url.path) { creating = CreateRequest(root: entry.url) }
					}
				} label: {
					Label(L.t("button.newSubagent", "新建子 agent"), systemImage: "plus")
				}
				.controlSize(.small)
				.disabled(roots.filter { $0.root.isWritable }.isEmpty)
				Button {
					reload()
				} label: {
					Label(L.t("button.reload", "重新读取"), systemImage: "arrow.clockwise")
				}
				.controlSize(.small)
			}
			Text(
				L.t(
					"subagents.note",
					"子 agent 由 subagent 扩展加载：frontmatter 里的 name 与 description 是必填项，model 用 `provider/modelId` 指定。"
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
			ProjectScopeBanner(surface: surface)
			if let banner { InfoBanner(kind: .info, title: banner) }
			if let errorText { InfoBanner(kind: .error, title: errorText) }
		}
		.padding(14)
	}

	private var list: some View {
		List(selection: $selectedID) {
			ForEach(["user", "project"], id: \.self) { scope in
				let scoped = entries.filter { $0.scope == scope }
				if !scoped.isEmpty {
					Section(
						scope == "user"
							? L.t("badge.scopeUserLevel", "用户级")
							: L.t("badge.scopeProjectLevel", "项目级")
					) {
						ForEach(scoped) { entry in
							VStack(alignment: .leading, spacing: 2) {
								HStack(spacing: 6) {
									Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
									if !entry.issues.isEmpty {
										Image(systemName: "exclamationmark.triangle.fill")
											.font(.caption2)
											.foregroundStyle(.orange)
									}
								}
								Text(entry.description)
									.font(.caption2)
									.foregroundStyle(.secondary)
									.lineLimit(2)
								if let model = entry.model {
									Text(model)
										.font(.system(.caption2, design: .monospaced))
										.foregroundStyle(.tertiary)
										.lineLimit(1)
								}
							}
							.tag(entry.id as String?)
						}
					}
				}
			}
		}
		.frame(width: 260)
		.listStyle(.sidebar)
		.overlay {
			if entries.isEmpty {
				Text(L.t("empty.noSubagents", "还没有子 agent"))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	// MARK: - Editor

	@ViewBuilder
	private var editor: some View {
		if let entry = selected {
			let current = draft ?? Draft(
				name: entry.name,
				description: entry.description,
				model: entry.model ?? "",
				toolsText: entry.tools.joined(separator: ", "),
				body: entry.frontmatter.body
			)
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					if !entry.issues.isEmpty {
						InfoBanner(
							kind: .warning,
							title: L.t("subagents.issues.title", "这个文件 pi 可能不会加载"),
							detail: entry.issues.joined(separator: "\n")
						)
					}
					PathChip(
						path: entry.url.path,
						secondary: entry.document.isSymlink ? "→ \(entry.document.realURL.path)" : nil
					)

					Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
						GridRow {
							Text("name").gridColumnAlignment(.trailing)
							TextField(
								L.t("subagents.field.namePlaceholder", "子 agent 的名字"),
								text: binding(\.name, current, entry)
							)
								.textFieldStyle(.roundedBorder)
						}
						GridRow {
							Text("description").gridColumnAlignment(.trailing)
							TextField(
								L.t("field.descriptionPlaceholder", "做什么、什么时候用"),
								text: binding(\.description, current, entry)
							)
								.textFieldStyle(.roundedBorder)
						}
						GridRow {
							Text("model").gridColumnAlignment(.trailing)
							HStack(spacing: 6) {
								TextField("provider/modelId", text: binding(\.model, current, entry))
									.textFieldStyle(.roundedBorder)
									.font(.system(.body, design: .monospaced))
								Menu {
									ForEach(modelIdentifiers, id: \.self) { identifier in
										Button(identifier) { update(entry) { $0.model = identifier } }
									}
								} label: {
									Image(systemName: "chevron.down")
								}
								.menuStyle(.borderlessButton)
								.fixedSize()
								.disabled(modelIdentifiers.isEmpty)
							}
						}
						GridRow {
							Text("tools").gridColumnAlignment(.trailing)
							TextField("read, grep, find, ls", text: binding(\.toolsText, current, entry))
								.textFieldStyle(.roundedBorder)
								.font(.system(.body, design: .monospaced))
						}
					}

					if !current.model.isEmpty, !modelIdentifiers.isEmpty,
						!modelIdentifiers.contains(current.model)
					{
						InfoBanner(
							kind: .warning,
							title: String(
								format: L.t("subagents.modelMissing.title", "models.json 里找不到 %@"),
								current.model
							),
							detail: L.t(
								"subagents.modelMissing.detail",
								"pi 用的是内置目录或其它来源的话没问题；否则启动时会回退到默认模型。"
							)
						)
					}

					VStack(alignment: .leading, spacing: 4) {
						Text(L.t("subagents.body.label", "正文（系统提示）")).font(.caption.weight(.medium))
						TextEditor(text: binding(\.body, current, entry))
							.font(.system(size: 12, design: .monospaced))
							.frame(minHeight: 220)
							.overlay(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
							)
					}

					HStack(spacing: 8) {
						let validation = validate(current)
						if let validation {
							StatusBadge(text: validation, level: .error)
						}
						Spacer()
						Button(L.t("button.revealInFinder", "在 Finder 中显示")) { ShellActions.reveal(entry.url) }
							.controlSize(.small)
						Button(L.t("button.delete", "删除…"), role: .destructive) { confirmDelete = entry }
							.controlSize(.small)
							.disabled(!entry.writable)
						Button(L.t("button.discardChanges", "放弃改动")) { draft = nil }
							.controlSize(.small)
							.disabled(draft == nil)
						Button(L.t("button.save", "保存…")) { stage(entry, current) }
							.buttonStyle(.borderedProminent)
							.controlSize(.small)
							.disabled(validation != nil || !entry.writable)
					}
				}
				.padding(14)
				.frame(maxWidth: .infinity, alignment: .topLeading)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			EmptyStateView(
				icon: "person.2",
				title: L.t("empty.noSubagent.title", "没有子 agent"),
				message: L.t(
					"empty.noSubagent.message",
					"用右上角的新建按钮创建一个，会在选中的根目录里生成一个带 frontmatter 的 Markdown 文件。"
				)
			)
		}
	}

	private func binding(
		_ key: WritableKeyPath<Draft, String>,
		_ current: Draft,
		_ entry: SubagentEntry
	) -> Binding<String> {
		Binding(
			get: { (draft ?? current)[keyPath: key] },
			set: { newValue in
				var next = draft ?? current
				next[keyPath: key] = newValue
				draft = next
				_ = entry
			}
		)
	}

	private func update(_ entry: SubagentEntry, _ body: (inout Draft) -> Void) {
		let current = draft ?? Draft(
			name: entry.name,
			description: entry.description,
			model: entry.model ?? "",
			toolsText: entry.tools.joined(separator: ", "),
			body: entry.frontmatter.body
		)
		var next = current
		body(&next)
		draft = next
	}

	private func validate(_ draft: Draft) -> String? {
		if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
			return L.t("subagents.error.nameEmpty", "name 不能为空")
		}
		if draft.description.trimmingCharacters(in: .whitespaces).isEmpty {
			return L.t("subagents.error.descriptionEmpty", "description 不能为空")
		}
		if draft.name.contains("/") {
			return L.t("subagents.error.nameSlash", "name 里不能有斜杠")
		}
		return nil
	}

	/// Composes the file text, preserving unknown frontmatter keys and order.
	private func compose(_ entry: SubagentEntry, _ draft: Draft) -> String {
		var document = entry.frontmatter
		document.body = draft.body
		document.setRaw(FrontmatterDocument.literal(for: .string(draft.name.trimmingCharacters(in: .whitespaces))), forKey: "name")
		document.setRaw(
			FrontmatterDocument.literal(for: .string(draft.description.trimmingCharacters(in: .whitespaces))),
			forKey: "description"
		)
		let model = draft.model.trimmingCharacters(in: .whitespaces)
		if model.isEmpty {
			document.remove(key: "model")
		} else {
			document.setRaw(FrontmatterDocument.literal(for: .string(model)), forKey: "model")
		}
		let tools = draft.toolsText
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		if tools.isEmpty {
			document.remove(key: "tools")
		} else {
			document.setRaw(FrontmatterDocument.literal(for: .list(tools)), forKey: "tools")
		}
		return document.render()
	}

	private func stage(_ entry: SubagentEntry, _ draft: Draft) {
		let text = compose(entry, draft)
		let preview = TextFile.preview(text, for: entry.document, policy: policy)
		guard preview.hasChanges else {
			banner = L.t("banner.noChanges", "没有需要写入的改动")
			return
		}
		_ = entry
		pending = PendingWrite(url: entry.url, preview: preview, document: entry.document, text: text)
	}

	private func confirm(_ write: PendingWrite) {
		do {
			let result = try TextFile.write(write.text, document: write.document, scope: resolver, policy: policy)
			pending = nil
			banner = result.backupURL.map {
				String(format: L.t("banner.writtenWithBackup", "已写入，备份 %@"), $0.lastPathComponent)
			} ?? L.t("banner.written", "已写入")
			errorText = nil
			draft = nil
			reload()
		} catch {
			pending = nil
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	// MARK: - Create

	private func createSheet(_ request: CreateRequest) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(L.t("button.newSubagent", "新建子 agent")).font(.headline)
			PathChip(path: request.root.path)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
				GridRow {
					Text("name").gridColumnAlignment(.trailing)
					TextField(L.t("subagents.field.nameExample", "例如 code-reviewer"), text: Binding(
						get: { creating?.name ?? "" },
						set: { creating?.name = $0 }
					))
					.textFieldStyle(.roundedBorder)
				}
				GridRow {
					Text("description").gridColumnAlignment(.trailing)
					TextField(L.t("field.descriptionPlaceholder", "做什么、什么时候用"), text: Binding(
						get: { creating?.description ?? "" },
						set: { creating?.description = $0 }
					))
					.textFieldStyle(.roundedBorder)
				}
			}
			Text(
				String(
					format: L.t("subagents.create.detail", "会写入 %@"),
					request.root.appendingPathComponent(createName(request) + ".md").path
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button(L.t("button.cancel", "取消")) { creating = nil }
				Button(L.t("button.create", "创建")) { create(request) }
					.buttonStyle(.borderedProminent)
					.disabled(createName(request).isEmpty || (creating?.description ?? "").isEmpty)
			}
		}
		.padding(16)
		.frame(minWidth: 520)
	}

	private func createName(_ request: CreateRequest) -> String {
		(creating?.name ?? "")
			.trimmingCharacters(in: .whitespaces)
			.replacingOccurrences(of: "/", with: "-")
	}

	private func create(_ request: CreateRequest) {
		let name = createName(request)
		let url = request.root.appendingPathComponent("\(name).md")
		guard !FileManager.default.fileExists(atPath: url.path) else {
			errorText = String(format: L.t("error.fileExists", "%@ 已经存在"), url.path)
			creating = nil
			return
		}
		var document = FrontmatterDocument.empty
		document.hasFrontmatter = true
		document.setRaw(FrontmatterDocument.literal(for: .string(name)), forKey: "name")
		document.setRaw(
			FrontmatterDocument.literal(for: .string((creating?.description ?? "").trimmingCharacters(in: .whitespaces))),
			forKey: "description"
		)
		document.setRaw("read, grep, find, ls", forKey: "tools")
		document.body = L.t("subagents.create.bodyPlaceholder", "\n在这里写这个子 agent 的系统提示。\n")
		let text = document.render()
		do {
			try FileManager.default.createDirectory(at: request.root, withIntermediateDirectories: true)
			try text.write(to: url, atomically: true, encoding: .utf8)
			creating = nil
			banner = String(format: L.t("banner.createdAt", "已创建 %@"), url.lastPathComponent)
			reload()
			selectedID = url.path
			draft = nil
		} catch {
			errorText = error.localizedDescription
			creating = nil
		}
	}

	// MARK: - Load

	private func reload() {
		var loaded: [SubagentEntry] = []
		for entry in roots {
			let urls = (try? FileManager.default.contentsOfDirectory(
				at: entry.url,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)) ?? []
			for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
			where url.pathExtension.lowercased() == "md" {
				loaded.append(
					SubagentEntry(
						url: url,
						scope: entry.root.scope ?? "user",
						writable: entry.root.isWritable,
						document: TextFile.load(url, policy: policy)
					)
				)
			}
		}
		entries = loaded
		if selectedID == nil || !loaded.contains(where: { $0.id == selectedID }) {
			selectedID = loaded.first?.id
		}
	}
}
