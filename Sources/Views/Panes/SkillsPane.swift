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
	@State private var query = ""
	@State private var selectedID: String?
	@State private var banner: String?
	@State private var errorText: String?
	@State private var creating: CreateRequest?
	@State private var confirmDelete: SkillEntry?
	@State private var confirmDisable: SkillEntry?
	@State private var token = UUID()

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
		let needle = query.lowercased()
		return snapshot.skills.filter {
			$0.name.lowercased().contains(needle)
				|| $0.description.lowercased().contains(needle)
				|| $0.directory.path.lowercased().contains(needle)
		}
	}

	private var selected: SkillEntry? {
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
		.task(id: token) { scan() }
		.onChange(of: model.externalChangeToken) { _, _ in scan() }
		.onChange(of: model.projectURL) { _, _ in scan() }
		.sheet(item: $creating) { request in createSheet(request) }
		.alert("删除这个 skill？", isPresented: Binding(
			get: { confirmDelete != nil },
			set: { if !$0 { confirmDelete = nil } }
		), presenting: confirmDelete) { entry in
			Button("移到废纸篓", role: .destructive) {
				do {
					try TextFile.trash(entry.directory)
					banner = "已把 \(entry.directory.lastPathComponent) 移到废纸篓"
					confirmDelete = nil
					scan()
				} catch {
					errorText = error.localizedDescription
					confirmDelete = nil
				}
			}
			Button("取消", role: .cancel) { confirmDelete = nil }
		} message: { entry in
			Text("\(entry.directory.path)\n\n整个目录会移到废纸篓，可以恢复。")
		}
		.alert("停用这个 skill？", isPresented: Binding(
			get: { confirmDisable != nil },
			set: { if !$0 { confirmDisable = nil } }
		), presenting: confirmDisable) { entry in
			Button("停用") {
				do {
					try SkillsScanner.setEnabled(entry, enabled: false)
					banner = "已停用，目录移到了 .disabled/"
					confirmDisable = nil
					scan()
				} catch {
					errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
					confirmDisable = nil
				}
			}
			Button("取消", role: .cancel) { confirmDisable = nil }
		} message: { entry in
			Text("pi 没有单个 skill 的开关，所以 AgentKit 用自己约定：把 \(entry.directory.lastPathComponent) 移到同级 .disabled/ 下，pi 就不会再发现它。需要时可以从这个面板再启用回来。")
		}
	}

	// MARK: - Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.title).font(.title3.weight(.semibold))
				if let snapshot {
					StatusBadge(text: "\(snapshot.skills.count) 个 skill", level: .info)
					if snapshot.problemCount > 0 {
						StatusBadge(text: "\(snapshot.problemCount) 个有问题", level: .warning)
					}
					if !snapshot.disabled.isEmpty {
						StatusBadge(text: "\(snapshot.disabled.count) 个已停用", level: .muted)
					}
				}
				if scanning { ProgressView().controlSize(.mini) }
				Spacer()
				Menu {
					ForEach(Array(roots.enumerated()), id: \.offset) { _, entry in
						Button(entry.url.path) { creating = CreateRequest(root: entry.url) }
					}
				} label: {
					Label("新建 skill", systemImage: "plus")
				}
				.controlSize(.small)
				.disabled(roots.filter { $0.spec.isWritable }.isEmpty)
				Button {
					scan()
				} label: {
					Label("重新扫描", systemImage: "arrow.clockwise")
				}
				.controlSize(.small)
			}
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
				TextField("搜索", text: $query)
					.textFieldStyle(.roundedBorder)
			}
			ProjectScopeBanner(surface: surface)
			if let banner { InfoBanner(kind: .info, title: banner) }
			if let errorText { InfoBanner(kind: .error, title: errorText) }
			if let snapshot, !snapshot.missingRoots.isEmpty {
				InfoBanner(
					kind: .info,
					title: "以下目录不存在，已跳过",
					detail: snapshot.missingRoots.map(\.path).joined(separator: "\n")
				)
			}
		}
		.padding(14)
	}

	// MARK: - List

	private var list: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 2) {
				ForEach(filtered) { entry in
					row(entry)
				}
				if let snapshot, !snapshot.missingManifest.isEmpty {
					Text("没有 SKILL.md 的目录")
						.font(.caption.weight(.semibold))
						.foregroundStyle(.secondary)
						.padding(.horizontal, 8)
						.padding(.top, 10)
					ForEach(snapshot.missingManifest) { item in
						HStack(spacing: 6) {
							Image(systemName: "folder").font(.caption2).foregroundStyle(.tertiary)
							Text(item.url.lastPathComponent).font(.caption)
							Spacer(minLength: 0)
							Text("不会被发现").font(.caption2).foregroundStyle(.tertiary)
						}
						.padding(.horizontal, 10)
						.padding(.vertical, 2)
					}
				}
			}
			.padding(.vertical, 6)
		}
		.frame(width: 320)
		.background(Color(nsColor: .controlBackgroundColor))
	}

	private func row(_ entry: SkillEntry) -> some View {
		let isSelected = selected?.id == entry.id
		return Button {
			selectedID = entry.id
		} label: {
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
					if entry.isSymlink {
						Image(systemName: "link").font(.caption2).foregroundStyle(.orange)
							.help("符号链接 → \(entry.realDirectory.path)")
					}
					if !entry.issues.isEmpty {
						Image(systemName: "exclamationmark.triangle.fill")
							.font(.caption2)
							.foregroundStyle(.orange)
					}
					Spacer(minLength: 0)
					Text(entry.scope == "project" ? "项目" : "用户")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				Text(entry.description)
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(2)
				Text(entry.directory.path)
					.font(.system(size: 10, design: .monospaced))
					.foregroundStyle(.tertiary)
					.lineLimit(1)
					.truncationMode(.head)
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
		if let entry = selected {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					VStack(alignment: .leading, spacing: 6) {
						HStack(spacing: 8) {
							Text(entry.name).font(.title3.weight(.semibold))
							StatusBadge(text: entry.scope == "project" ? "项目级" : "用户级", level: .info)
							if entry.disableModelInvocation {
								StatusBadge(text: "仅手动调用", level: .muted)
							}
							if !entry.writable { StatusBadge(text: "只读", level: .muted) }
						}
						Text(entry.description)
							.font(.callout)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}

					if !entry.issues.isEmpty {
						InfoBanner(kind: .error, title: "pi 可能不会加载这个 skill", detail: entry.issues.joined(separator: "\n"))
					}
					if !entry.warnings.isEmpty {
						InfoBanner(kind: .warning, title: "提示", detail: entry.warnings.joined(separator: "\n"))
					}

					Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
						detailRow("SKILL.md", entry.url.path, monospaced: true)
						detailRow("目录", entry.directory.path, monospaced: true)
						if entry.isSymlink {
							detailRow("符号链接指向", entry.realDirectory.path, monospaced: true)
						}
						detailRow("声明名", entry.frontmatter.string("name") ?? "（未声明）")
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
						VStack(alignment: .leading, spacing: 5) {
							Text("随包文件").font(.caption.weight(.semibold))
							HStack(spacing: 6) {
								ForEach(entry.topLevel.prefix(14), id: \.self) { name in
									Text(name)
										.font(.system(size: 10.5, design: .monospaced))
										.padding(.horizontal, 6)
										.padding(.vertical, 2)
										.background(
											RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .quaternarySystemFill))
										)
								}
								if entry.topLevel.count > 14 {
									Text("…还有 \(entry.topLevel.count - 14) 项")
										.font(.caption2)
										.foregroundStyle(.tertiary)
								}
							}
						}
					}

					Divider()

					HStack(spacing: 8) {
						Button {
							ShellActions.openExternally(entry.url)
						} label: {
							Label("编辑 SKILL.md", systemImage: "square.and.pencil")
						}
						Button {
							ShellActions.reveal(entry.directory)
						} label: {
							Label("在 Finder 中显示", systemImage: "folder")
						}
						Button {
							confirmDisable = entry
						} label: {
							Label("停用", systemImage: "eye.slash")
						}
						.disabled(!entry.writable)
						Button(role: .destructive) {
							confirmDelete = entry
						} label: {
							Label("删除…", systemImage: "trash")
						}
						.disabled(!entry.writable)
					}

					if !(snapshot?.disabled.isEmpty ?? true) {
						Divider()
						VStack(alignment: .leading, spacing: 6) {
							Text("已停用（AgentKit 约定，位于 .disabled/）").font(.caption.weight(.semibold))
							ForEach(snapshot?.disabled ?? [], id: \.path) { url in
								HStack(spacing: 6) {
									Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
									Spacer()
									Button("启用") { enable(url) }
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
				title: query.isEmpty ? "没有找到 skill" : "没有匹配的 skill",
				message: query.isEmpty
					? "已扫描：" + roots.map(\.url.path).joined(separator: "\n")
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
		let roots = self.roots
		let ignore = Set(surface.ignore ?? [])
		let maxDepth = surface.maxDepth ?? 6
		let policy = self.policy
		Task.detached(priority: .userInitiated) {
			let snapshot = SkillsScanner.scan(roots: roots, ignore: ignore, maxDepth: maxDepth, policy: policy)
			await MainActor.run {
				self.snapshot = snapshot
				self.scanning = false
				if selectedID == nil || !snapshot.skills.contains(where: { $0.id == selectedID }) {
					selectedID = snapshot.skills.first?.id
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
			banner = "已启用 \(name)"
			scan()
		} catch {
			errorText = error.localizedDescription
		}
	}

	private func createSheet(_ request: CreateRequest) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("新建 skill").font(.headline)
			PathChip(path: request.root.path)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
				GridRow {
					Text("name").gridColumnAlignment(.trailing)
					TextField("小写字母、数字、连字符", text: Binding(
						get: { creating?.name ?? "" },
						set: { creating?.name = $0 }
					))
					.textFieldStyle(.roundedBorder)
				}
				GridRow {
					Text("description").gridColumnAlignment(.trailing)
					TextField("做什么、什么时候用", text: Binding(
						get: { creating?.description ?? "" },
						set: { creating?.description = $0 }
					))
					.textFieldStyle(.roundedBorder)
				}
			}
			let name = (creating?.name ?? "").trimmingCharacters(in: .whitespaces)
			if !name.isEmpty, !SkillsScanner.isValidName(name) {
				InfoBanner(kind: .warning, title: "name 不符合 Agent Skills 规范（只能小写字母、数字和连字符）")
			}
			Text("会创建 \(request.root.appendingPathComponent(name.isEmpty ? "<name>" : name).path)，其中包含 SKILL.md 与 scripts/ 目录。")
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				Button("取消") { creating = nil }
				Button("创建") { create(request) }
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
			banner = "已创建 \(manifest.path)"
			scan()
			selectedID = manifest.path
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
			creating = nil
		}
	}
}
