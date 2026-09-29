//
//  ResourcesPane.swift
//  AgentKit
//
//  主题、扩展、Prompt 模板，以及 settings.json 里声明的 Pi Packages。
//

import SwiftUI

struct ResourcesPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var entries: [ResourceEntry] = []
	@State private var packages: [PackageEntry] = []
	@State private var currentTheme: String?
	@State private var enabledExtensions: [String] = []
	@State private var cliOutput: String?
	@State private var runningCLI = false
	@State private var banner: String?
	@State private var errorText: String?
	@State private var selectedSection: String = "theme"
	@State private var token = UUID()

	struct ResourceEntry: Identifiable {
		let url: URL
		let type: String
		let scope: String
		let writable: Bool
		var id: String { url.path }
		var isDisabled: Bool { url.lastPathComponent.hasSuffix(".off") }
		var displayName: String {
			let name = url.lastPathComponent
			return isDisabled ? String(name.dropLast(4)) : name
		}
	}

	struct PackageEntry: Identifiable {
		let source: String
		let filters: [String]
		var id: String { source }
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	private var sections: [(id: String, title: String, icon: String, type: String)] {
		[
			("theme", L.t("resources.section.themes", "主题"), "paintpalette", "theme"),
			("extension", L.t("resources.section.extensions", "扩展"), "puzzlepiece", "extension"),
			("prompt", L.t("resources.section.prompts", "Prompt 模板"), "text.badge.plus", "prompt"),
			(
				"package",
				L.t("resources.section.packages", "Packages"),
				"shippingbox",
				"package"
			),
		]
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			HStack(spacing: 0) {
				sectionList
				Divider()
				content
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.task(id: token) { load() }
		.onChange(of: model.externalChangeToken) { _, _ in load() }
		.onChange(of: model.projectURL) { _, _ in load() }
		// "Reload" moved to the toolbar's ⋯ menu, which leaves the header as a
		// title, a count and the note about the `.off` convention. Enabling and
		// disabling files stays where it is: those are row actions.
		.paneActions(token: paneActionToken(agent: agent, surface: surface), title: surface.titleText) {
			[
				.command(
					id: "resources.reload",
					title: L.t("button.reload", "重新读取"),
					systemImage: "arrow.clockwise"
				) { load() }
			]
		}
	}

	// MARK: - Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.titleText).font(.title3.weight(.semibold))
				StatusBadge(
					text: String(
						format: L.t(entries.count == 1 ? "resources.badge.fileCount.one" : "resources.badge.fileCount", "%d 个资源文件"),
						entries.count
					),
					level: .info
				)
				Spacer()
			}
			Text(
				L.t(
					"resources.note.extensions",
					"扩展的启用/停用沿用 pi 的约定：文件名以 .off 结尾即不加载。这里的改动是直接重命名文件，会先征求确认。"
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

	private var sectionList: some View {
		List(selection: $selectedSection) {
			ForEach(sections, id: \.id) { section in
				HStack(spacing: 7) {
					Image(systemName: section.icon).frame(width: 16)
					Text(section.title)
					Spacer(minLength: 0)
					let count = section.id == "package" ? packages.count : entries.filter { $0.type == section.type }.count
					if count > 0 {
						Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
					}
				}
				.tag(section.id)
			}
		}
		.frame(width: 200)
		.listStyle(.sidebar)
	}

	@ViewBuilder
	private var content: some View {
		if selectedSection == "package" {
			packageList
		} else {
			resourceList
		}
	}

	private var resourceList: some View {
		let items = entries.filter { $0.type == selectedSection }
		return ScrollView {
			VStack(alignment: .leading, spacing: 6) {
				if items.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text(L.t("empty.noResources", "这个分类下没有资源文件。"))
							.font(.callout)
							.foregroundStyle(.secondary)
						Text(L.t("resources.scannedRoots", "已扫描："))
							.font(.caption)
							.foregroundStyle(.tertiary)
						ForEach(scannedRoots(for: selectedSection), id: \.path) { url in
							Text(url.path)
								.font(.system(size: 10.5, design: .monospaced))
								.foregroundStyle(.tertiary)
								.textSelection(.enabled)
						}
						if scannedRoots(for: selectedSection).isEmpty {
							Text(L.t("resources.noRoots", "描述文件里没有为这个分类声明根目录"))
								.font(.caption)
								.foregroundStyle(.tertiary)
						}
					}
					.padding(.vertical, 8)
				}
				ForEach(items) { entry in
					HStack(spacing: 9) {
						Image(systemName: entry.isDisabled ? "circle.slash" : "doc")
							.font(.caption)
							.foregroundStyle(entry.isDisabled ? Color.secondary : Color.accentColor)
							.frame(width: 16)
						VStack(alignment: .leading, spacing: 2) {
							HStack(spacing: 6) {
								Text(entry.displayName)
									.font(.callout)
									.lineLimit(1)
								if entry.isDisabled {
									StatusBadge(text: L.t("badge.disabled", "已停用"), level: .muted)
								}
								if entry.type == "theme", entry.displayName == activeThemeName {
									StatusBadge(text: L.t("resources.badge.currentTheme", "当前主题"), level: .ok)
								}
								if entry.scope == "project" {
									StatusBadge(text: L.t("badge.scopeProject", "项目"), level: .muted)
								}
							}
							Text(entry.url.path)
								.font(.system(size: 10.5, design: .monospaced))
								.foregroundStyle(.tertiary)
								.lineLimit(1)
								.truncationMode(.middle)
						}
						Spacer(minLength: 6)
						if entry.type == "extension", entry.writable {
							Button(
								entry.isDisabled
									? L.t("button.enable", "启用")
									: L.t("button.disable", "停用")
							) {
								toggleExtension(entry)
							}
							.controlSize(.small)
						}
						Button {
							ShellActions.reveal(entry.url)
						} label: {
							Image(systemName: "folder")
						}
						.buttonStyle(.borderless)
					}
					.padding(.vertical, 5)
					.padding(.horizontal, 8)
					.background(
						RoundedRectangle(cornerRadius: 8, style: .continuous)
							.fill(Color(nsColor: .controlBackgroundColor))
					)
				}
			}
			.padding(14)
			.frame(maxWidth: .infinity, alignment: .topLeading)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var packageList: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				HStack {
					Text(L.t("resources.packages.title", "settings.json 里声明的包")).font(.headline)
					Spacer()
					Button {
						runCLI(["list"])
					} label: {
						Label(L.t("button.runPiList", "运行 pi list"), systemImage: "play")
					}
					.controlSize(.small)
					.disabled(agent.cliURL == nil || runningCLI)
				}
				if packages.isEmpty {
					Text(L.t("empty.noPackages", "没有声明任何 package。"))
						.font(.callout)
						.foregroundStyle(.secondary)
				}
				ForEach(packages) { package in
					VStack(alignment: .leading, spacing: 3) {
						Text(package.source)
							.font(.system(.callout, design: .monospaced))
							.textSelection(.enabled)
						if !package.filters.isEmpty {
							Text(package.filters.joined(separator: L.t("listSeparator", "、")))
								.font(.caption2)
								.foregroundStyle(.tertiary)
						}
					}
					.padding(9)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(
						RoundedRectangle(cornerRadius: 8, style: .continuous)
							.fill(Color(nsColor: .controlBackgroundColor))
					)
				}
				if let cliOutput {
					VStack(alignment: .leading, spacing: 4) {
						Text(L.t("resources.piListOutput", "pi list 输出")).font(.caption.weight(.semibold))
						Text(cliOutput)
							.font(.system(size: 11, design: .monospaced))
							.textSelection(.enabled)
							.padding(8)
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
					}
				}
				Text(
					L.t(
						"resources.packages.note",
						"安装与卸载请用命令行：`pi install <source>` / `pi remove <source>`。AgentKit 只读取声明，不替你改 packages 数组。"
					)
				)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
			.padding(14)
			.frame(maxWidth: .infinity, alignment: .topLeading)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private func scannedRoots(for type: String) -> [URL] {
		(surface.roots ?? [])
			.filter { ($0.type ?? "extension") == type }
			.compactMap { try? resolver.expand($0.path) }
	}

	private var activeThemeName: String? {
		guard let currentTheme else { return nil }
		return currentTheme.split(separator: "/").first.map(String.init)
	}

	// MARK: - Actions

	private func toggleExtension(_ entry: ResourceEntry) {
		let destination: URL
		if entry.isDisabled {
			destination = entry.url.deletingPathExtension()
		} else {
			destination = URL(fileURLWithPath: entry.url.path + ".off")
		}
		do {
			guard !FileManager.default.fileExists(atPath: destination.path) else {
				errorText = String(
					format: L.t("error.fileExists", "%@ 已经存在"),
					destination.lastPathComponent
				)
				return
			}
			try FileManager.default.moveItem(at: entry.url, to: destination)
			banner = String(
				format: entry.isDisabled
					? L.t("banner.enabled", "已启用 %@")
					: L.t("banner.disabled", "已停用 %@"),
				entry.displayName
			)
			errorText = nil
			load()
		} catch {
			errorText = error.localizedDescription
		}
	}

	private func runCLI(_ arguments: [String]) {
		guard let cli = agent.cliURL else { return }
		runningCLI = true
		Task.detached(priority: .userInitiated) {
			let result = AgentProcess.run(
				executable: cli,
				arguments: arguments,
				environment: LoginShell.environment(),
				timeout: 120
			)
			let output = result.combinedOutput
			await MainActor.run {
				cliOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
				runningCLI = false
			}
		}
	}

	// MARK: - Load

	private func load() {
		var loaded: [ResourceEntry] = []
		for spec in surface.roots ?? [] {
			guard let url = try? resolver.expand(spec.path) else { continue }
			let items = (try? FileManager.default.contentsOfDirectory(
				at: url,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)) ?? []
			for item in items {
				let name = item.lastPathComponent
				if name.hasPrefix(".") { continue }
				loaded.append(
					ResourceEntry(
						url: item,
						type: spec.type ?? "extension",
						scope: spec.scope ?? "user",
						writable: spec.isWritable
					)
				)
			}
		}
		entries = loaded.sorted { $0.url.path < $1.url.path }

		// settings.json: current theme, enabled extension paths, packages.
		if let settingsTemplate = agent.descriptor.surfaces
			.first(where: { $0.kind == .settings })?.file,
			let url = try? resolver.expand(settingsTemplate)
		{
			let document = JSONFile.load(url, policy: policy)
			currentTheme = document.value(at: ["theme"])?.stringValue
			enabledExtensions = document.value(at: ["extensions"])?.stringsValue ?? []
			packages = (document.value(at: ["packages"])?.arrayValue ?? []).compactMap { value in
				if let string = value.stringValue { return PackageEntry(source: string, filters: []) }
				guard let object = value.objectValue, let source = object["source"]?.stringValue else { return nil }
				let filters = ["extensions", "skills", "prompts", "themes"].flatMap { key in
					(object[key]?.stringsValue ?? []).map { "\(key): \($0)" }
				}
				return PackageEntry(source: source, filters: filters)
			}
		}
		errorText = nil
	}
}
