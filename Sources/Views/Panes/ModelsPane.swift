//
//  ModelsPane.swift
//  AgentKit
//
//  models.json 里的 provider / model，settings.json 里的启动默认值，
//  以及 `pi auth check` 的认证状态。
//

import SwiftUI

struct ModelsPane: View {
	let agent: LoadedAgent
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model
	@State private var snapshot: ModelsSnapshot?
	@State private var selectedProviderID: String?
	@State private var providerDraft: ProviderDraft?
	@State private var settingsController = JSONEditController()
	@State private var authResults: [String: String] = [:]
	@State private var defaultsDraft: DefaultsDraft?
	@State private var checkingAuth = false
	@State private var banner: String?
	@State private var errorText: String?
	@State private var token = UUID()

	private struct DefaultsDraft: Identifiable {
		let id = UUID()
		var provider: String
		var model: String
		var thinking: String
	}

	private struct ProviderDraft: Identifiable {
		let id = UUID()
		let originalID: String?
		var identifier: String
		var name: String
		var baseUrl: String
		var api: String
		var apiKey: String
		var modelsText: String

		var isNew: Bool { originalID == nil }
	}

	private var resolver: PathResolver { model.resolver(for: agent) }
	private var policy: BackupPolicy { agent.descriptor.backupPolicy }

	/// pi stores providers under `providers`, Codex under `model_providers`.
	private var currentProvidersKey: String {
		snapshot?.providersKey ?? surface.providersKey ?? "providers"
	}

	/// pi spells the fields `baseUrl` / `api` / `apiKey`, Codex `base_url` /
	/// `wire_api` / `env_key`.
	private var providerKeys: ModelProviderKeys {
		snapshot?.keys ?? surface.providerKeys ?? .pi
	}

	private var providerURL: URL? {
		guard let template = surface.providerFile else { return nil }
		return try? resolver.expand(template)
	}

	private var settingsURL: URL? {
		guard let ref = surface.defaults?["provider"] else { return nil }
		return try? resolver.expand(ref.file)
	}

	private var selectedProvider: ProviderEntry? {
		guard let snapshot else { return nil }
		guard let selectedProviderID else { return snapshot.providers.first }
		return snapshot.providers.first { $0.id == selectedProviderID } ?? snapshot.providers.first
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			HStack(spacing: 0) {
				providerList
				Divider()
				providerDetail
			}
			// An HStack sizes to its children: without an explicit greedy frame a
			// narrow empty state collapses the whole row and pushes the list inwards.
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.task(id: token) { load() }
		.onChange(of: model.externalChangeToken) { _, _ in load() }
		.sheet(item: $providerDraft) { draft in providerSheet(draft) }
		.sheet(item: $defaultsDraft) { draft in defaultsSheet(draft) }
		.sheet(item: $settingsController.pending) { pending in
			DiffSheet(
				preview: pending.preview,
				backup: pending.preview.backupURL,
				onCancel: { settingsController.cancel() },
				onConfirm: {
					settingsController.confirm()
					banner = settingsController.banner
					load()
				}
			)
		}
	}

	// MARK: - Header

	private var header: some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 8) {
				Text(surface.title).font(.title3.weight(.semibold))
				if let snapshot {
					StatusBadge(text: "\(snapshot.providers.count) 个 provider", level: .info)
					StatusBadge(
						text: "\(snapshot.providers.reduce(0) { $0 + $1.models.count }) 个自定义 model",
						level: .muted
					)
				}
				Spacer()
				Button {
					checkAuth()
				} label: {
					Label("检查认证", systemImage: "key.horizontal")
				}
				.controlSize(.small)
				.disabled(agent.cliURL == nil || checkingAuth || snapshot?.providers.isEmpty != false)
				if checkingAuth { ProgressView().controlSize(.mini) }
				Menu {
					Button("新增 provider…") { beginNewProvider() }
				} label: {
					Label("新增", systemImage: "plus")
				}
				.controlSize(.small)
			}
			if let snapshot, let provider = snapshot.defaults.provider {
				HStack(spacing: 6) {
					Text("启动默认：").font(.caption).foregroundStyle(.secondary)
					Text("\(provider)/\(snapshot.defaults.model ?? "—")")
						.font(.system(.caption, design: .monospaced))
					if let thinking = snapshot.defaults.thinking {
						StatusBadge(text: "thinking: \(thinking)", level: .muted)
					}
					Button("改…") { editDefaults() }
						.controlSize(.mini)
				}
			} else {
				Text("settings.json 里没有设置启动默认模型；pi 会自己选一个。")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			if let banner { InfoBanner(kind: .info, title: banner) }
			if let errorText { InfoBanner(kind: .error, title: errorText) }
			if let reason = snapshot?.malformedReason {
				InfoBanner(kind: .error, title: "models.json 无法解析，编辑已停用", detail: reason)
			}
		}
		.padding(14)
	}

	// MARK: - List

	private var providerList: some View {
		List(selection: $selectedProviderID) {
			ForEach(snapshot?.providers ?? []) { provider in
				VStack(alignment: .leading, spacing: 3) {
					HStack(spacing: 6) {
						Text(provider.name ?? provider.id)
							.font(.callout.weight(.medium))
							.lineLimit(1)
						if provider.hasKey {
							Image(systemName: "key.fill")
								.font(.system(size: 9))
								.foregroundStyle(provider.keyIsEnvReference ? Color.orange : Color.green)
								.help(provider.keyIsEnvReference ? "apiKey 是环境变量/命令引用" : "已配置 apiKey")
						} else {
							Image(systemName: "key.slash")
								.font(.system(size: 9))
								.foregroundStyle(.tertiary)
								.help("没有 apiKey，pi 会依赖 auth.json 或环境变量")
						}
						Spacer(minLength: 0)
						if let status = authResults[provider.id] {
							StatusBadge(text: status, level: status == "ready" ? .ok : .warning)
						}
					}
					Text(provider.id)
						.font(.system(.caption2, design: .monospaced))
						.foregroundStyle(.tertiary)
					Text(provider.baseUrl ?? "—")
						.font(.system(size: 10, design: .monospaced))
						.foregroundStyle(.tertiary)
						.lineLimit(1)
						.truncationMode(.middle)
					Text("\(provider.models.count) 个 model")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				.tag(provider.id as String?)
			}
		}
		.frame(width: 260)
		.listStyle(.sidebar)
	}

	// MARK: - Detail

	private var apiSuggestions: [String] {
		// `wire_api` is a different vocabulary from pi's `api`.
		(providerKeys.api ?? "api") == "wire_api"
			? ["responses", "chat"]
			: ModelsSurfaceLoader.knownAPIs
	}

	private var apiPlaceholder: String { apiSuggestions.first ?? "" }

	@ViewBuilder
	private var providerDetail: some View {
		if let provider = selectedProvider {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					VStack(alignment: .leading, spacing: 6) {
						HStack(spacing: 8) {
							Text(provider.name ?? provider.id).font(.title3.weight(.semibold))
							StatusBadge(text: provider.api ?? "api 未设置", level: .muted)
							if !provider.hasKey {
								StatusBadge(text: "无 apiKey", level: .warning)
							}
						}
						Text(provider.baseUrl ?? "—")
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
					}

					Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
						row("provider id", provider.id, monospaced: true)
						row("api", provider.api ?? "—", monospaced: true)
						row(
							"apiKey",
							provider.hasKey
								? (provider.keyIsEnvReference ? "环境变量 / 命令引用（未展开）" : "已配置（已隐藏，AgentKit 不读取明文）")
								: "未配置"
						)
						if !provider.compatKeys.isEmpty {
							row("compat", provider.compatKeys.joined(separator: "、"), monospaced: true)
						}
						if let status = authResults[provider.id] {
							row("pi auth check", status)
						}
					}

					if !provider.unknownKeys.isEmpty {
						InfoBanner(
							kind: .info,
							title: "这个 provider 还有 AgentKit 不认识的键，编辑时会原样保留",
							detail: provider.unknownKeys.joined(separator: "、")
						)
					}

					HStack(spacing: 8) {
						Button("编辑 provider…") { beginEdit(provider) }
						Button("在 Finder 中显示") {
							if let providerURL { ShellActions.reveal(providerURL) }
						}
						Button(role: .destructive) { deleteProvider(provider) } label: {
							Text("删除 provider…")
						}
						Spacer()
					}

					Divider()

					if providerKeys.models != nil {
						HStack {
							Text("Models").font(.headline)
							Spacer()
							Button {
								addModel(provider)
							} label: {
								Label("新增 model", systemImage: "plus")
							}
							.controlSize(.small)
						}

						if provider.models.isEmpty {
							Text("这个 provider 没有自定义 model 条目。")
								.font(.callout)
								.foregroundStyle(.secondary)
						}
					} else {
						InfoBanner(
							kind: .info,
							title: "这个 agent 的 provider 不声明模型列表",
							detail: "模型 id 由 \(providerKeys.api == nil ? "api" : "接口") 侧决定，这里只配置连接方式。"
						)
					}

					ForEach(provider.models) { entry in
						let catalog = snapshot?.catalog["\(provider.id)/\(entry.id)"]
						VStack(alignment: .leading, spacing: 4) {
							HStack(spacing: 7) {
								Text(entry.id)
									.font(.system(.callout, design: .monospaced))
								if entry.reasoning == true { StatusBadge(text: "推理", level: .info) }
								if entry.supportsImages { StatusBadge(text: "图片", level: .muted) }
								Spacer()
								Button(role: .destructive) { deleteModel(provider, entry) } label: {
									Image(systemName: "minus.circle")
								}
								.buttonStyle(.borderless)
								.help("删除这个 model 条目")
							}
							HStack(spacing: 12) {
								if let context = entry.contextWindow ?? catalog?.contextWindow {
									Text("上下文 \(formatCount(context))").font(.caption2).foregroundStyle(.tertiary)
								}
								if let max = entry.maxTokens ?? catalog?.maxTokens {
									Text("最大输出 \(formatCount(max))").font(.caption2).foregroundStyle(.tertiary)
								}
								if entry.name != nil, entry.name != entry.id {
									Text(entry.name ?? "").font(.caption2).foregroundStyle(.tertiary)
								}
							}
						}
						.padding(9)
						.frame(maxWidth: .infinity, alignment: .leading)
						.background(
							RoundedRectangle(cornerRadius: 8, style: .continuous)
								.fill(Color(nsColor: .controlBackgroundColor))
						)
					}
				}
				.padding(16)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		} else {
			EmptyStateView(
				icon: "cpu",
				title: "models.json 里还没有 provider",
				message: providerURL?.path,
				action: ("新增 provider…", { beginNewProvider() })
			)
		}
	}

	private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
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

	private func formatCount(_ value: Int) -> String {
		value >= 1000 ? String(format: "%.0fK", Double(value) / 1000) : "\(value)"
	}

	// MARK: - Provider editing

	private func beginNewProvider() {
		providerDraft = ProviderDraft(
			originalID: nil,
			identifier: "",
			name: "",
			baseUrl: "",
			api: "openai-completions",
			apiKey: "",
			modelsText: "[]"
		)
	}

	private func beginEdit(_ provider: ProviderEntry) {
		let models = provider.models.map { JSONWriter.pretty.serialize($0.raw) }
		providerDraft = ProviderDraft(
			originalID: provider.id,
			identifier: provider.id,
			name: provider.name ?? "",
			baseUrl: provider.baseUrl ?? "",
			api: provider.api ?? "openai-completions",
			apiKey: "",
			modelsText: "[\n" + models.joined(separator: ",\n") + "\n]"
		)
	}

	private func providerSheet(_ draft: ProviderDraft) -> some View {
		let prepared = preparedProviderEdit(draft)
		return VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 10) {
				Text(draft.isNew ? "新增 provider" : "编辑 \(draft.originalID ?? "")").font(.headline)
				Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
					GridRow {
						Text("id").gridColumnAlignment(.trailing)
						TextField("例如 example", text: binding(\.identifier, draft))
							.textFieldStyle(.roundedBorder)
							.font(.system(.body, design: .monospaced))
							.disabled(!draft.isNew)
					}
					GridRow {
						Text(providerKeys.name ?? "name").gridColumnAlignment(.trailing)
						TextField("显示名", text: binding(\.name, draft))
							.textFieldStyle(.roundedBorder)
					}
					GridRow {
						Text(providerKeys.baseUrl ?? "baseUrl").gridColumnAlignment(.trailing)
						TextField("https://…/v1", text: binding(\.baseUrl, draft))
							.textFieldStyle(.roundedBorder)
							.font(.system(.body, design: .monospaced))
					}
					GridRow {
						Text(providerKeys.api ?? "api").gridColumnAlignment(.trailing)
						HStack(spacing: 6) {
							TextField(apiPlaceholder, text: binding(\.api, draft))
								.textFieldStyle(.roundedBorder)
								.font(.system(.body, design: .monospaced))
							Menu {
								ForEach(apiSuggestions, id: \.self) { value in
									Button(value) { self.providerDraft?.api = value }
								}
							} label: {
								Image(systemName: "chevron.down")
							}
							.menuStyle(.borderlessButton)
							.fixedSize()
						}
					}
					GridRow {
						Text(providerKeys.apiKey ?? "apiKey").gridColumnAlignment(.trailing)
						SecureField(
							draft.isNew ? "可留空，改用 auth.json 或环境变量" : "留空表示不改动现有值",
							text: binding(\.apiKey, draft)
						)
						.textFieldStyle(.roundedBorder)
					}
				}
				VStack(alignment: .leading, spacing: 4) {
					Text("models（JSON 数组）").font(.caption.weight(.medium))
					TextEditor(text: binding(\.modelsText, draft))
						.font(.system(size: 11, design: .monospaced))
						.frame(height: 150)
						.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
				}
				if let prepared, let problem = prepared.problem {
					InfoBanner(kind: .warning, title: problem)
				}
				if let prepared, prepared.preview.hasChanges {
					VStack(alignment: .leading, spacing: 4) {
						Text("写入 \(prepared.url.path) 的改动").font(.caption.weight(.medium))
						DiffPreviewList(diff: prepared.preview.diff)
					}
				}
			}
			.padding(14)
			Divider()
			HStack {
				if draft.isNew {
					Text("新增的 provider 会追加到 models.json 的 providers 下。")
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
				Spacer()
				Button("取消") { providerDraft = nil }
				Button(draft.isNew ? "新增" : "写入") { applyProvider(draft) }
					.buttonStyle(.borderedProminent)
					.disabled(prepared?.problem != nil || prepared?.preview.hasChanges != true)
			}
			.padding(14)
		}
		.frame(minWidth: 720)
	}

	private func binding(_ key: WritableKeyPath<ProviderDraft, String>, _ draft: ProviderDraft) -> Binding<String> {
		Binding(
			get: { providerDraft?[keyPath: key] ?? draft[keyPath: key] },
			set: { providerDraft?[keyPath: key] = $0 }
		)
	}

	private func preparedProviderEdit(
		_ draft: ProviderDraft
	) -> (url: URL, preview: FilePreview, problem: String?)? {
		guard let providerURL else { return nil }
		let document = JSONFile.load(providerURL, policy: policy)
		guard let problem = providerProblem(draft, existing: document) else {
			var value = document.editableValue
			value.setValue(
				buildProvider(draft, existing: document),
				at: [currentProvidersKey, draft.identifier]
			)
			return (providerURL, JSONFile.preview(value, for: document, policy: policy), nil)
		}
		return (providerURL, JSONFile.preview(document.editableValue, for: document, policy: policy), problem)
	}

	private func providerProblem(_ draft: ProviderDraft, existing: JSONDocument) -> String? {
		if draft.identifier.trimmingCharacters(in: .whitespaces).isEmpty { return "id 不能为空" }
		if draft.baseUrl.trimmingCharacters(in: .whitespaces).isEmpty { return "baseUrl 不能为空" }
		if draft.isNew, existing.value(at: [currentProvidersKey, draft.identifier]) != nil {
			return "providers 下已经有 \(draft.identifier) 了"
		}
		guard let parsed = try? JSONParser.parse(draft.modelsText), parsed.arrayValue != nil else {
			return "models 必须是一个 JSON 数组"
		}
		return nil
	}

	/// Merges the form into the provider's existing object, so keys AgentKit does
	/// not understand (`compat`, `headers`, …) survive an edit.
	private func buildProvider(_ draft: ProviderDraft, existing: JSONDocument) -> JSONValue {
		var object = existing.value(at: [currentProvidersKey, draft.identifier])?.objectValue ?? JSONObject()
		let keys = providerKeys
		let nameKey = keys.name ?? "name"
		let name = draft.name.trimmingCharacters(in: .whitespaces)
		if name.isEmpty {
			_ = object.removeValue(forKey: nameKey)
		} else {
			object[nameKey] = .string(name)
		}
		if let baseUrlKey = keys.baseUrl {
			object[baseUrlKey] = .string(draft.baseUrl.trimmingCharacters(in: .whitespaces))
		}
		if let apiKey = keys.api, !draft.api.isEmpty {
			object[apiKey] = .string(draft.api.trimmingCharacters(in: .whitespaces))
		}
		if let credentialKey = keys.apiKey {
			let key = draft.apiKey.trimmingCharacters(in: .whitespaces)
			if !key.isEmpty {
				object[credentialKey] = .string(key)
			} else if draft.isNew {
				// New providers get an empty key so the shape is obvious.
				object[credentialKey] = .string("")
			}
		}
		if let modelsKey = keys.models, let models = try? JSONParser.parse(draft.modelsText) {
			object[modelsKey] = models
		}
		return .object(object)
	}

	private func applyProvider(_ draft: ProviderDraft) {
		guard let providerURL else { return }
		let document = JSONFile.load(providerURL, policy: policy)
		var value = document.editableValue
		if let original = draft.originalID, original != draft.identifier {
			value.removeValue(at: [currentProvidersKey, original])
		}
		value.setValue(buildProvider(draft, existing: document), at: [currentProvidersKey, draft.identifier])
		do {
			let result = try JSONFile.write(value, document: document, scope: resolver, policy: policy)
			banner = result.backupURL.map { "已写入，备份 \($0.lastPathComponent)" } ?? "已写入"
			errorText = nil
			providerDraft = nil
			selectedProviderID = draft.identifier
			load()
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
			providerDraft = nil
		}
	}

	private func deleteProvider(_ provider: ProviderEntry) {
		guard let providerURL else { return }
		let document = JSONFile.load(providerURL, policy: policy)
		var value = document.editableValue
		value.removeValue(at: [currentProvidersKey, provider.id])
		do {
			let result = try JSONFile.write(value, document: document, scope: resolver, policy: policy)
			banner = "已删除 provider \(provider.id)"
				+ (result.backupURL.map { "，备份 \($0.lastPathComponent)" } ?? "")
			errorText = nil
			load()
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	private func addModel(_ provider: ProviderEntry) {
		guard let providerURL else { return }
		let document = JSONFile.load(providerURL, policy: policy)
		var models = document.value(at: [currentProvidersKey, provider.id, "models"])?.arrayValue ?? []
		models.append(ModelsSurfaceLoader.emptyModel())
		var value = document.editableValue
		value.setValue(.array(models), at: [currentProvidersKey, provider.id, "models"])
		do {
			let result = try JSONFile.write(value, document: document, scope: resolver, policy: policy)
			banner = "已在 \(provider.id) 下新增一个 model 条目，请编辑它的 id"
				+ (result.backupURL.map { "（备份 \($0.lastPathComponent)）" } ?? "")
			errorText = nil
			load()
			if let refreshed = snapshot?.providers.first(where: { $0.id == provider.id }) {
				beginEdit(refreshed)
			}
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	private func deleteModel(_ provider: ProviderEntry, _ entry: ModelEntry) {
		guard let providerURL else { return }
		let document = JSONFile.load(providerURL, policy: policy)
		var models = document.value(at: [currentProvidersKey, provider.id, "models"])?.arrayValue ?? []
		models.removeAll { $0.value(at: ["id"])?.stringValue == entry.id }
		var value = document.editableValue
		value.setValue(.array(models), at: [currentProvidersKey, provider.id, "models"])
		do {
			_ = try JSONFile.write(value, document: document, scope: resolver, policy: policy)
			banner = "已删除 \(provider.id)/\(entry.id)"
			errorText = nil
			load()
		} catch {
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}

	// MARK: - Defaults

	private func editDefaults() {
		guard let snapshot else { return }
		defaultsDraft = DefaultsDraft(
			provider: snapshot.defaults.provider ?? snapshot.providers.first?.id ?? "",
			model: snapshot.defaults.model ?? "",
			thinking: snapshot.defaults.thinking ?? "medium"
		)
	}

	private func defaultsSheet(_ draft: DefaultsDraft) -> some View {
		let models = snapshot?.providers.first { $0.id == draft.provider }?.models ?? []
		return VStack(alignment: .leading, spacing: 12) {
			Text("启动默认模型").font(.headline)
			Text("写入 settings.json 的 defaultProvider / defaultModel / defaultThinkingLevel。")
				.font(.caption)
				.foregroundStyle(.secondary)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
				GridRow {
					Text("provider").gridColumnAlignment(.trailing)
					Picker("", selection: Binding(
						get: { defaultsDraft?.provider ?? "" },
						set: { newValue in
							defaultsDraft?.provider = newValue
							defaultsDraft?.model = snapshot?.providers.first { $0.id == newValue }?.models.first?.id ?? ""
						}
					)) {
						ForEach(snapshot?.providers ?? []) { provider in
							Text(provider.id).tag(provider.id)
						}
					}
					.labelsHidden()
				}
				GridRow {
					Text("model").gridColumnAlignment(.trailing)
					Picker("", selection: Binding(
						get: { defaultsDraft?.model ?? "" },
						set: { defaultsDraft?.model = $0 }
					)) {
						ForEach(models) { entry in
							Text(entry.id).tag(entry.id)
						}
					}
					.labelsHidden()
				}
				GridRow {
					Text("thinking").gridColumnAlignment(.trailing)
					Picker("", selection: Binding(
						get: { defaultsDraft?.thinking ?? "medium" },
						set: { defaultsDraft?.thinking = $0 }
					)) {
						ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
							Text(level).tag(level)
						}
					}
					.labelsHidden()
				}
			}
			if models.isEmpty {
				InfoBanner(
					kind: .info,
					title: "这个 provider 在 models.json 里没有自定义 model",
					detail: "pi 会用内置目录里的模型；这里只能设置 provider 级别的默认值。"
				)
			}
			HStack {
				Spacer()
				Button("取消") { defaultsDraft = nil }
				Button("保存…") { applyDefaults(draft) }
					.buttonStyle(.borderedProminent)
					.disabled(draft.provider.isEmpty)
			}
		}
		.padding(16)
		.frame(minWidth: 520)
	}

	private func applyDefaults(_ draft: DefaultsDraft) {
		guard let settingsURL else { return }
		defaultsDraft = nil
		settingsController.load(url: settingsURL, resolver: resolver, policy: policy)
		var value = settingsController.editable
		value.setValue(.string(draft.provider), at: ["defaultProvider"])
		if !draft.model.isEmpty {
			value.setValue(.string(draft.model), at: ["defaultModel"])
		}
		value.setValue(.string(draft.thinking), at: ["defaultThinkingLevel"])
		settingsController.stage(value)
	}

	// MARK: - Auth

	private func checkAuth() {
		guard let cli = agent.cliURL, let snapshot else { return }
		checkingAuth = true
		let arguments = surface.cli?["authCheck"] ?? ["auth", "check"]
		let providers = snapshot.providers.map(\.id)
		Task.detached(priority: .utility) {
			var results: [String: String] = [:]
			for provider in providers {
				let result = AgentProcess.run(
					executable: cli,
					arguments: arguments + ["--provider", provider, "--json", "--no-refresh"],
					environment: LoginShell.environment(),
					timeout: 30
				)
				results[provider] = ModelsPane.status(from: result)
			}
			let final = results
			await MainActor.run {
				authResults = final
				checkingAuth = false
			}
		}
	}

	/// `pi auth check --json` prints `{"status":"ready","provider":"…","authType":"…"}`.
	nonisolated static func status(from result: ProcessResult) -> String {
		let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		if let data = text.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let status = object["status"] as? String
		{
			if let type = object["authType"] as? String { return "\(status) · \(type)" }
			return status
		}
		if text.isEmpty { return result.succeeded ? "ok" : "无法检查" }
		return text.split(separator: "\n").first.map(String.init) ?? "无法检查"
	}

	// MARK: - Load

	private func load() {
		let loaded = ModelsSurfaceLoader.snapshot(surface: surface, resolver: resolver, policy: policy)
		snapshot = loaded
		if selectedProviderID == nil || !loaded.providers.contains(where: { $0.id == selectedProviderID }) {
			selectedProviderID = loaded.providers.first?.id
		}
	}
}
