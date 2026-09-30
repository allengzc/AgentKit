//
//  SkillsPane.swift
//  AgentKit
//
//  Skills 面板：扫描各个根目录下的 SKILL.md，展示 frontmatter、校验问题与
//  随包文件，并提供启用/停用、新建、删除。
//

import SwiftUI

struct SkillsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var snapshot: SkillsSnapshot?
	@State private var scanning = false
	/// Set when something outside AgentKit changed a skill root. The header then
	/// offers a rescan instead of the pane rescanning on its own — see the note at
	/// `onChange(of: model.externalChangeToken)`.
	@State private var stale = false
	/// Seeded from `AGENTKIT_DOC_STATE=search:<text>` so a screenshot (or a
	/// verification run) can put the row filter into a state that otherwise
	/// needs typing into the field — the filtered list is the one path where a
	/// row's cost used to depend on the size of the library.
	@State private var query = DocumentationState.string("search") ?? ""
	@State private var selectedID: String?
	@State private var banner: String?
	@State private var errorText: String?
	@State private var creating: CreateRequest?
	@State private var confirmDelete: SkillEntry?
	@State private var confirmDisable: SkillEntry?
	@State private var token = UUID()
	/// Bumped by every `scan()`; only the newest request may publish (see `scan`).
	@State private var scanGeneration = 0
	/// The bundled-file list starts as a short preview: a skill can ship 30+
	/// files and the detail pane should stay readable.
	@State private var showsAllBundled = false
	@State private var expandedFolders: Set<String> = []

	private let bundledPreviewLimit = 7

	private struct CreateRequest: Identifiable {
		let id = UUID()
		let root: URL
		var name = ""
		var description = ""
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	private var roots: [(spec: RootEntry, url: URL)] {
		(surface.roots ?? []).compactMap { spec in
			guard let url = try? resolver.expand(spec.path) else { return nil }
			return (spec, url)
		}
	}

	private var filtered: [SkillEntry] {
		guard let snapshot else { return [] }
		guard !query.isEmpty else { return snapshot.skills }
		// One `contains` against a precomputed lowercased haystack; matching the
		// three fields separately meant three `lowercased()` allocations per
		// skill per keystroke.
		let needle = query.lowercased()
		return snapshot.skills.filter { $0.searchText.contains(needle) }
	}

	/// The entry a row's highlight and the detail pane agree on.
	///
	/// Takes the already-filtered list: resolving it through `filtered` per row
	/// made one body pass O(rows × skills) *and* re-ran the whole search filter
	/// for every row, which measured 2.4 s with 500 skills and a query typed.
	private func selected(in entries: [SkillEntry]) -> SkillEntry? {
		guard let selectedID else { return entries.first }
		return entries.first { $0.id == selectedID } ?? entries.first
	}

	/// The selection for callers outside `body` (the scan's completion handler).
	private var selected: SkillEntry? { selected(in: filtered) }

	var body: some View {
		let entries = filtered
		let current = selected(in: entries)
		return VStack(spacing: 0) {
			header
			Divider()
			HStack(spacing: 0) {
				list(entries, current: current)
				Divider()
				detail(current)
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.task(id: token) { scan() }
		.onChange(of: selectedID) { _, _ in
			showsAllBundled = false
			expandedFolders = []
		}
		// An external edit used to rescan straight away. The watcher reports
		// everything under an agent's root, and while the agent runs that includes
		// its own session traffic — measured: 6 change batches in 2.5 s while a
		// session log was being appended to, i.e. a full rescan ~2.4x per second.
		// Each one replaced the snapshot, so the list was rebuilt (scroll position,
		// hover and expanded folders reset) faster than anyone could read it.
		//
		// Now a change that touches a skill root only marks the list stale and the
		// header offers the rescan: one click, at the moment the user wants it.
		.onChange(of: model.externalChangeToken) { _, _ in
			if model.externalChangeTouches(roots.map(\.url)) { stale = true }
		}
		.onChange(of: model.projectURL) { _, _ in scan() }
		// "Rescan" left the header for the toolbar's ⋯ menu: the pane already
		// rescans when a descriptor changes and when the project scope moves, so
		// the button was a manual fallback for a watcher that is usually right —
		// and it took a slot next to the one action a newcomer needs to find,
		// "new skill".
		.paneActions(token: paneActionToken(agent: agent, surface: surface), title: surface.titleText) {
			[
				.command(
					id: "skills.rescan",
					title: L.t("button.rescan", "重新扫描"),
					systemImage: "arrow.clockwise"
				) { scan() }
			]
		}
		.sheet(item: $creating) { request in createSheet(request) }
		.alert(L.t("skills.delete.title", "删除这个 skill？"), isPresented: Binding(
			get: { confirmDelete != nil },
			set: { if !$0 { confirmDelete = nil } }
		), presenting: confirmDelete) { entry in
			Button(L.t("button.moveToTrash", "移到废纸篓"), role: .destructive) {
				do {
					try TextFile.trash(entry.directory)
					banner = String(
						format: L.t("banner.movedToTrash", "已把 %@ 移到废纸篓"),
						entry.directory.lastPathComponent
					)
					confirmDelete = nil
					scan()
				} catch {
					errorText = error.localizedDescription
					confirmDelete = nil
				}
			}
			Button(L.t("button.cancel", "取消"), role: .cancel) { confirmDelete = nil }
		} message: { entry in
			Text(
				String(
					format: L.t("skills.delete.message", "%@\n\n整个目录会移到废纸篓，可以恢复。"),
					entry.directory.path
				)
			)
		}
		.alert(L.t("skills.disable.title", "停用这个 skill？"), isPresented: Binding(
			get: { confirmDisable != nil },
			set: { if !$0 { confirmDisable = nil } }
		), presenting: confirmDisable) { entry in
			Button(L.t("button.disable", "停用")) {
				do {
					try SkillsScanner.setEnabled(entry, enabled: false)
					banner = L.t("skills.disable.banner", "已停用，目录移到了 .disabled/")
					confirmDisable = nil
					scan()
				} catch {
					errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
					confirmDisable = nil
				}
			}
			Button(L.t("button.cancel", "取消"), role: .cancel) { confirmDisable = nil }
		} message: { entry in
			Text(
				String(
					format: L.t(
						"skills.disable.message",
						"pi 没有单个 skill 的开关，所以 AgentKit 用自己约定：把 %@ 移到同级 .disabled/ 下，pi 就不会再发现它。需要时可以从这个面板再启用回来。"
					),
					entry.directory.lastPathComponent
				)
			)
		}
	}

	// MARK: - Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				if let snapshot {
					StatusBadge(
						text: String(format: L.t(snapshot.skills.count == 1 ? "skills.badge.skillCount.one" : "skills.badge.skillCount", "%d 个 skill"), snapshot.skills.count),
						level: .info
					)
					if snapshot.problemCount > 0 {
						StatusBadge(
							text: String(
								format: L.t(snapshot.problemCount == 1 ? "skills.badge.problemCount.one" : "skills.badge.problemCount", "%d 个有问题"),
								snapshot.problemCount
							),
							level: .warning
						)
					}
					if !snapshot.disabled.isEmpty {
						StatusBadge(
							text: String(
								format: L.t("skills.badge.disabledCount", "%d 个已停用"),
								snapshot.disabled.count
							),
							level: .muted
						)
					}
				}
				if scanning { ProgressView().controlSize(.mini) }
				Spacer()
				// Sits in the existing first row rather than as its own banner: the
				// header's height is what pushes the window's content past the
				// window (see README 已知限制), so a "there is newer content"
				// notice must not add a row to it.
				if stale, !scanning {
					Button {
						scan()
					} label: {
						Label(
							L.t("skills.stale.rescan", "有外部改动 · 重新扫描"),
							systemImage: "arrow.clockwise"
						)
					}
					.controlSize(.small)
					.help(
						L.t(
							"skills.stale.help",
							"skill 目录在 AgentKit 之外被改动了，列表是上次扫描的结果；点一下重新扫描"
						)
					)
				}
				Menu {
					ForEach(Array(roots.enumerated()), id: \.offset) { _, entry in
						Button(entry.url.path) { creating = CreateRequest(root: entry.url) }
					}
				} label: {
					Label(L.t("button.newSkill", "新建 skill"), systemImage: "plus")
				}
				.controlSize(.small)
				.disabled(roots.filter { $0.spec.isWritable }.isEmpty)
			}
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
				TextField(L.t("skills.searchPlaceholder", "搜索"), text: $query)
					.textFieldStyle(.roundedBorder)
			}
			ProjectScopeBanner(surface: surface)
			if let banner { InfoBanner(kind: .info, title: banner) }
			if let errorText { InfoBanner(kind: .error, title: errorText) }
			if let snapshot, !snapshot.missingRoots.isEmpty {
				InfoBanner(
					kind: .info,
					title: L.t("skills.missingRoots.title", "以下目录不存在，已跳过"),
					detail: snapshot.missingRoots.map(\.path).joined(separator: "\n")
				)
			}
		}
		.padding(14)
	}

	// MARK: - List

	private func list(_ entries: [SkillEntry], current: SkillEntry?) -> some View {
		ScrollView {
			// 1pt, not 2: see the padding note in `row`. Rows are separated by
			// their own padding now; this only keeps the selection highlights
			// from touching.
			LazyVStack(alignment: .leading, spacing: 1) {
				ForEach(entries) { entry in
					row(entry, isSelected: current?.id == entry.id)
				}
				if let snapshot, !snapshot.missingManifest.isEmpty {
					Text(L.t("skills.missingManifest", "没有 SKILL.md 的目录"))
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 8)
						.padding(.top, 10)
					ForEach(snapshot.missingManifest) { item in
						HStack(spacing: 6) {
							Image(systemName: "folder").font(.caption2).foregroundStyle(.tertiary)
							Text(item.url.lastPathComponent).font(.caption)
							Spacer(minLength: 0)
							Text(L.t("skills.notDiscovered", "不会被发现")).font(.caption2).foregroundStyle(.tertiary)
						}
						.padding(.horizontal, 10)
						.padding(.vertical, 2)
					}
				}
			}
			.padding(.vertical, 6)
		}
		.frame(width: 320)
		// No fill of its own: see `paneListBackground()`. `controlBackgroundColor`
		// happens to equal the pane's background in light mode and is visibly
		// darker in dark mode, which is what made this column a black slab there.
	}

	private func row(_ entry: SkillEntry, isSelected: Bool) -> some View {
		// `description` may be absent, empty, or a block scalar of blanks; the
		// row renders nothing for all three. See the note at the Text below.
		let description = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
		return Button {
			selectedID = entry.id
		} label: {
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
					if entry.isSymlink {
						Image(systemName: "link").font(.caption2).foregroundStyle(.orange)
							.help(
								String(
									format: L.t("skills.help.symlink", "符号链接 → %@"),
									entry.realDirectory.path
								)
							)
					}
					if !entry.issues.isEmpty {
						Image(systemName: "exclamationmark.triangle.fill")
							.font(.caption2)
							.foregroundStyle(.orange)
					}
					Spacer(minLength: 0)
					Text(entry.scope == "project" ? L.t("badge.scopeProject", "项目") : L.t("badge.scopeUser", "用户"))
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				// A skill whose manifest has no `description:` (or only blanks)
				// must not render the Text at all. `Text("")` still lays out a
				// full line — measured: 14pt at `.caption2`, one point *more*
				// than a real line, and 0 wide, so it is invisible. Together
				// with the 3pt stack spacing that was 17pt of blank band
				// between the name and the path of every such row.
				if entry.hasDescription {
					Text(description)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.lineLimit(2)
				}
				// The directory used to be a third text line here. It is now the
				// row's tooltip instead: the column is 320pt wide, so
				// `.truncationMode(.head)` left it as
				// "…ate/tmp/kit-demo/.pi/agent/skills/pdf-tools" — 90% ellipsis —
				// while its information is already four-deep elsewhere: the name
				// is the leaf, the badge gives the scope, the detail pane prints
				// the directory in full, and hovering says the rest. It cost
				// 13pt of text plus 3pt of stack spacing, 23% of the row.
			}
			// 3pt, not 5: the gap between two rows measured 15.5pt of ink
			// against 3.5pt between the two lines of a description — a 4.4x
			// contrast, which is what made the list read as airy. Removing the
			// path line is what keeps this from getting cramped.
			.padding(.vertical, 3)
			.padding(.horizontal, 8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		// Where the directory line went: the whole row is the hover target now,
		// which is a bigger one than the 10pt monospaced line it replaced.
		.help(entry.directory.path)
	}

	// MARK: - Detail

	@ViewBuilder
	private func detail(_ entry: SkillEntry?) -> some View {
		if let entry {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					VStack(alignment: .leading, spacing: 6) {
						HStack(spacing: 8) {
							Text(entry.name).font(.title3.weight(.semibold))
							StatusBadge(
								text: entry.scope == "project"
									? L.t("badge.scopeProjectLevel", "项目级")
									: L.t("badge.scopeUserLevel", "用户级"),
								level: .info
							)
							if entry.disableModelInvocation {
								StatusBadge(text: L.t("skills.badge.manualOnly", "仅手动调用"), level: .muted)
							}
							if !entry.writable { StatusBadge(text: L.t("badge.readOnly", "只读"), level: .muted) }
						}
						Text(entry.description)
							.font(.callout)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}

					if !entry.issues.isEmpty {
						InfoBanner(
							kind: .error,
							title: L.t("skills.issues.title", "pi 可能不会加载这个 skill"),
							detail: entry.issues.joined(separator: "\n")
						)
					}
					if !entry.warnings.isEmpty {
						InfoBanner(
							kind: .warning,
							title: L.t("skills.warnings.title", "提示"),
							detail: entry.warnings.joined(separator: "\n")
						)
					}

					Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
						detailRow("SKILL.md", entry.url.path, monospaced: true)
						detailRow(L.t("skills.detail.directory", "目录"), entry.directory.path, monospaced: true)
						if entry.isSymlink {
							detailRow(
								L.t("skills.detail.symlinkTarget", "符号链接指向"),
								entry.realDirectory.path,
								monospaced: true
							)
						}
						detailRow(
							L.t("skills.detail.declaredName", "声明名"),
							entry.frontmatter.string("name") ?? L.t("skills.detail.undeclared", "（未声明）")
						)
						if let license = entry.license { detailRow("license", license) }
						if let compatibility = entry.compatibility { detailRow("compatibility", compatibility) }
						if let tools = entry.allowedTools {
							detailRow("allowed-tools", tools.joined(separator: ", "), monospaced: true)
						}
						if let metadata = entry.frontmatter.value("metadata") {
							detailRow("metadata", metadata.displayText, monospaced: true)
						}
					}

					if !entry.topLevel.isEmpty {
						bundledFiles(entry)
					}

					Divider()

					HStack(spacing: 8) {
						Button {
							ShellActions.openExternally(entry.url)
						} label: {
							Label(L.t("button.editSkillFile", "编辑 SKILL.md"), systemImage: "square.and.pencil")
						}
						Button {
							ShellActions.reveal(entry.directory)
						} label: {
							Label(L.t("button.revealInFinder", "在 Finder 中显示"), systemImage: "folder")
						}
						Button {
							confirmDisable = entry
						} label: {
							Label(L.t("button.disable", "停用"), systemImage: "eye.slash")
						}
						.disabled(!entry.writable)
						Button(role: .destructive) {
							confirmDelete = entry
						} label: {
							Label(L.t("button.delete", "删除…"), systemImage: "trash")
						}
						.disabled(!entry.writable)
					}

					if !(snapshot?.disabled.isEmpty ?? true) {
						Divider()
						VStack(alignment: .leading, spacing: 6) {
							Text(L.t("skills.disabledSection.title", "已停用（AgentKit 约定，位于 .disabled/）"))
								.font(.caption.weight(.semibold))
							ForEach(snapshot?.disabled ?? [], id: \.path) { url in
								HStack(spacing: 6) {
									Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
									Spacer()
									Button(L.t("button.enable", "启用")) { enable(url) }
										.controlSize(.mini)
								}
							}
						}
					}
				}
				.padding(16)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		} else {
			EmptyStateView(
				icon: "puzzlepiece.extension",
				title: query.isEmpty
					? L.t("empty.noSkills", "没有找到 skill")
					: L.t("empty.noMatchingSkills", "没有匹配的 skill"),
				message: query.isEmpty
					? String(
						format: L.t("empty.noSkills.scanned", "已扫描：%@"),
						roots.map(\.url.path).joined(separator: "\n")
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
				.lineLimit(3)
				.truncationMode(.middle)
		}
	}

	// MARK: - Actions

	private func scan() {
		scanning = true
		// A scan is requested by the file watcher, by a scope change and by the
		// toolbar action, and a walk in flight cannot be cancelled mid-directory.
		// Overlapping scans used to race on both the snapshot and the spinner:
		// the first one to finish cleared `scanning`, and an *older* result could
		// overwrite a newer one. The generation stamp lets only the last request
		// publish.
		scanGeneration += 1
		let generation = scanGeneration
		let roots = self.roots
		let ignore = Set(surface.ignore ?? [])
		let maxDepth = surface.maxDepth ?? 6
		let policy = self.policy
		Task.detached(priority: .userInitiated) {
			let snapshot = SkillsScanner.scan(roots: roots, ignore: ignore, maxDepth: maxDepth, policy: policy)
			await MainActor.run {
				guard generation == scanGeneration else { return }
				self.snapshot = snapshot
				self.scanning = false
				self.stale = false
				if selectedID == nil || !snapshot.skills.contains(where: { $0.id == selectedID }) {
					// Opening on a skill that pi will not load is a poor first
					// impression when a healthy one is right there.
					let healthy = snapshot.skills.first { $0.issues.isEmpty }
					selectedID = (healthy ?? snapshot.skills.first)?.id
				}
				if let folder = DocumentationState.string("expand"), folder != "1",
					let entry = self.selected,
					let item = entry.topLevel.first(where: { $0.name == folder })
				{
					expandedFolders.insert(item.id)
				}
			}
		}
	}

	private func enable(_ url: URL) {
		let name = url.lastPathComponent
		let root = url.deletingLastPathComponent().deletingLastPathComponent()
		let destination = root.appendingPathComponent(name)
		do {
			try FileManager.default.moveItem(at: url, to: destination)
			banner = String(format: L.t("banner.enabled", "已启用 %@"), name)
			scan()
		} catch {
			errorText = error.localizedDescription
		}
	}

	private func createSheet(_ request: CreateRequest) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(L.t("button.newSkill", "新建 skill")).font(.headline)
			PathChip(path: request.root.path)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
				GridRow {
					Text("name").gridColumnAlignment(.trailing)
					TextField(L.t("skills.create.namePlaceholder", "小写字母、数字、连字符"), text: Binding(
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
			let name = (creating?.name ?? "").trimmingCharacters(in: .whitespaces)
			if !name.isEmpty, !SkillsScanner.isValidName(name) {
				InfoBanner(
					kind: .warning,
					title: L.t(
						"skills.create.invalidName",
						"name 不符合 Agent Skills 规范（只能小写字母、数字和连字符）"
					)
				)
			}
			Text(
				String(
					format: L.t("skills.create.detail", "会创建 %@，其中包含 SKILL.md 与 scripts/ 目录。"),
					request.root.appendingPathComponent(name.isEmpty ? "<name>" : name).path
				)
			)
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button(L.t("button.cancel", "取消")) { creating = nil }
				Button(L.t("button.create", "创建")) { create(request) }
					.buttonStyle(.borderedProminent)
					.disabled(!SkillsScanner.isValidName(name) || (creating?.description ?? "").isEmpty)
			}
		}
		.padding(16)
		.frame(minWidth: 560)
	}

	private func create(_ request: CreateRequest) {
		let name = (creating?.name ?? "").trimmingCharacters(in: .whitespaces)
		let description = (creating?.description ?? "").trimmingCharacters(in: .whitespaces)
		do {
			let manifest = try SkillsScanner.createSkill(named: name, in: request.root, description: description)
			creating = nil
			banner = String(format: L.t("banner.createdAt", "已创建 %@"), manifest.path)
			scan()
			selectedID = manifest.path
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
			creating = nil
		}
	}

	// MARK: - 随包文件

	/// A skill ships anything from one manifest to a whole tree of references and
	/// scripts, so this is a list, not a row of chips. The old chip layout put
	/// every name in one competing `HStack`: each label was squeezed until it
	/// wrapped one letter per line.
	private func bundledFiles(_ entry: SkillEntry) -> some View {
		let items = entry.topLevel
		let visible = showsAllBundled ? items : Array(items.prefix(bundledPreviewLimit))
		return VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Text(L.t("skills.bundled.title", "随包文件")).font(.caption.weight(.semibold))
				Text(String(format: L.t(items.count == 1 ? "skills.bundled.count.one" : "skills.bundled.count", "%d 项"), items.count))
					.font(.caption2)
					.foregroundStyle(.tertiary)
				Spacer()
			}
			VStack(spacing: 0) {
				ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
					if index > 0 {
						Divider().padding(.leading, 34)
					}
					if item.isDirectory {
						directoryRow(item, in: entry.directory)
					} else {
						fileRow(item, in: entry.directory)
					}
				}
			}
			.padding(.vertical, 2)
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(Color(nsColor: .controlBackgroundColor))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
			)

			if items.count > bundledPreviewLimit {
				Button(
					showsAllBundled
						? L.t("button.collapse", "收起")
						: String(
							format: L.t("skills.bundled.showAll", "显示全部 %d 项"),
							items.count
						)
				) {
					showsAllBundled.toggle()
				}
				.buttonStyle(.link)
				.controlSize(.small)
				.font(.caption)
			}
		}
	}

	/// A folder uses the platform's own disclosure control.
	///
	/// An earlier version drew its own chevron and toggled a set from a Button
	/// action. Expansion is the one interaction that has to work every time, and
	/// a control the system provides costs nothing here: its hit testing, its
	/// animation and its accessibility are Apple's. The binding is still backed by
	/// view state so the children can be driven programmatically for verification.
	private func directoryRow(_ item: SkillItem, in directory: URL) -> some View {
		DisclosureGroup(isExpanded: expansion(for: item)) {
			ForEach(item.children) { child in
				HStack(spacing: 6) {
					Color.clear.frame(width: 9)
					Image(systemName: fileIcon(child))
						.font(.caption)
						.foregroundStyle(.secondary)
						.frame(width: 15)
					Text(child.name)
						.font(.system(size: 11.5, design: .monospaced))
						.lineLimit(1)
						.truncationMode(.middle)
						.frame(maxWidth: .infinity, alignment: .leading)
					Text(child.displaySize)
						.font(.system(size: 10.5, design: .monospaced))
						.foregroundStyle(.tertiary)
						.lineLimit(1)
						.layoutPriority(1)
				}
				.padding(.leading, 19)
				.padding(.trailing, 8)
				.padding(.vertical, 2)
				.help(directory.appendingPathComponent(item.name).appendingPathComponent(child.name).path)
			}
		} label: {
			rowLabel(item, indented: false)
		}
		.padding(.leading, 8)
		.padding(.trailing, 8)
		.padding(.vertical, 1)
		.help(
			String(
				format: expandedFolders.contains(item.id)
					? L.t("skills.help.folderExpanded", "%@（已展开）")
					: L.t("skills.help.folderCollapsed", "%@（已折叠）"),
				directory.appendingPathComponent(item.name).path
			)
		)
	}

	private func fileRow(_ item: SkillItem, in directory: URL) -> some View {
		let url = directory.appendingPathComponent(item.name)
		return Button {
			ShellActions.reveal(url)
		} label: {
			rowLabel(item, indented: false)
		}
		.buttonStyle(.plain)
		.padding(.leading, 8)
		.padding(.trailing, 8)
		.padding(.vertical, 1)
		.help(url.path)
	}

	/// Leading spacing plus the icon, name and size, without any disclosure
	/// control: the caller supplies that, so the two row kinds line up.
	private func rowLabel(_ item: SkillItem, indented: Bool) -> some View {
		HStack(spacing: 6) {
			Image(systemName: fileIcon(item))
				.font(.caption)
				.foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
				.frame(width: 15)
			// One line, middle-truncated. A name must never wrap: wrapping is
			// what turned these into columns of single letters.
			Text(item.name)
				.font(.system(size: 11.5, design: .monospaced))
				.lineLimit(1)
				.truncationMode(.middle)
				.frame(maxWidth: .infinity, alignment: .leading)
			Text(item.displaySize)
				.font(.system(size: 10.5, design: .monospaced))
				.foregroundStyle(.tertiary)
				.lineLimit(1)
				.layoutPriority(1)
		}
		.padding(.vertical, 3)
		.contentShape(Rectangle())
	}

	private func expansion(for item: SkillItem) -> Binding<Bool> {
		Binding(
			get: { expandedFolders.contains(item.id) },
			set: { open in
				if open {
					expandedFolders.insert(item.id)
				} else {
					expandedFolders.remove(item.id)
				}
			}
		)
	}

	private func fileIcon(_ item: SkillItem) -> String {
		guard !item.isDirectory else { return "folder" }
		switch (item.name as NSString).pathExtension.lowercased() {
		case "md", "markdown", "mdx": return "doc.text"
		case "json", "toml", "yaml", "yml": return "curlybraces"
		case "sh", "bash", "zsh", "py", "js", "ts", "rb", "pl", "lua": return "terminal"
		case "swift": return "swift"
		case "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf": return "photo"
		case "csv", "tsv": return "tablecells"
		case "txt", "log": return "text.alignleft"
		default: return "doc"
		}
	}
}

