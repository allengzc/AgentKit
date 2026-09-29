//
//  MCPPane.swift
//  AgentKit
//
//  MCP 服务器：生效列表、配置层、冲突、导入候选，以及把一个已经被弃用的
//  mcp.json 优雅地退休。
//

import SwiftUI

struct MCPPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var snapshot: MCPSnapshot?
	@State private var controller = JSONEditController()
	@State private var repairFinding: MCPLegacyFinding?
	@State private var repairIncludeServers = true
	@State private var repairOutcome: [MCPRepair.Outcome]?
	@State private var draft: ServerDraft?
	@State private var reloadToken = UUID()

	private struct ServerDraft: Identifiable {
		let id = UUID()
		let layerID: String
		let originalName: String?
		var name: String
		var command: String
		var argsText: String
		var url: String
		var disabled: Bool

		var isNew: Bool { originalName == nil }
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	var body: some View {
		VStack(spacing: 0) {
			if let snapshot {
				header(snapshot)
				Divider()
				content(snapshot)
			} else {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.task(id: reloadToken) { reload() }
		.onChange(of: model.externalChangeToken) { _, _ in reload() }
		.onChange(of: model.projectURL) { _, _ in reload() }
		// Both header buttons moved to the toolbar's ⋯ menu. "Reload" is the
		// same manual fallback the other panes carry, and "add server" cannot
		// stay in the header because it needs a target: the writable config
		// layer. That makes it a submenu, which the overflow menu can hold and
		// a header row of six layer badges cannot. The submenu only exists once
		// the snapshot is in, hence the signature.
		.paneActions(
			token: paneActionToken(agent: agent, surface: surface),
			title: surface.titleText,
			signature: snapshot?.writableLayers.map(\.id).joined(separator: "|") ?? ""
		) {
			var actions: [PaneAction] = [
				.command(
					id: "mcp.reload",
					title: L.t("button.reload", "重新读取"),
					systemImage: "arrow.clockwise"
				) { reload() }
			]
			// A read-only install has nowhere to write, so the entry goes away
			// rather than opening an empty submenu.
			let layers = snapshot?.writableLayers ?? []
			if !layers.isEmpty {
				actions.append(
					.submenu(
						id: "mcp.addServer",
						title: L.t("button.addServer", "新增服务器"),
						systemImage: "plus",
						items: layers.map { layer in
							.path(id: "mcp.addServer.\(layer.id)", title: layer.url.path) {
								draft = ServerDraft(
									layerID: layer.id,
									originalName: nil,
									name: "",
									command: "",
									argsText: "",
									url: "",
									disabled: false
								)
							}
						}
					)
				)
			}
			return actions
		}
		.overlay(alignment: .bottom) { statusBar }
		.sheet(item: $controller.pending) { pending in
			DiffSheet(
				preview: pending.preview,
				backup: pending.preview.backupURL,
				onCancel: { controller.cancel() },
				onConfirm: {
					controller.confirm()
					snapshot = nil
					reload()
				}
			)
		}
		.sheet(item: $repairFinding) { finding in
			repairSheet(finding)
		}
		.sheet(item: $draft) { draft in
			editorSheet(draft)
		}
	}

	// MARK: - Loading

	private func reload() {
		snapshot = MCPSurfaceLoader.snapshot(surface: surface, resolver: resolver, policy: policy)
	}

	// MARK: - Header

	private func header(_ snapshot: MCPSnapshot) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				StatusBadge(
					text: String(
						format: L.t(snapshot.effective.count == 1 ? "mcp.badge.effectiveCount.one" : "mcp.badge.effectiveCount", "%d 个生效服务器"),
						snapshot.effective.count
					),
					level: .info
				)
				if snapshot.problemCount > 0 {
					StatusBadge(
						text: String(
							format: L.t(snapshot.problemCount == 1 ? "mcp.badge.problemCount.one" : "mcp.badge.problemCount", "%d 个问题"),
							snapshot.problemCount
						),
						level: .warning
					)
				}
				Spacer()
			}
			Text(
				L.t(
					"mcp.note.merge",
					"按优先级从低到高合并全部配置层，后出现的层覆盖先出现的层。默认写入的共享层是 ~/.config/mcp/mcp.json。"
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
			ProjectScopeBanner(surface: surface)
			if let banner = controller.banner {
				InfoBanner(kind: .info, title: banner)
			}
			if let error = controller.errorText {
				InfoBanner(kind: .error, title: error)
			}
		}
		.padding(14)
	}

	// MARK: - Content

	@ViewBuilder
	private func content(_ snapshot: MCPSnapshot) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 18) {
				if !snapshot.legacy.isEmpty {
					legacySection(snapshot.legacy)
				}
				if !snapshot.conflicts.isEmpty {
					conflictSection(snapshot.conflicts)
				}
				effectiveSection(snapshot)
				layerSection(snapshot)
				// Host-config imports are a pi-mcp-adapter concept; a descriptor
				// that declares none should not show an empty section about them.
				if !(surface.imports ?? [:]).isEmpty {
					importSection(snapshot)
				}
			}
			.padding(14)
		}
	}

	@ViewBuilder
	private func legacySection(_ findings: [MCPLegacyFinding]) -> some View {
		ForEach(findings) { finding in
			if finding.hasAnything {
				InfoBanner(
					kind: .warning,
					title: String(
						format: L.t("mcp.legacy.title", "%@ 已经不会被读取"),
						finding.url.path
					),
					detail: finding.notice
						+ "\n"
						+ String(
							format: L.t("mcp.legacy.declared", "这里声明了 %d 个服务器%@。"),
							finding.serverNames.count,
							finding.adapterKeys.isEmpty
								? ""
								: String(
									format: L.t("mcp.legacy.alsoKeys", "、以及 %@"),
									finding.adapterKeys.joined(separator: L.t("listSeparator", "、"))
								)
						),
					action: (
						L.t("button.viewRepairPlan", "查看修复方案…"),
						{ repairIncludeServers = true; repairFinding = finding }
					)
				)
			}
		}
	}

	@ViewBuilder
	private func conflictSection(_ conflicts: [MCPConflict]) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			sectionTitle(L.t("mcp.section.conflicts", "同名冲突"), icon: "exclamationmark.triangle", count: conflicts.count)
			ForEach(conflicts) { conflict in
				VStack(alignment: .leading, spacing: 4) {
					Text(conflict.name).font(.callout.weight(.medium))
					ForEach(conflict.contenders) { layer in
						HStack(spacing: 6) {
							Image(systemName: layer.id == conflict.winner.id ? "checkmark.circle.fill" : "circle.dashed")
								.font(.caption2)
								.foregroundStyle(layer.id == conflict.winner.id ? .green : .secondary)
							Text(layer.url.path)
								.font(.system(.caption, design: .monospaced))
								.foregroundStyle(.secondary)
							if layer.id == conflict.winner.id {
								Text(L.t("mcp.badge.winner", "生效")).font(.caption2).foregroundStyle(.green)
							}
						}
					}
				}
				.padding(8)
				.background(
					RoundedRectangle(cornerRadius: 8, style: .continuous)
						.fill(Color.orange.opacity(0.08))
				)
			}
		}
	}

	@ViewBuilder
	private func effectiveSection(_ snapshot: MCPSnapshot) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				sectionTitle(
					L.t("mcp.section.effective", "生效的服务器"),
					icon: "checkmark.seal",
					count: snapshot.effective.count
				)
				Spacer()
			}

			if snapshot.effective.isEmpty {
				Text(L.t("empty.noMCPServers", "没有任何生效的 MCP 服务器。"))
					.font(.callout)
					.foregroundStyle(.secondary)
					.padding(.vertical, 8)
			}

			ForEach(snapshot.effective) { item in
				HStack(alignment: .top, spacing: 10) {
					Image(systemName: item.value.boolValue == nil ? "server.rack" : "server.rack")
						.foregroundStyle(item.isShadowed ? Color.orange : Color.accentColor)
						.frame(width: 18)
					VStack(alignment: .leading, spacing: 3) {
						HStack(spacing: 7) {
							Text(item.name).font(.callout.weight(.semibold))
							StatusBadge(text: MCPShape.transport(item.value), level: .muted)
							if item.isDisabled {
								StatusBadge(text: L.t("mcp.badge.disabled", "已禁用"), level: .warning)
							}
							if item.isShadowed {
								StatusBadge(
									text: String(
										format: L.t(item.shadowed.count == 1 ? "mcp.badge.shadowed.one" : "mcp.badge.shadowed", "有 %d 处被覆盖"),
										item.shadowed.count
									),
									level: .warning
								)
							}
						}
						Text(MCPShape.summary(item.value))
							.font(.system(.caption, design: .monospaced))
							.foregroundStyle(.secondary)
							.lineLimit(2)
							.textSelection(.enabled)
						Text(item.winner.url.path)
							.font(.caption2)
							.foregroundStyle(.tertiary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
					Spacer(minLength: 8)
					Menu {
						if item.winner.isWritable {
							Button(L.t("button.edit", "编辑…")) { beginEdit(item) }
							Button(
								item.isDisabled
									? L.t("button.enable", "启用")
									: L.t("mcp.button.disable", "禁用")
							) {
								toggleDisabled(item)
							}
							Divider()
							Button(L.t("button.delete", "删除…"), role: .destructive) { deleteServer(item) }
						} else {
							Text(L.t("mcp.layerReadOnly", "这一层是只读的"))
						}
						Divider()
						Button(L.t("button.revealInFinder", "在 Finder 中显示")) { ShellActions.reveal(item.winner.url) }
					} label: {
						Image(systemName: "ellipsis.circle")
					}
					.menuStyle(.borderlessButton)
					.fixedSize()
				}
				.padding(10)
				.background(
					RoundedRectangle(cornerRadius: 8, style: .continuous)
						.fill(Color(nsColor: .controlBackgroundColor))
				)
			}
		}
	}

	@ViewBuilder
	private func layerSection(_ snapshot: MCPSnapshot) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			sectionTitle(
				L.t("mcp.section.layers", "配置层（优先级从低到高）"),
				icon: "square.3.layers.3d",
				count: snapshot.layers.count
			)
			ForEach(snapshot.layers) { layer in
				HStack(spacing: 9) {
					Text("\(layer.spec.precedence)")
						.font(.system(.caption2, design: .monospaced))
						.foregroundStyle(.tertiary)
						.frame(width: 22, alignment: .trailing)
					VStack(alignment: .leading, spacing: 2) {
						HStack(spacing: 6) {
							Text(layer.url.path)
								.font(.system(.caption, design: .monospaced))
								.lineLimit(1)
								.truncationMode(.middle)
							if layer.malformedReason != nil {
								StatusBadge(text: L.t("badge.malformedJSON", "JSON 损坏"), level: .error)
							}
							if !layer.exists {
								StatusBadge(text: L.t("badge.missing", "不存在"), level: .muted)
							}
						}
						HStack(spacing: 6) {
							StatusBadge(
								text: layer.isProjectScoped
									? L.t("badge.scopeProject", "项目")
									: L.t("badge.scopeGlobal", "全局"),
								level: .muted
							)
							if layer.isShared { StatusBadge(text: L.t("badge.shared", "共享"), level: .muted) }
							if !layer.isWritable { StatusBadge(text: L.t("badge.readOnly", "只读"), level: .muted) }
							Text(
								String(
									format: L.t(layer.serverNames.count == 1 ? "mcp.layer.serverCount.one" : "mcp.layer.serverCount", "%d 个服务器"),
									layer.serverNames.count
								)
							)
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
					Spacer(minLength: 6)
					Button {
						ShellActions.reveal(layer.url)
					} label: {
						Image(systemName: "folder")
					}
					.buttonStyle(.borderless)
					.help(L.t("button.revealInFinder", "在 Finder 中显示"))
				}
				.padding(.vertical, 5)
			}
		}
	}

	@ViewBuilder
	private func importSection(_ snapshot: MCPSnapshot) -> some View {
		let found = snapshot.imports.filter(\.exists)
		VStack(alignment: .leading, spacing: 8) {
			sectionTitle(L.t("mcp.section.imports", "可导入的其它工具配置"), icon: "arrow.down.doc", count: found.count)
			if found.isEmpty {
				Text(L.t("empty.noImports", "没有检测到 Cursor / Claude / Codex / opencode 等工具的 MCP 配置。"))
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				ForEach(found) { candidate in
					HStack(spacing: 8) {
						StatusBadge(text: candidate.kind, level: .info)
						Text(candidate.url.path)
							.font(.system(.caption, design: .monospaced))
							.lineLimit(1)
							.truncationMode(.middle)
						Spacer(minLength: 6)
						if let note = candidate.note {
							Text(note).font(.caption2).foregroundStyle(.tertiary)
						} else {
							Text(
								String(
									format: L.t(candidate.serverCount == 1 ? "mcp.layer.serverCount.one" : "mcp.layer.serverCount", "%d 个服务器"),
									candidate.serverCount
								)
							)
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
					.padding(.vertical, 3)
				}
			}
			Text(
				L.t(
					"mcp.note.imports",
					"这些是 pi-mcp-adapter 的兼容输入，默认不加载（hostConfigDiscovery 为 off）。这里只做展示，不会替你改动它们。"
				)
			)
				.font(.caption2)
				.foregroundStyle(.tertiary)
		}
	}

	private func sectionTitle(_ title: String, icon: String, count: Int) -> some View {
		HStack(spacing: 6) {
			Image(systemName: icon).foregroundStyle(.tint)
			Text(title).font(.headline)
			Text("\(count)").font(.caption).foregroundStyle(.tertiary)
		}
	}

	@ViewBuilder
	private var statusBar: some View {
		if let outcome = repairOutcome {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(Array(outcome.enumerated()), id: \.offset) { _, item in
					HStack(spacing: 6) {
						Image(systemName: item.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
							.foregroundStyle(item.succeeded ? .green : .red)
							.font(.caption)
						Text(item.step).font(.caption)
						Text(item.detail).font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
			.padding(10)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
			.padding(12)
		}
	}

	// MARK: - Repair

	private func repairSheet(_ finding: MCPLegacyFinding) -> some View {
		let sharedLayer = try? resolver.expand("~/.config/mcp/mcp.json")
		let plan = MCPRepair.plan(
			finding: finding,
			includeServers: repairIncludeServers,
			sharedLayerURL: sharedLayer,
			policy: policy
		)

		return VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 8) {
				Text(L.t("mcp.repair.title", "修复方案")).font(.headline)
				Text(
					L.t(
						"mcp.repair.detail",
						"下面是 AgentKit 准备按顺序执行的全部步骤。每一步都是原子写入，并各自生成一份 .bak-agentkit-* 备份；任何一步失败就停下，不会继续。"
					)
				)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Toggle(
					L.t("mcp.repair.includeServers", "把这个文件里的 mcpServers 并入共享全局层"),
					isOn: $repairIncludeServers
				)
					.toggleStyle(.checkbox)
			}
			.padding(14)
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
						VStack(alignment: .leading, spacing: 6) {
							HStack(spacing: 6) {
								Text("\(index + 1)").font(.caption2.weight(.bold))
									.foregroundStyle(.white)
									.frame(width: 16, height: 16)
									.background(Circle().fill(Color.accentColor))
								Text(step.title).font(.callout.weight(.medium))
							}
							if let preview = step.preview {
								PathChip(path: step.url.path)
								DiffPreviewList(diff: preview.diff)
							} else {
								PathChip(path: step.url.path)
							}
						}
						.padding(10)
						.background(
							RoundedRectangle(cornerRadius: 8, style: .continuous)
								.fill(Color(nsColor: .controlBackgroundColor))
						)
					}
					if !plan.notes.isEmpty {
						InfoBanner(
							kind: .info,
							title: L.t("banner.notes", "说明"),
							detail: plan.notes.joined(separator: "\n")
						)
					}
					if let outcome = repairOutcome {
						InfoBanner(
							kind: outcome.allSatisfy(\.succeeded) ? .info : .error,
							title: outcome.allSatisfy(\.succeeded)
								? L.t("mcp.repair.done", "修复完成")
								: L.t("mcp.repair.interrupted", "修复中断"),
							detail: outcome.map { "\($0.succeeded ? "✓" : "✗") \($0.step) — \($0.detail)" }.joined(separator: "\n")
						)
					}
				}
				.padding(14)
			}
			Divider()
			HStack {
				Spacer()
				Button(L.t("button.close", "关闭")) { repairFinding = nil }
				Button(L.t("button.runRepair", "执行")) {
					let outcomes = MCPRepair.run(plan, scope: resolver, policy: policy)
					repairOutcome = outcomes
					reload()
				}
				.disabled(plan.isEmpty || repairOutcome?.allSatisfy(\.succeeded) == true)
				.buttonStyle(.borderedProminent)
				.disabled(plan.isEmpty)
			}
			.padding(14)
		}
		.frame(minWidth: 760, minHeight: 520)
	}

	// MARK: - Server editing

	private func beginEdit(_ item: MCPEffective) {
		draft = ServerDraft(
			layerID: item.winner.id,
			originalName: item.name,
			name: item.name,
			command: item.value.value(at: ["command"])?.stringValue ?? "",
			argsText: (item.value.value(at: ["args"])?.stringsValue ?? []).joined(separator: "\n"),
			url: item.value.value(at: ["url"])?.stringValue ?? "",
			disabled: item.isDisabled
		)
	}

	private func editorSheet(_ draft: ServerDraft) -> some View {
		let error = MCPShape.validate(name: draft.name, value: buildValue(draft))
		let prepared = preparedEdit(draft)
		return VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Text(
						draft.isNew
							? L.t("mcp.editor.newTitle", "新增 MCP 服务器")
							: String(
								format: L.t("mcp.editor.editTitle", "编辑 %@"),
								draft.originalName ?? ""
							)
					)
						.font(.headline)
					Spacer()
				}
				Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
					GridRow {
						Text(L.t("mcp.field.name", "名字")).gridColumnAlignment(.trailing)
						TextField("", text: Binding(
							get: { draft.name },
							set: { self.draft?.name = $0 }
						))
						.textFieldStyle(.roundedBorder)
					}
					GridRow {
						Text("command").gridColumnAlignment(.trailing)
						TextField(L.t("mcp.field.commandPlaceholder", "本地服务器的可执行文件"), text: Binding(
							get: { draft.command },
							set: { self.draft?.command = $0 }
						))
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
					}
					GridRow {
						Text("args").gridColumnAlignment(.trailing)
						TextEditor(text: Binding(
							get: { draft.argsText },
							set: { self.draft?.argsText = $0 }
						))
						.font(.system(size: 11, design: .monospaced))
						.frame(height: 54)
						.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
					}
					GridRow {
						Text("url").gridColumnAlignment(.trailing)
						TextField(L.t("mcp.field.urlPlaceholder", "远程服务器的 URL"), text: Binding(
							get: { draft.url },
							set: { self.draft?.url = $0 }
						))
						.textFieldStyle(.roundedBorder)
						.font(.system(.body, design: .monospaced))
					}
					GridRow {
						Text("").gridColumnAlignment(.trailing)
						Toggle(
							L.t("mcp.field.disabledToggle", "禁用（保留配置但不加载）"),
							isOn: Binding(
								get: { draft.disabled },
								set: { self.draft?.disabled = $0 }
							)
						)
						.toggleStyle(.checkbox)
					}
				}
				Text(L.t("mcp.editor.hint", "args 一行一个参数；command 与 url 只能填一个。"))
					.font(.caption2)
					.foregroundStyle(.tertiary)
				if let error {
					InfoBanner(kind: .warning, title: error)
				}
				if let prepared {
					if prepared.preview.hasChanges {
						VStack(alignment: .leading, spacing: 4) {
							Text(
								String(
									format: L.t("sheet.changesTo", "写入 %@ 的改动"),
									prepared.url.path
								)
							)
							.font(.caption.weight(.medium))
							DiffPreviewList(diff: prepared.preview.diff)
						}
					} else {
						Text(L.t("sheet.noChangesInline", "没有改动。"))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
			.padding(14)
			Divider()
			HStack {
				if let prepared, prepared.preview.existed {
					Text(
						String(
							format: L.t("diff.backupNotice", "写入前会备份为 %@"),
							prepared.preview.backupURL?.lastPathComponent ?? ""
						)
					)
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				Spacer()
				Button(L.t("button.cancel", "取消")) { self.draft = nil }
				Button(L.t("button.write", "写入")) { apply(draft) }
					.buttonStyle(.borderedProminent)
					.disabled(error != nil || prepared?.preview.hasChanges != true)
			}
			.padding(14)
		}
		.frame(minWidth: 640)
	}

	/// Builds the value the editor would write, plus its diff, without writing.
	private func preparedEdit(_ draft: ServerDraft) -> (url: URL, preview: FilePreview)? {
		guard let snapshot,
			let layer = snapshot.layers.first(where: { $0.id == draft.layerID })
		else { return nil }
		let document = JSONFile.load(layer.url, policy: policy)
		guard document.status.isWritable else { return nil }
		var value = document.editableValue
		let name = draft.name.trimmingCharacters(in: .whitespaces)
		if let original = draft.originalName, original != name {
			value.removeValue(at: [layer.shape.serverKey, original])
		}
		value.setValue(buildValue(draft), at: [layer.shape.serverKey, name])
		return (layer.url, JSONFile.preview(value, for: document, policy: policy))
	}

	/// The server object as it exists in the file right now, or nil for a new one.
	private func existingServer(_ draft: ServerDraft) -> JSONValue? {
		guard let snapshot,
			let layer = snapshot.layers.first(where: { $0.id == draft.layerID }),
			let name = draft.originalName
		else { return nil }
		return layer.document.value(at: [layer.shape.serverKey, name])
	}

	private func shape(for draft: ServerDraft) -> MCPServerShape {
		snapshot?.layers.first { $0.id == draft.layerID }?.shape ?? snapshot?.shape ?? .pi
	}

	private func buildValue(_ draft: ServerDraft) -> JSONValue {
		MCPShape.mergedServer(
			existing: existingServer(draft),
			draft: MCPShape.MCPServerDraft(
				command: draft.command,
				args: draft.argsText
					.split(separator: "\n", omittingEmptySubsequences: true)
					.map { $0.trimmingCharacters(in: .whitespaces) }
					.filter { !$0.isEmpty },
				url: draft.url,
				disabled: draft.disabled
			),
			shape: shape(for: draft)
		)
	}

	private func apply(_ draft: ServerDraft) {
		guard let snapshot,
			let layer = snapshot.layers.first(where: { $0.id == draft.layerID })
		else { return }
		let document = JSONFile.load(layer.url, policy: policy)
		var value = document.editableValue
		let name = draft.name.trimmingCharacters(in: .whitespaces)
		if let original = draft.originalName, original != name {
			value.removeValue(at: [layer.shape.serverKey, original])
		}
		value.setValue(buildValue(draft), at: [layer.shape.serverKey, name])
		do {
			let result = try JSONFile.write(value, document: document, scope: resolver, policy: policy)
			controller.banner = result.backupURL.map {
				String(format: L.t("banner.writtenWithBackup", "已写入，备份 %@"), $0.lastPathComponent)
			} ?? String(
				format: L.t("banner.writtenTo", "已写入 %@"),
				result.url.lastPathComponent
			)
			controller.errorText = nil
			self.draft = nil
			reload()
		} catch {
			controller.errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	private func toggleDisabled(_ item: MCPEffective) {
		let shape = item.winner.shape
		controller.load(url: item.winner.url, resolver: resolver, policy: policy)
		var value = controller.editable
		if item.isDisabled {
			// Back to the default: drop the key rather than write its no-op value.
			value.removeValue(at: [shape.serverKey, item.name, shape.toggleKey ?? "disabled"])
		} else {
			var server = item.value
			shape.setDisabled(true, in: &server)
			value.setValue(server, at: [shape.serverKey, item.name])
		}
		controller.stage(value)
	}

	private func deleteServer(_ item: MCPEffective) {
		controller.load(url: item.winner.url, resolver: resolver, policy: policy)
		var value = controller.editable
		value.removeValue(at: [item.winner.shape.serverKey, item.name])
		controller.stage(value)
	}
}

/// Renders a condensed diff inline (used by the repair sheet).
struct DiffPreviewList: View {
	let diff: TextDiff
	var limit = 40

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(Array(diff.lines.filter { $0.kind != .equal }.prefix(limit).enumerated()), id: \.offset) { _, line in
				HStack(alignment: .top, spacing: 6) {
					Text(line.kind == .insert ? "+" : "−")
						.foregroundStyle(line.kind == .insert ? .green : .red)
					Text(line.text.isEmpty ? " " : line.text)
						.foregroundStyle(line.kind == .insert ? .green : .red)
						.textSelection(.enabled)
				}
				.font(.system(size: 11, design: .monospaced))
			}
			if diff.lines.filter({ $0.kind != .equal }).count > limit {
				Text(L.t("diff.moreLines", "… 还有更多差异")).font(.caption2).foregroundStyle(.tertiary)
			}
		}
		.padding(6)
		.background(
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.fill(Color(nsColor: .textBackgroundColor))
		)
	}
}
