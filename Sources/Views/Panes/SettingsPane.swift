//
//  SettingsPane.swift
//  AgentKit
//
//  The typed settings editor: a form generated from the descriptor's schema,
//  written back through the diff sheet with a timestamped backup.
//
//  This is also the reference implementation of the "read → edit → diff →
//  atomic write → backup" path that every other surface reuses.
//

import SwiftUI

struct SettingsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model

	@State private var document: JSONDocument?
	@State private var editor: SettingsEditor?
	@State private var drafts: [String: String] = [:]
	@State private var selectedSectionID: String?
	@State private var pendingWrite: PendingWrite?
	@State private var banner: String?
	@State private var loadError: String?
	@State private var reloadToken = UUID()

	private struct PendingWrite: Identifiable {
		let id = UUID()
		let preview: FilePreview
		let document: JSONDocument
		let value: JSONValue
		let policy: BackupPolicy
		let resolver: PathResolver
	}

	private var fileURL: URL? {
		guard let template = surface.file else { return nil }
		return try? model.resolver(for: agent).expand(template)
	}

	private var schemaID: String? { surface.schema }

	var body: some View {
		Group {
			if let editor, let document {
				content(editor: editor, document: document)
			} else if let loadError {
				EmptyStateView(
					icon: "exclamationmark.triangle",
					title: L.t("empty.settingsLoadFailed.title", "无法载入设置"),
					message: loadError
				)
			} else {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.task(id: reloadToken) {
			load()
			stageDocumentationDiff()
		}
		.onChange(of: model.externalChangeToken) { _, _ in load() }
		// "Reload file" moved to the toolbar's ⋯ menu. It re-reads from disk and
		// silently throws away unsaved edits, so the footer is the wrong place
		// for it: the two buttons that belong together there are "discard" and
		// "save", and a third control that also discards — but without asking —
		// sat between them.
		.paneActions(token: paneActionToken(agent: agent, surface: surface), title: surface.titleText) {
			[
				.command(
					id: "settings.reloadFile",
					title: L.t("button.reloadFile", "重新载入"),
					systemImage: "arrow.clockwise"
				) { load() }
			]
		}
		.sheet(item: $pendingWrite) { pending in
			DiffSheet(
				preview: pending.preview,
				backup: pending.preview.backupURL,
				onCancel: { pendingWrite = nil },
				onConfirm: { confirmWrite(pending) }
			)
		}
	}

	// MARK: - Load / write

	/// Puts the pane into the state the README's diff screenshot shows: a few
	/// edited fields with the confirm sheet open, so the picture does not have to
	/// be produced by hand. Off unless `AGENTKIT_DOC_STATE` asks for it.
	private func stageDocumentationDiff() {
		guard DocumentationState.isOn("diff"), var current = editor else { return }
		var staged = 0
		for section in current.schema.sections {
			for field in section.fields {
				guard staged < 3 else { break }
				switch field.type {
				case .bool, .boolOrAuto:
					current.setBool(!current.bool(field), field)
					staged += 1
				case .text, .path:
					let text = current.text(field)
					if !text.isEmpty, current.setText(text + "-edited", field) == nil {
						staged += 1
					}
				default:
					continue
				}
			}
		}
		guard staged > 0 else { return }
		editor = current
		requestWrite(editor: current)
	}

	private func load() {
		guard let fileURL else {
			loadError = L.t("error.settingsNoFile", "描述文件没有为这个面板指定 file")
			return
		}
		guard let definition = SettingsSchema.definition(for: schemaID) else {
			loadError = String(
				format: L.t("error.schemaNotFound", "找不到 schema “%@”"),
				schemaID ?? L.t("error.schemaUnspecified", "未指定")
			)
			return
		}
		let policy = agent.descriptor.backupPolicy
		let loaded = JSONFile.load(
			fileURL,
			policy: policy,
			format: surface.format.flatMap(ConfigFormat.init(rawValue:))
		)
		document = loaded
		editor = SettingsEditor(document: loaded, schema: definition)
		drafts = [:]
		loadError = nil
		if selectedSectionID == nil || definition.sections.first(where: { $0.id == selectedSectionID }) == nil {
			selectedSectionID = definition.sections.first?.id
		}
	}

	private func confirmWrite(_ pending: PendingWrite) {
		do {
			let result = try JSONFile.write(
				pending.value,
				document: pending.document,
				scope: pending.resolver,
				policy: pending.policy
			)
			let reloaded = JSONFile.load(pending.document.url, policy: pending.policy)
			document = reloaded
			if let definition = SettingsSchema.definition(for: schemaID) {
				editor = SettingsEditor(document: reloaded, schema: definition)
			}
			drafts = [:]
			pendingWrite = nil
			if let backup = result.backupURL {
				banner = String(
					format: L.t("banner.writtenWithBackup", "已写入，备份 %@"),
					backup.lastPathComponent
				)
			} else {
				banner = String(format: L.t("banner.writtenTo", "已写入 %@"), result.url.path)
			}
			model.statusMessage = banner
		} catch {
			pendingWrite = nil
			banner = nil
			loadError = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	private func requestWrite(editor current: SettingsEditor) {
		guard let document, let fileURL else { return }
		let preview = JSONFile.preview(current.root, for: document, policy: agent.descriptor.backupPolicy)
		guard preview.hasChanges else {
			banner = L.t("banner.noChanges", "没有需要写入的改动")
			return
		}
		pendingWrite = PendingWrite(
			preview: preview,
			document: document,
			value: current.root,
			policy: agent.descriptor.backupPolicy,
			resolver: model.resolver(for: agent)
		)
		_ = fileURL
	}

	// MARK: - Content

	@ViewBuilder
	private func content(editor current: SettingsEditor, document: JSONDocument) -> some View {
		VStack(spacing: 0) {
			header(current: current, document: document)
			Divider()
			if let reason = current.readOnlyReason {
				InfoBanner(
					kind: .error,
					title: reason,
					detail: document.rawText.isEmpty
						? nil
						: L.t("settings.readOnly.detail", "下方是文件原文；修复之前不会写入。")
				)
					.padding(12)
			}
			HStack(spacing: 0) {
				sectionList(current: current)
				Divider()
				form(current: current, document: document)
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			Divider()
			footer(current: current)
		}
	}

	@ViewBuilder
	private func header(current: SettingsEditor, document: JSONDocument) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				StatusBadge(text: current.schema.titleText, level: .info)
				if document.isSymlink {
					StatusBadge(text: L.t("badge.symlink", "符号链接"), level: .warning)
				}
				if !document.exists {
					StatusBadge(text: L.t("badge.fileMissing", "文件不存在"), level: .muted)
				}
				Spacer()
				if let fingerprint = document.fingerprint {
					Text(fingerprint.shortHash)
						.font(.system(.caption2, design: .monospaced))
						.foregroundStyle(.tertiary)
						.help(L.t("settings.help.hashPrefix", "当前文件的 SHA-256 前 7 位"))
				}
			}
			if let fileURL {
				PathChip(path: fileURL.path, secondary: document.isSymlink ? "→ \(document.realURL.path)" : nil)
			}
			if let banner {
				InfoBanner(kind: .info, title: banner)
			}
		}
		.padding(14)
	}

	private func sectionList(current: SettingsEditor) -> some View {
		List(selection: $selectedSectionID) {
			ForEach(current.schema.sections) { section in
				HStack(spacing: 7) {
					Image(systemName: section.icon)
						.frame(width: 16)
					Text(section.titleText)
					Spacer(minLength: 0)
					let setCount = section.fields.filter { current.isSet($0) }.count
					if setCount > 0 {
						Text("\(setCount)")
							.font(.caption2)
							.foregroundStyle(.tertiary)
					}
				}
				.tag(section.id as String?)
			}
			if !current.unknownPaths().isEmpty {
				HStack(spacing: 7) {
					Image(systemName: "questionmark.folder")
						.frame(width: 16)
					Text(L.t("settings.unknownSection.title", "其它键（保留）"))
					Spacer(minLength: 0)
					Text("\(current.unknownPaths().count)")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				.tag("__unknown" as String?)
			}
		}
		.frame(width: 190)
		.listStyle(.sidebar)
	}

	@ViewBuilder
	private func form(current: SettingsEditor, document: JSONDocument) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 0) {
				if selectedSectionID == "__unknown" {
					unknownSection(current: current)
				} else if let section = current.schema.sections.first(where: { $0.id == selectedSectionID }) {
					sectionHeader(section)
					ForEach(section.fields) { field in
						fieldRow(field, current: current)
						Divider().opacity(0.4)
					}
				} else {
					Text(L.t("settings.pickSection", "选择一个分组")).foregroundStyle(.secondary).padding(20)
				}
			}
			.padding(16)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func sectionHeader(_ section: SettingsSection) -> some View {
		HStack(spacing: 7) {
			Image(systemName: section.icon).foregroundStyle(.tint)
			Text(section.titleText).font(.headline)
			Spacer()
		}
		.padding(.bottom, 8)
	}

	@ViewBuilder
	private func fieldRow(_ field: SettingField, current: SettingsEditor) -> some View {
		FieldRow(
			label: field.labelText,
			help: field.helpText,
			note: field.scopeNoteText,
			isDefault: !current.isSet(field),
			error: current.errors[field.key]
		) {
			fieldControl(field, current: current)
		}
	}

	@ViewBuilder
	private func fieldControl(_ field: SettingField, current: SettingsEditor) -> some View {
		switch current.editorKind(field) {
		case .toggle:
			Toggle("", isOn: Binding(
				get: { current.bool(field) },
				set: { newValue in
					var updated = current
					updated.setBool(newValue, field)
					editor = updated
				}
			))
			.labelsHidden()
			.toggleStyle(.switch)
			.controlSize(.small)

		case .picker:
			Picker("", selection: Binding(
				get: { current.isSet(field) ? current.text(field) : "" },
				set: { newValue in
					var updated = current
					if newValue.isEmpty {
						updated.clear(field)
					} else {
						_ = updated.setText(newValue, field)
					}
					editor = updated
				}
			)) {
				ForEach(current.pickerOptions(field), id: \.self) { option in
					Text(option.isEmpty ? L.t("settings.useDefault", "（使用默认）") : option).tag(option)
				}
			}
			.labelsHidden()
			.pickerStyle(.menu)
			.frame(maxWidth: 200)

		case .json:
			VStack(alignment: .trailing, spacing: 4) {
				TextEditor(text: draftBinding(field, current: current, initial: current.jsonText(field)))
					.font(.system(size: 11, design: .monospaced))
					.frame(height: 80)
					.overlay(
						RoundedRectangle(cornerRadius: 6)
							.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
					)
				if current.isSet(field) {
					Button(L.t("button.restoreDefault", "恢复默认")) {
						var updated = current
						updated.clear(field)
						drafts[field.key] = nil
						editor = updated
					}
					.buttonStyle(.link)
					.controlSize(.mini)
				}
			}
			.frame(maxWidth: 320)

		case .list, .text, .path:
			VStack(alignment: .trailing, spacing: 4) {
				TextField("", text: draftBinding(field, current: current, initial: textInitial(field, current: current)))
					.textFieldStyle(.roundedBorder)
					.font(.system(size: 12, design: .monospaced))
				if current.isSet(field) {
					Button(L.t("button.restoreDefault", "恢复默认")) {
						var updated = current
						updated.clear(field)
						drafts[field.key] = nil
						editor = updated
					}
					.buttonStyle(.link)
					.controlSize(.mini)
				}
			}
		}
	}

	private func textInitial(_ field: SettingField, current: SettingsEditor) -> String {
		switch field.type {
		case .textList, .mixedList: return current.listText(field)
		default: return current.text(field)
		}
	}

	/// Text fields keep what the user typed even when the parser rejects it, so
	/// a half-typed number is not silently reverted mid-keystroke.
	private func draftBinding(
		_ field: SettingField,
		current: SettingsEditor,
		initial: String
	) -> Binding<String> {
		Binding(
			get: { drafts[field.key] ?? initial },
			set: { newValue in
				drafts[field.key] = newValue
				var updated = current
				_ = updated.setText(newValue, field)
				editor = updated
			}
		)
	}

	@ViewBuilder
	private func unknownSection(current: SettingsEditor) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(L.t("settings.unknownSection.title", "其它键（保留）")).font(.headline)
			Text(
				String(
					format: L.t(
						"settings.unknownSection.detail",
						"这些键不在 %@ 里，AgentKit 认识不了它们的含义，所以只读展示；写入时原样保留，不会丢失。"
					),
					current.schema.titleText
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
			if let document {
				PathChip(path: document.realURL.path)
			}
			Divider()
			ForEach(current.unknownPaths(), id: \.self) { path in
				VStack(alignment: .leading, spacing: 3) {
					Text(path).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
					Text(current.unknownValue(at: path).map { JSONWriter.pretty.serialize($0) } ?? "null")
						.font(.system(size: 11, design: .monospaced))
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
				}
				.padding(.vertical, 3)
			}
		}
	}

	private func footer(current: SettingsEditor) -> some View {
		HStack(spacing: 10) {
			if current.hasChanges {
				StatusBadge(text: L.t("badge.unsavedChanges", "有未保存改动"), level: .warning)
			} else {
				StatusBadge(text: L.t("badge.inSync", "与磁盘一致"), level: .ok)
			}
			Text(current.summary)
				.font(.caption)
				.foregroundStyle(.secondary)
			if current.errorCount > 0 {
				StatusBadge(
					text: String(
						format: L.t(current.errorCount == 1 ? "settings.badge.invalidInputs.one" : "settings.badge.invalidInputs", "%d 个输入无效"),
						current.errorCount
					),
					level: .error
				)
			}
			Spacer()
			Button(L.t("button.discardChanges", "放弃改动")) {
				if let document, let definition = SettingsSchema.definition(for: schemaID) {
					editor = SettingsEditor(document: document, schema: definition)
					drafts = [:]
				}
			}
			.controlSize(.small)
			.disabled(!current.hasChanges)
			Button(L.t("button.save", "保存…")) { requestWrite(editor: current) }
				.buttonStyle(.borderedProminent)
				.controlSize(.small)
				.disabled(!current.hasChanges || current.errorCount > 0 || current.readOnlyReason != nil)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
	}
}
