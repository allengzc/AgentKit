//
//  SettingsSchema.swift
//  AgentKit
//
//  The typed settings catalog for pi 0.87.
//
//  This is the "agent-specific knowledge" half of the design: a descriptor
//  says *which* file holds the settings and *which* schema to use, and the
//  schema — compiled in, versioned, reviewable — says what each key means.
//  Every key below is taken from the settings reference shipped with
//  `@earendil-works/pi-coding-agent` 0.87.1 (`docs/settings.md`).
//
//  Every label and every help sentence is a `zh`/`en` pair: the pane is read in
//  both languages, and a plain string here would show Chinese in English mode
//  without anything complaining. `Tests/main.swift` asserts none of the shipped
//  schemas is plain.
//

import Foundation

public enum SettingFieldType: Equatable {
	case bool
	case integer(min: Int?, max: Int?)
	case text
	case path
	case choice([String])
	case textList
	/// `true`, `false`, or the literal string `"auto"`.
	case boolOrAuto
	/// `false`, or one of the listed protocol names.
	case choiceOrFalse([String])
	/// A free-form object, edited as JSON.
	case json
	/// An array whose items may be strings or objects (pi's `packages`).
	case mixedList

	public var choices: [String] {
		switch self {
		case .choice(let values): return values
		case .boolOrAuto: return ["auto", "true", "false"]
		case .choiceOrFalse(let values): return ["false"] + values
		default: return []
		}
	}

	public var placeholder: String {
		switch self {
		case .bool, .boolOrAuto: return "true / false / auto"
		case .integer(let min, let max):
			switch (min, max) {
			case let (min?, max?): return "\(min) – \(max)"
			case let (min?, nil): return "≥ \(min)"
			case let (nil, max?): return "≤ \(max)"
			default: return "整数"
			}
		case .text: return "文本"
		case .path: return "路径"
		case .choice(let values): return values.joined(separator: " / ")
		case .textList: return "逗号分隔或 JSON 数组"
		case .choiceOrFalse(let values): return "false / " + values.joined(separator: " / ")
		case .json: return "JSON 对象"
		case .mixedList: return "JSON 数组"
		}
	}
}

public struct SettingField: Identifiable {
	public let key: String
	/// Per-language. A plain string (every language the same) is what a schema
	/// that has not been translated yet contains.
	public let label: LocalizedText
	public let type: SettingFieldType
	public let help: LocalizedText
	/// The value a field takes when the file does not set it. Data, not prose —
	/// it goes into the JSON as written, so it is never translated.
	public let fallback: String
	public let scopeNote: LocalizedText?

	public var id: String { key }
	public var path: [String] { key.split(separator: ".").map(String.init) }

	/// Resolved for the language in effect right now.
	public var labelText: String { label.current }
	public var helpText: String { help.current }
	public var scopeNoteText: String? { scopeNote?.current }
}

public struct SettingsSection: Identifiable {
	public let id: String
	public let title: LocalizedText
	public let icon: String
	public let fields: [SettingField]

	public var titleText: String { title.current }
}

public struct SettingsSchemaDefinition: Identifiable {
	public let id: String
	public let title: LocalizedText
	public let sections: [SettingsSection]

	public var titleText: String { title.current }

	public var fields: [SettingField] { sections.flatMap(\.fields) }

	public func field(key: String) -> SettingField? {
		fields.first { $0.key == key }
	}

	public var knownKeys: Set<String> { Set(fields.map(\.key)) }
}

// MARK: - Builder helpers

func boolField(
	_ key: String, _ label: LocalizedText, fallback: Bool, _ help: LocalizedText, scope: LocalizedText? = nil
) -> SettingField {
	SettingField(
		key: key, label: label, type: .bool, help: help,
		fallback: fallback ? "true" : "false", scopeNote: scope
	)
}

func intField(
	_ key: String, _ label: LocalizedText, fallback: Int?, min: Int? = nil, max: Int? = nil,
	_ help: LocalizedText, scope: LocalizedText? = nil
) -> SettingField {
	SettingField(
		key: key, label: label, type: .integer(min: min, max: max), help: help,
		fallback: fallback.map(String.init) ?? "", scopeNote: scope
	)
}

func textField(
	_ key: String, _ label: LocalizedText, _ fallback: String = "", _ help: LocalizedText,
	type: SettingFieldType = .text, scope: LocalizedText? = nil
) -> SettingField {
	SettingField(key: key, label: label, type: type, help: help, fallback: fallback, scopeNote: scope)
}

func choiceField(
	_ key: String, _ label: LocalizedText, options: [String], fallback: String, _ help: LocalizedText,
	scope: LocalizedText? = nil
) -> SettingField {
	SettingField(
		key: key, label: label, type: .choice(options), help: help,
		fallback: fallback, scopeNote: scope
	)
}

func listField(
	_ key: String, _ label: LocalizedText, _ help: LocalizedText, type: SettingFieldType = .textList,
	fallback: String = "[]"
) -> SettingField {
	SettingField(key: key, label: label, type: type, help: help, fallback: fallback, scopeNote: nil)
}

func jsonField(
	_ key: String, _ label: LocalizedText, _ help: LocalizedText, fallback: String = "{}"
) -> SettingField {
	SettingField(key: key, label: label, type: .json, help: help, fallback: fallback, scopeNote: nil)
}

// MARK: - pi 0.87 settings

public enum SettingsSchema {
	public static let pi087 = SettingsSchemaDefinition(
		id: "pi-settings-0.87",
		title: .both(zh: "pi 0.87 设置", en: "pi 0.87 settings"),
		sections: [
			SettingsSection(
				id: "model",
				title: .both(zh: "模型与思考", en: "Model & thinking"),
				icon: "cpu",
				fields: [
					textField(
						"defaultProvider", .both(zh: "默认 Provider", en: "Default provider"), "",
						.both(zh: "启动时使用的 provider。留空表示自动选择。", en: "Provider used at startup. Empty means it is chosen automatically.")
					),
					textField(
						"defaultModel", .both(zh: "默认模型", en: "Default model"), "",
						.both(zh: "启动时使用的模型 id。留空表示自动选择。", en: "Model id used at startup. Empty means it is chosen automatically.")
					),
					choiceField(
						"defaultThinkingLevel", .both(zh: "默认思考等级", en: "Default thinking level"),
						options: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
						fallback: "medium",
						.both(zh: "启动时的思考等级。模型不支持的等级会被忽略。", en: "Thinking level at startup. Levels the model does not support are ignored.")
					),
					jsonField(
						"modelThinkingLevels", .both(zh: "逐模型思考等级", en: "Thinking level per model"),
						.both(zh: "以 `provider/modelId` 为键指定每个模型启动时的思考等级。", en: "Thinking level at startup for each model, keyed by `provider/modelId`.")
					),
					jsonField(
						"thinkingBudgets", .both(zh: "思考预算", en: "Thinking budgets"),
						.both(zh: "为 minimal / low / medium / high 覆盖内置的 token 预算。", en: "Overrides the built-in token budgets for minimal / low / medium / high.")
					),
					listField(
						"enabledModels", .both(zh: "可循环的模型", en: "Cyclable models"),
						.both(zh: "启动选择与 Ctrl+P 循环使用的模型匹配式，支持 `provider/*`、`*sonnet*` 等通配。", en: "Model patterns for the startup picker and Ctrl+P cycling; supports wildcards such as `provider/*` and `*sonnet*`.")
					),
					boolField(
						"hideThinkingBlock", .both(zh: "隐藏思考块", en: "Hide thinking block"), fallback: false,
						.both(zh: "在对话记录里隐藏思考内容。", en: "Hides thinking output in the transcript.")
					),
					boolField(
						"showCacheMissNotices", .both(zh: "显示缓存提示", en: "Show cache notices"), fallback: false,
						.both(zh: "显示明显的缓存未命中、成功预热、压缩用量与 provider 恢复提示。", en: "Shows prominent notices for cache misses, successful warming, compaction usage and provider recovery.")
					),
					choiceField(
						"cacheWarming", .both(zh: "缓存预热", en: "Cache warming"),
						options: ["off", "streaming", "idle"],
						fallback: "streaming",
						.both(zh: "在运行期间（streaming）或两次运行之间（idle）保持可用的 provider 提示缓存。", en: "Keeps the provider's prompt cache warm during a run (streaming) or between runs (idle)."),
						scope: .both(zh: "只能写在 agent 目录级别的 settings.json", en: "Only in the agent-directory-level settings.json")
					),
				]
			),
			SettingsSection(
				id: "interaction",
				title: .both(zh: "交互", en: "Interaction"),
				icon: "hand.tap",
				fields: [
					choiceField(
						"steeringMode", .both(zh: "引导消息投递", en: "Steering message delivery"),
						options: ["all", "one-at-a-time"], fallback: "one-at-a-time",
						.both(zh: "排队中的引导消息如何投递。", en: "How queued steering messages are delivered.")
					),
					choiceField(
						"followUpMode", .both(zh: "追问投递", en: "Follow-up delivery"),
						options: ["all", "one-at-a-time"], fallback: "one-at-a-time",
						.both(zh: "排队中的追问消息如何投递。", en: "How queued follow-up messages are delivered.")
					),
					textField(
						"externalEditor", .both(zh: "外部编辑器", en: "External editor"), "",
						.both(zh: "外部编辑器快捷键调用的命令。默认为 $VISUAL、$EDITOR 或平台默认值。", en: "Command the external-editor shortcut runs. Defaults to $VISUAL, $EDITOR, or the platform default.")
					),
					choiceField(
						"doubleEscapeAction", .both(zh: "双击 Esc", en: "Double Escape"),
						options: ["tree", "fork", "none"], fallback: "tree",
						.both(zh: "编辑器为空时连按两次 Esc 的动作。", en: "What pressing Escape twice does when the editor is empty.")
					),
					choiceField(
						"treeFilterMode", .both(zh: "/tree 初始过滤", en: "/tree initial filter"),
						options: ["default", "no-tools", "user-only", "labeled-only", "all"],
						fallback: "default",
						.both(zh: "/tree 打开时使用的初始过滤器。", en: "Initial filter used when /tree opens.")
					),
					choiceField(
						"defaultProjectTrust", .both(zh: "默认项目信任", en: "Default project trust"),
						options: ["ask", "always", "never"], fallback: "ask",
						.both(zh: "项目信任的兜底行为。", en: "Fallback behaviour for project trust."),
						scope: .both(zh: "只能写在 agent 目录级别的 settings.json", en: "Only in the agent-directory-level settings.json")
					),
				]
			),
			SettingsSection(
				id: "tools",
				title: .both(zh: "工具", en: "Tools"),
				icon: "wrench.and.screwdriver",
				fields: [
					listField(
						"defaultTools", .both(zh: "默认启用的工具", en: "Built-in tools enabled by default"),
						.both(zh: "启动时启用的内置工具。可选 read、bash、powershell、edit、write、grep、find、ls。空数组会关闭全部内置工具。", en: "Built-in tools enabled at startup. One of read, bash, powershell, edit, write, grep, find, ls. An empty array turns every built-in tool off.")
					),
				]
			),
			SettingsSection(
				id: "sessions",
				title: .both(zh: "会话与上下文", en: "Sessions & context"),
				icon: "clock.arrow.circlepath",
				fields: [
					textField(
						"sessionDir", .both(zh: "会话目录", en: "Session directory"), "",
						.both(zh: "会话存储目录。相对路径从工作目录解析。", en: "Directory sessions are stored in. Relative paths resolve from the working directory."),
						type: .path
					),
					boolField(
						"compaction.enabled", .both(zh: "自动压缩", en: "Automatic compaction"), fallback: true,
						.both(zh: "启用自动上下文压缩。", en: "Enables automatic context compaction.")
					),
					intField(
						"compaction.reserveTokens", .both(zh: "压缩预留 token", en: "Compaction reserve tokens"), fallback: 16384, min: 0,
						.both(zh: "为模型回复预留的 token。", en: "Tokens reserved for the model's reply.")
					),
					intField(
						"compaction.keepRecentTokens", .both(zh: "保留最近 token", en: "Keep recent tokens"), fallback: 20000, min: 0,
						.both(zh: "不参与摘要、原样保留的近期 token 数。", en: "Recent tokens kept verbatim instead of being summarised.")
					),
					jsonField(
						"compaction.modelOverrides", .both(zh: "逐模型压缩设置", en: "Compaction settings per model"),
						.both(zh: "以 `provider/modelId` 为键覆盖上面的压缩 token 设置。", en: "Overrides the compaction token settings above, keyed by `provider/modelId`.")
					),
					intField(
						"branchSummary.reserveTokens", .both(zh: "分支摘要预留 token", en: "Branch summary reserve tokens"), fallback: 16384, min: 0,
						.both(zh: "生成分支摘要时预留的 token。", en: "Tokens reserved when generating a branch summary.")
					),
					boolField(
						"branchSummary.skipPrompt", .both(zh: "跳过分支摘要提示", en: "Skip branch summary prompt"), fallback: false,
						.both(zh: "跳过分支摘要询问，直接按“不生成摘要”处理。", en: "Skips the branch-summary question and behaves as if “no summary” was chosen.")
					),
				]
			),
			SettingsSection(
				id: "display",
				title: .both(zh: "终端与显示", en: "Terminal & display"),
				icon: "textformat",
				fields: [
					textField(
						"theme", .both(zh: "主题", en: "Theme"), "",
						.both(zh: "内置或自定义主题名，支持 `浅色/深色` 双主题写法。", en: "Built-in or custom theme name; supports the `light/dark` dual-theme form.")
					),
					boolField(
						"quietStartup", .both(zh: "静默启动", en: "Quiet startup"), fallback: false,
						.both(zh: "隐藏启动头部。", en: "Hides the startup header.")
					),
					choiceField(
						"tuiMode", .both(zh: "TUI 模式", en: "TUI mode"),
						options: ["regular", "fullscreen"], fallback: "regular",
						.both(zh: "交互式终端界面的模式。", en: "Mode of the interactive terminal interface.")
					),
					choiceField(
						"fullscreenExitOutput", .both(zh: "全屏退出输出", en: "Fullscreen exit output"),
						options: ["transcript", "resume-hint"], fallback: "transcript",
						.both(zh: "退出全屏模式时打印的内容。", en: "What is printed when leaving fullscreen mode.")
					),
					choiceField(
						"fullscreenScrollbar", .both(zh: "全屏滚动条", en: "Fullscreen scrollbar"),
						options: ["auto", "always", "hidden"], fallback: "auto",
						.both(zh: "全屏对话记录的滚动条行为。", en: "Scrollbar behaviour in the fullscreen transcript.")
					),
					boolField(
						"fullscreenCopyOnSelect", .both(zh: "选中即复制", en: "Copy on select"), fallback: true,
						.both(zh: "全屏模式下选中文字自动复制。", en: "Copies selected text automatically in fullscreen mode.")
					),
					intField(
						"editorPaddingX", .both(zh: "编辑器水平内边距", en: "Editor horizontal padding"), fallback: 0, min: 0, max: 3,
						.both(zh: "0 到 3 个字符格。", en: "0 to 3 character cells.")
					),
					choiceField(
						"outputPad", .both(zh: "输出内边距", en: "Output padding"),
						options: ["0", "1"], fallback: "1",
						.both(zh: "对话记录的水平内边距。", en: "Horizontal padding of the transcript.")
					),
					intField(
						"autocompleteMaxVisible", .both(zh: "补全可见条数", en: "Autocomplete items shown"), fallback: 5, min: 3, max: 20,
						.both(zh: "自动补全同时显示的条目数，3 到 20。", en: "Number of autocomplete items shown at once, 3 to 20.")
					),
					boolField(
						"showHardwareCursor", .both(zh: "显示硬件光标", en: "Show hardware cursor"), fallback: false,
						.both(zh: "在 Pi 为输入法定位光标时显示终端光标。", en: "Shows the terminal cursor while Pi positions it for the input method.")
					),
					boolField(
						"terminal.showImages", .both(zh: "显示内联图片", en: "Show inline images"), fallback: true,
						.both(zh: "终端支持时显示内联图片。", en: "Shows inline images when the terminal supports them.")
					),
					intField(
						"terminal.imageWidthCells", .both(zh: "图片宽度（字符格）", en: "Image width (cells)"), fallback: 60, min: 1,
						.both(zh: "内联图片的首选宽度。", en: "Preferred width of inline images.")
					),
					boolField(
						"terminal.clearOnShrink", .both(zh: "收缩时清行", en: "Clear lines on shrink"), fallback: false,
						.both(zh: "渲染内容变少时清除空行。", en: "Clears empty lines when the rendered output shrinks.")
					),
					boolField(
						"terminal.showTerminalProgress", .both(zh: "终端进度条", en: "Terminal progress bar"), fallback: false,
						.both(zh: "在终端标签页显示 OSC 9;4 进度。", en: "Shows OSC 9;4 progress in the terminal tab.")
					),
					textField(
						"terminal.hyperlinks", .both(zh: "超链接检测", en: "Hyperlink detection"), "auto",
						.both(zh: "覆盖 OSC 8 超链接检测。", en: "Overrides OSC 8 hyperlink detection."),
						type: .boolOrAuto
					),
					textField(
						"terminal.images", .both(zh: "内联图片协议", en: "Inline image protocol"), "auto",
						.both(zh: "覆盖内联图片协议检测。", en: "Overrides inline image protocol detection."),
						type: .choiceOrFalse(["kitty", "iterm2", "auto"])
					),
					textField(
						"terminal.trueColor", .both(zh: "真彩色", en: "True color"), "auto",
						.both(zh: "覆盖真彩色检测。", en: "Overrides true-color detection."),
						type: .boolOrAuto
					),
					boolField(
						"images.autoResize", .both(zh: "自动缩放图片", en: "Auto-resize images"), fallback: true,
						.both(zh: "发送给模型前把图片缩到最大 2000×2000。", en: "Scales images down to at most 2000×2000 before sending them to the model.")
					),
					boolField(
						"images.blockImages", .both(zh: "禁止发送图片", en: "Block images"), fallback: false,
						.both(zh: "阻止图片发送给模型。", en: "Blocks images from being sent to the model.")
					),
					textField(
						"markdown.codeBlockIndent", .both(zh: "代码块缩进", en: "Code block indent"), "  ",
						.both(zh: "渲染代码块时使用的前缀。", en: "Prefix used when rendering code blocks.")
					),
					choiceField(
						"markdown.mermaid", .both(zh: "Mermaid 渲染", en: "Mermaid rendering"),
						options: ["off", "final", "streaming"], fallback: "streaming",
						.both(zh: "Mermaid 图表的渲染时机。", en: "When Mermaid diagrams are rendered.")
					),
				]
			),
			SettingsSection(
				id: "network",
				title: .both(zh: "网络与重试", en: "Network & retry"),
				icon: "network",
				fields: [
					choiceField(
						"transport", .both(zh: "传输方式", en: "Transport"),
						options: ["auto", "sse", "websocket", "websocket-cached"], fallback: "auto",
						.both(zh: "支持多种传输的 provider 所用的首选传输方式。", en: "Preferred transport for providers that support more than one.")
					),
					textField(
						"httpProxy", .both(zh: "HTTP 代理", en: "HTTP proxy"), "",
						.both(zh: "应用于 Pi 管理的 HTTP 客户端的代理地址，会设置 HTTP_PROXY / HTTPS_PROXY。", en: "Proxy address for the HTTP clients Pi manages; sets HTTP_PROXY / HTTPS_PROXY."),
						scope: .both(zh: "只能写在 agent 目录级别的 settings.json", en: "Only in the agent-directory-level settings.json")
					),
					intField(
						"httpIdleTimeoutMs", .both(zh: "HTTP 空闲超时（毫秒）", en: "HTTP idle timeout (ms)"), fallback: 300000, min: 0,
						.both(zh: "响应头与响应体的空闲超时。0 表示不限制。", en: "Idle timeout for response headers and bodies. 0 means no limit.")
					),
					intField(
						"websocketConnectTimeoutMs", .both(zh: "WebSocket 连接超时（毫秒）", en: "WebSocket connect timeout (ms)"), fallback: 15000, min: 0,
						.both(zh: "WebSocket 连接超时。0 表示不限制。", en: "WebSocket connection timeout. 0 means no limit.")
					),
					boolField(
						"retry.enabled", .both(zh: "自动重试", en: "Automatic retries"), fallback: true,
						.both(zh: "对瞬时失败启用 agent 级自动重试。", en: "Enables agent-level retries for transient failures.")
					),
					intField(
						"retry.maxRetries", .both(zh: "最大重试次数", en: "Maximum retries"), fallback: 3, min: 0,
						.both(zh: "agent 级最大重试次数。", en: "Maximum number of agent-level retries.")
					),
					intField(
						"retry.baseDelayMs", .both(zh: "初始退避（毫秒）", en: "Initial backoff (ms)"), fallback: 2000, min: 0,
						.both(zh: "指数退避的初始延迟。", en: "Initial delay for exponential backoff.")
					),
					intField(
						"retry.maxAgentDelayMs", .both(zh: "最大退避（毫秒）", en: "Maximum backoff (ms)"), fallback: 60000, min: 0,
						.both(zh: "agent 级最大重试延迟。", en: "Maximum agent-level retry delay.")
					),
					intField(
						"retry.provider.timeoutMs", .both(zh: "provider 请求超时（毫秒）", en: "provider request timeout (ms)"), fallback: nil, min: 0,
						.both(zh: "provider 请求超时，默认取 httpIdleTimeoutMs。", en: "Timeout for provider requests; defaults to httpIdleTimeoutMs.")
					),
					intField(
						"retry.provider.maxRetries", .both(zh: "provider 级重试", en: "provider-level retries"), fallback: 0, min: 0,
						.both(zh: "provider 级重试次数。除非确有必要，保持 0；它会推迟 Pi 自行处理配额与限流错误。", en: "Number of provider-level retries. Keep at 0 unless you really need it; it delays Pi's own handling of quota and rate-limit errors.")
					),
					intField(
						"retry.provider.maxRetryDelayMs", .both(zh: "provider 最大重试延迟（毫秒）", en: "provider max retry delay (ms)"),
						fallback: 60000, min: 0,
						.both(zh: "服务端要求的最大重试延迟。0 表示不限制。", en: "Maximum retry delay the server asks for. 0 means no limit.")
					),
				]
			),
			SettingsSection(
				id: "shell",
				title: .both(zh: "Shell", en: "Shell"),
				icon: "terminal",
				fields: [
					textField(
						"shellPath", .both(zh: "Shell 路径", en: "Shell path"), "",
						.both(zh: "自定义 shell 可执行文件路径，支持开头的 `~`。", en: "Path to a custom shell executable; a leading `~` is supported."),
						type: .path
					),
					textField(
						"shellCommandPrefix", .both(zh: "命令前缀", en: "Command prefix"), "",
						.both(zh: "拼接到每条 shell 命令前面的前缀。", en: "Prefix prepended to every shell command.")
					),
					listField(
						"npmCommand", .both(zh: "npm 命令", en: "npm command"),
						.both(zh: "用于 npm 包查找与安装的命令与参数，默认 `[\"npm\"]`。", en: "Command and arguments used for npm package lookup and install; defaults to `[\"npm\"]`.")
					),
				]
			),
			SettingsSection(
				id: "resources",
				title: .both(zh: "资源", en: "Resources"),
				icon: "shippingbox",
				fields: [
					listField(
						"packages", .both(zh: "Pi Packages", en: "Pi Packages"),
						.both(zh: "npm、git 或本地包来源。数组项可以是字符串，也可以是带 extensions / skills / prompts 过滤的对象。建议在“主题 · 扩展 · Packages”面板里管理。", en: "npm, git or local package sources. Items may be strings or objects with extensions / skills / prompts filters. Manage them in the “Themes, Extensions & Packages” pane."),
						type: .mixedList
					),
					listField(
						"extensions", .both(zh: "扩展路径", en: "Extension paths"),
						.both(zh: "额外的扩展文件或目录。支持 `!pattern`、`+path`、`-path`。", en: "Extra extension files or directories. Supports `!pattern`, `+path`, `-path`.")
					),
					listField(
						"skills", .both(zh: "Skills 路径", en: "Skills paths"),
						.both(zh: "额外的 skill 文件或目录。支持 `!pattern`、`+path`、`-path`。", en: "Extra skill files or directories. Supports `!pattern`, `+path`, `-path`.")
					),
					listField(
						"prompts", .both(zh: "Prompt 模板路径", en: "Prompt template paths"),
						.both(zh: "额外的 prompt 模板文件或目录。", en: "Extra prompt template files or directories.")
					),
					listField(
						"themes", .both(zh: "主题路径", en: "Theme paths"),
						.both(zh: "额外的主题文件或目录。", en: "Extra theme files or directories.")
					),
					boolField(
						"enableSkillCommands", .both(zh: "注册 skill 命令", en: "Register skill commands"), fallback: true,
						.both(zh: "把 skills 注册成 `/skill:name` 命令。", en: "Registers skills as `/skill:name` commands.")
					),
				]
			),
			SettingsSection(
				id: "updates",
				title: .both(zh: "更新、遥测与警告", en: "Updates, telemetry & warnings"),
				icon: "arrow.down.circle",
				fields: [
					boolField(
						"collapseChangelog", .both(zh: "折叠更新日志", en: "Collapse changelog"), fallback: false,
						.both(zh: "更新后只显示精简的变更日志。", en: "Shows only a condensed changelog after an update.")
					),
					boolField(
						"enableInstallTelemetry", .both(zh: "安装遥测", en: "Install telemetry"), fallback: true,
						.both(zh: "匿名的安装/更新上报与部分 provider 归属头。不影响更新检查。", en: "Anonymous install/update reporting and some provider attribution headers. Does not affect update checks.")
					),
					boolField(
						"enableAnalytics", .both(zh: "分析数据", en: "Analytics"), fallback: false,
						.both(zh: "选择加入分析数据共享。", en: "Opt in to analytics data sharing.")
					),
					boolField(
						"warnings.anthropicExtraUsage", .both(zh: "Anthropic 额外用量警告", en: "Anthropic extra usage warning"), fallback: true,
						.both(zh: "当 Anthropic 订阅认证可能产生额外计费时给出警告。", en: "Warns when Anthropic subscription auth may incur extra billing.")
					),
				]
			),
		]
	)

	// MARK: - Codex 0.157
	//
	// Taken from the upstream configuration reference
	// (developers.openai.com/codex/config-reference). The help text keeps the
	// upstream English description — so it can be checked against the docs
	// rather than trusted to a translation — alongside a Chinese sentence with
	// the same meaning, added by hand. Where the upstream sentence was pasted
	// truncated, the Chinese stops at the same place instead of inventing the
	// rest.
	//
	// Keys that describe MCP servers or model providers are deliberately absent:
	// they belong to the MCP and models panes. Anything else the reference
	// documents as a table or map shows up in the read-only "其它键（保留）" list
	// and is preserved on write.

	public static let codex0157 = SettingsSchemaDefinition(
		id: "codex-0.157",
		title: .both(zh: "Codex 0.157 设置", en: "Codex 0.157 settings"),
		sections: [
			SettingsSection(
				id: "model",
				title: .both(zh: "模型与推理", en: "Model & reasoning"),
				icon: "cpu",
				fields: [
					textField(
						"model", .both(zh: "默认模型", en: "Default model"), "",
						.both(zh: "要使用的模型（例如 `gpt-6-sol`）。", en: "Model to use (e.g., `gpt-6-sol`).")
					),
					textField(
						"review_model", .both(zh: "/review 用的模型", en: "Model for /review"), "",
						.both(zh: "`/review` 使用的可选模型覆盖（默认为当前 session 的模型）。", en: "Optional model override used by `/review` (defaults to the current session model).")
					),
					textField(
						"model_provider", .both(zh: "默认 provider", en: "Default provider"), "",
						.both(zh: "取自 `model_providers` 的 provider id（默认 `openai`）。", en: "Provider id from `model_providers` (default: `openai`).")
					),
					textField(
						"openai_base_url", .both(zh: "内置 openai provider 的 base URL", en: "Base URL of the built-in openai provider"), "",
						.both(zh: "内置 `openai` model provider 的 base URL 覆盖。", en: "Base URL override for the built-in `openai` model provider.")
					),
					intField(
						"model_context_window", .both(zh: "上下文窗口 token", en: "Context window tokens"), fallback: nil,
						.both(zh: "当前模型可用的上下文窗口 token 数。", en: "Context window tokens available to the active model.")
					),
					intField(
						"model_auto_compact_token_limit", .both(zh: "自动压缩阈值", en: "Auto-compaction threshold"), fallback: nil,
						.both(zh: "触发历史自动压缩的 token 阈值（未设置时使用模型默认值）。", en: "Token threshold that triggers automatic history compaction (unset uses model defaults).")
					),
					choiceField(
						"model_auto_compact_token_limit_scope", .both(zh: "压缩阈值的计量范围", en: "What the threshold counts"),
						options: ["total", "body_after_prefix"], fallback: "total",
						.both(zh: "控制自动压缩阈值是统计完整的当前上下文（`total`，默认），还是只统计沿用压缩窗口前缀之后的增长（`body_after_prefix`）。", en: "Controls whether the auto-compaction threshold counts the full active context (`total`, the default) or only growth after the carried compaction-window prefix (`body_after_prefix`).")
					),
					textField(
						"model_catalog_json", .both(zh: "模型目录 JSON 路径", en: "Model catalog JSON path"), "",
						.both(zh: "启动时加载的 JSON 模型目录的可选路径。选中的 `$CODEX_HOME/profile-name.config.toml` profile 文件可以按 profile 覆盖它。", en: "Optional path to a JSON model catalog loaded on startup. A selected `$CODEX_HOME/profile-name.config.toml` profile file can override this per profile."),
						type: .path
					),
					choiceField(
						"oss_provider", .both(zh: "--oss 的本地 provider", en: "Local provider for --oss"),
						options: ["lmstudio", "ollama"], fallback: "lmstudio",
						.both(zh: "使用 `--oss` 运行时默认的本地 provider（未设置时会先询问）。", en: "Default local provider used when running with `--oss` (defaults to prompting if unset).")
					),
					textField(
						"model_instructions_file", .both(zh: "指令文件（替换 AGENTS.md）", en: "Instructions file (replaces AGENTS.md)"), "",
						.both(zh: "用来替代内置指令、取代 `AGENTS.md` 的文件。", en: "Replacement for built-in instructions instead of `AGENTS.md`."),
						type: .path
					),
					choiceField(
						"personality", .both(zh: "默认沟通风格", en: "Default personality"),
						options: ["none", "friendly", "pragmatic"], fallback: "none",
						.both(zh: "对声明了 `supportsPersonality` 的模型使用的默认沟通风格；可以按 thread/轮次或用 `/personality` 覆盖。", en: "Default communication style for models that advertise `supportsPersonality`; can be overridden per thread/turn or via `/personality`.")
					),
					textField(
						"service_tier", .both(zh: "服务等级", en: "Service tier"), "",
						.both(zh: "新轮次偏好的服务等级。可填 `fast`，或当前模型声明的其它等级；`fast` 映射为请求值 `priority`。", en: "Preferred service tier for new turns. Use `fast` or another tier advertised by the active model; `fast` maps to the request value `priority`.")
					),
					textField(
						"model_reasoning_effort", .both(zh: "推理强度", en: "Reasoning effort"), "",
						.both(zh: "所选模型声明的推理强度，例如 `low`、`medium`、`high`、`xhigh`、`max` 或 `ultra`。可用等级取决于模型和客户端。", en: "Reasoning effort advertised by the selected model, such as `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`. Available levels depend on the model and client.")
					),
					textField(
						"plan_mode_reasoning_effort", .both(zh: "计划模式推理强度", en: "Plan-mode reasoning effort"), "",
						.both(zh: "计划模式专用的推理强度覆盖，取所选模型支持的等级。未设置时，计划模式使用其内置预设默认值。", en: "Plan-mode-specific reasoning override using a level supported by the selected model. When unset, Plan mode uses its built-in preset default.")
					),
					choiceField(
						"model_reasoning_summary", .both(zh: "推理摘要详细度", en: "Reasoning summary detail"),
						options: ["auto", "concise", "detailed", "none"], fallback: "auto",
						.both(zh: "选择推理摘要的详细程度，或完全关闭摘要。", en: "Select reasoning summary detail or disable summaries entirely.")
					),
					choiceField(
						"model_verbosity", .both(zh: "回复详细度", en: "Response verbosity"),
						options: ["low", "medium", "high"], fallback: "low",
						.both(zh: "可选的 GPT-5 Responses API 详细度覆盖；未设置时使用所选模型/预设的默认值。", en: "Optional GPT-5 Responses API verbosity override; when unset, the selected model/preset default is used.")
					),
					boolField(
						"model_supports_reasoning_summaries", .both(zh: "强制发送/不发送推理元数据", en: "Force sending reasoning metadata"), fallback: false,
						.both(zh: "强制 Codex 发送或不发送推理元数据。", en: "Force Codex to send or not send reasoning metadata.")
					),
				]
			),
			SettingsSection(
				id: "approval",
				title: .both(zh: "审批与沙箱", en: "Approval & sandbox"),
				icon: "lock.shield",
				fields: [
					choiceField(
						"approval_policy", .both(zh: "审批策略", en: "Approval policy"),
						options: ["on-request", "never"],
						fallback: "on-request",
						.both(zh: "Codex 执行命令前何时暂停等待审批。上游参考还允许细粒度的表形式（{ granular = { ... } }）；在这里选择取值会用简单形式替换那张表。", en: "When Codex pauses for approval before executing commands. The upstream reference also allows a granular table form ({ granular = { ... } }); choosing a value here replaces that table with the simple form.")
					),
					choiceField(
						"approvals_reviewer", .both(zh: "审批人", en: "Approval reviewer"),
						options: ["user", "auto_review"], fallback: "user",
						.both(zh: "在 `on-request` 或细粒度审批策略下由谁审查符合条件的审批提示。默认为 `user`；`auto_review` 使用审查子 agent。这项设置不改变 sandbox 行为，也不改变 sandbox 内已允许的审查动作。", en: "Who reviews eligible approval prompts under `on-request` or granular approval policies. Defaults to `user`; `auto_review` uses the reviewer subagent. This setting doesnt change sandboxing or review actions already allowed inside the sandbox.")
					),
					boolField(
						"allow_login_shell", .both(zh: "允许登录 shell 语义", en: "Allow login-shell semantics"), fallback: false,
						.both(zh: "允许基于 shell 的工具使用登录 shell 语义。默认为 `true`；为 `false` 时，`login = true` 的请求会被拒绝，省略的 `login` 默认按非登录 shell 处理。", en: "Allow shell-based tools to use login-shell semantics. Defaults to `true`; when `false`, `login = true` requests are rejected and omitted `login` defaults to non-login shells.")
					),
					choiceField(
						"sandbox_mode", .both(zh: "沙箱模式", en: "Sandbox mode"),
						options: ["read-only", "workspace-write", "danger-full-access"], fallback: "read-only",
						.both(zh: "命令执行期间文件系统和网络访问的 sandbox 策略。", en: "Sandbox policy for filesystem and network access during command execution.")
					),
					listField(
						"sandbox_workspace_write.writable_roots", .both(zh: "额外可写根目录", en: "Extra writable roots"),
						.both(zh: "`sandbox_mode = \"workspace-write\"` 时的额外可写根目录。", en: "Additional writable roots when `sandbox_mode = \"workspace-write\"`.,")
					),
					boolField(
						"sandbox_workspace_write.network_access", .both(zh: "工作区内允许联网", en: "Allow network access in the workspace"), fallback: false,
						.both(zh: "允许在 workspace-write sandbox 内访问外部网络。", en: "Allow outbound network access inside the workspace-write sandbox.")
					),
					boolField(
						"sandbox_workspace_write.exclude_tmpdir_env_var", .both(zh: "可写根排除 $TMPDIR", en: "Exclude $TMPDIR from writable roots"), fallback: false,
						.both(zh: "在 workspace-write 模式下把 `$TMPDIR` 排除在可写根之外。", en: "Exclude `$TMPDIR` from writable roots in workspace-write mode.")
					),
					boolField(
						"sandbox_workspace_write.exclude_slash_tmp", .both(zh: "可写根排除 /tmp", en: "Exclude /tmp from writable roots"), fallback: false,
						.both(zh: "在 workspace-write 模式下把 `/tmp` 排除在可写根之外。", en: "Exclude `/tmp` from writable roots in workspace-write mode.")
					),
					textField(
						"default_permissions", .both(zh: "默认权限配置", en: "Default permissions profile"), "",
						.both(zh: "应用于沙箱化工具调用的默认权限配置名。内置的有 `:read-only`、`:workspace` 和 `:danger-full-access`；自定义配置名需要对应的 `[permissions.<name>]` 表。不要与 `sandbox_mode` 或 `[sandbox_workspace_write]` 同时使用。", en: "Name of the default permissions profile to apply to sandboxed tool calls. Built-ins are `:read-only`, `:workspace`, and `:danger-full-access`; custom profile names require matching `[permissions.<name>]` tables. Dont combine with `sandbox_mode` or `[sandbox_workspace_write]`.")
					),
				]
			),
			SettingsSection(
				id: "session",
				title: .both(zh: "会话与上下文", en: "Sessions & context"),
				icon: "clock.arrow.circlepath",
				fields: [
					listField(
						"notify", .both(zh: "通知命令", en: "Notification command"),
						.both(zh: "通知时调用的命令；会从 Codex 收到一段 JSON 负载。", en: "Command invoked for notifications; receives a JSON payload from Codex.")
					),
					textField(
						"instructions", .both(zh: "instructions（保留字段）", en: "instructions (reserved)"), "",
						.both(zh: "保留供将来使用；请优先使用 `model_instructions_file` 或 `AGENTS.md`。", en: "Reserved for future use; prefer `model_instructions_file` or `AGENTS.md`.")
					),
					textField(
						"developer_instructions", .both(zh: "附加开发者指令", en: "Extra developer instructions"), "",
						.both(zh: "注入 session 的附加开发者指令（可选）。", en: "Additional developer instructions injected into the session (optional).")
					),
					textField(
						"log_dir", .both(zh: "日志目录", en: "Log directory"), "",
						.both(zh: "Codex 写日志文件的目录；默认为 `$CODEX_HOME/log`。显式设置它还会在该目录启用需要主动开启的明文 TUI 日志 `codex-tui.log`。", en: "Directory where Codex writes log files; defaults to `$CODEX_HOME/log`. Setting this explicitly also enables the opt-in plaintext TUI log, `codex-tui.log`, in that directory."),
						type: .path
					),
					textField(
						"sqlite_home", .both(zh: "SQLite 状态目录", en: "SQLite state directory"), "",
						.both(zh: "Codex 存放 SQLite 状态数据库的目录，agent 任务和其它可恢复的运行时状态都用它。", en: "Directory where Codex stores the SQLite-backed state DB used by agent jobs and other resumable runtime state."),
						type: .path
					),
					textField(
						"compact_prompt", .both(zh: "压缩提示词（内联）", en: "Compaction prompt (inline)"), "",
						.both(zh: "历史压缩 prompt 的内联覆盖。", en: "Inline override for the history compaction prompt.")
					),
					textField(
						"experimental_compact_prompt_file", .both(zh: "压缩提示词文件（实验）", en: "Compaction prompt file (experimental)"), "",
						.both(zh: "从文件加载压缩 prompt 覆盖（实验性）。", en: "Load the compaction prompt override from a file (experimental)."),
						type: .path
					),
					intField(
						"mcp_optional_startup_grace_ms", .both(zh: "可选 MCP 启动宽限（毫秒）", en: "Optional MCP startup grace (ms)"), fallback: nil, min: 0,
						.both(zh: "构建初始工具目录时对可选 MCP server 的统一等待时间。默认为 `1000`。设为 `0` 则改为按每个 server 的 `startup_timeout_sec` 等待。", en: "Shared wait for optional MCP servers when building the initial tool catalog. Defaults to `1000`. Set to `0` to wait for each servers `startup_timeout_sec` instead.")
					),
					listField(
						"project_root_markers", .both(zh: "项目根标记文件", en: "Project root marker files"),
						.both(zh: "项目根标记文件名列表；向上级目录查找项目根时使用。", en: "List of project root marker filenames; used when searching parent directories for the project root.")
					),
					intField(
						"project_doc_max_bytes", .both(zh: "AGENTS.md 最大读取字节", en: "Max bytes read from AGENTS.md"), fallback: nil,
						.both(zh: "构建项目指令时从 `AGENTS.md` 读取的最大字节数。", en: "Maximum bytes read from `AGENTS.md` when building project instructions.")
					),
					listField(
						"project_doc_fallback_filenames", .both(zh: "AGENTS.md 的备用文件名", en: "Fallback names for AGENTS.md"),
						.both(zh: "`AGENTS.md` 缺失时额外尝试的文件名。", en: "Additional filenames to try when `AGENTS.md` is missing.")
					),
					choiceField(
						"history.persistence", .both(zh: "保存会话历史", en: "Persist session history"),
						options: ["save-all", "none"], fallback: "save-all",
						.both(zh: "控制 Codex 是否把 session 记录保存到 history.jsonl。", en: "Control whether Codex saves session transcripts to history.jsonl.")
					),
					intField(
						"tool_output_token_limit", .both(zh: "工具输出 token 预算", en: "Tool output token budget"), fallback: nil,
						.both(zh: "历史里保存单个工具/函数输出的 token 预算。", en: "Token budget for storing individual tool/function outputs in history.")
					),
					intField(
						"background_terminal_max_timeout", .both(zh: "后台终端轮询上限（毫秒）", en: "Background terminal poll limit (ms)"), fallback: nil,
						.both(zh: "空 `write_stdin` 轮询（后台终端轮询）的最大时间窗，单位毫秒。默认 `300000`（5 分钟）。取代较早的 `background_terminal_timeout` 键。", en: "Maximum poll window in milliseconds for empty `write_stdin` polls (background terminal polling). Default: `300000` (5 minutes). Replaces the older `background_terminal_timeout` key.")
					),
					intField(
						"history.max_bytes", .both(zh: "历史文件大小上限", en: "History file size limit"), fallback: nil,
						.both(zh: "设置后按字节限制历史文件大小，超出时丢弃最旧的条目。", en: "If set, caps the history file size in bytes by dropping oldest entries.")
					),
				]
			),
			SettingsSection(
				id: "tui",
				title: .both(zh: "终端界面", en: "Terminal interface"),
				icon: "textformat",
				fields: [
					boolField(
						"check_for_update_on_startup", .both(zh: "启动时检查更新", en: "Check for updates on startup"), fallback: false,
						.both(zh: "启动时检查 Codex 更新（只应在更新由中央统一管理时设为 false）。", en: "Check for Codex updates on startup (set to false only when updates are centrally managed).")
					),
					boolField(
						"suppress_unstable_features_warning", .both(zh: "隐藏实验特性警告", en: "Hide experimental feature warning"), fallback: false,
						.both(zh: "隐藏启用开发中特性开关时出现的警告。", en: "Suppress the warning that appears when under-development feature flags are enabled.")
					),
					choiceField(
						"file_opener", .both(zh: "打开引用用的编辑器", en: "Editor for opening citations"),
						options: ["vscode", "vscode-insiders", "windsurf", "cursor", "none"], fallback: "vscode",
						.both(zh: "打开 Codex 输出中引用所用的 URI scheme（默认 `vscode`）。", en: "URI scheme used to open citations from Codex output (default: `vscode`).")
					),
					jsonField(
						"tui.notifications", .both(zh: "TUI 通知", en: "TUI notifications"),
						.both(zh: "启用 TUI 通知；可以选择只对特定事件类型通知。", en: "Enable TUI notifications; optionally restrict to specific event types.")
					),
					choiceField(
						"tui.notification_method", .both(zh: "通知方式", en: "Notification method"),
						options: ["auto", "osc9", "bel"], fallback: "auto",
						.both(zh: "终端通知的通知方式（默认 auto）。", en: "Notification method for terminal notifications (default: auto).")
					),
					choiceField(
						"tui.notification_condition", .both(zh: "通知触发条件", en: "Notification condition"),
						options: ["unfocused", "always"], fallback: "unfocused",
						.both(zh: "控制 TUI 通知只在终端失焦时触发，还是不论焦点都触发。默认为 `unfocused`。", en: "Control whether TUI notifications fire only when the terminal is unfocused or regardless of focus. Defaults to `unfocused`.")
					),
					boolField(
						"tui.animations", .both(zh: "终端动画", en: "Terminal animations"), fallback: false,
						.both(zh: "启用终端动画（欢迎页、shimmer、加载指示器）（默认 true）。", en: "Enable terminal animations (welcome screen, shimmer, spinner) (default: true).")
					),
					choiceField(
						"tui.alternate_screen", .both(zh: "备用屏幕", en: "Alternate screen"),
						options: ["auto", "always", "never"], fallback: "auto",
						.both(zh: "控制 TUI 是否使用备用屏幕（默认 auto；auto 在 Zellij 里会跳过，以保留回滚缓冲）。", en: "Control alternate screen usage for the TUI (default: auto; auto skips it in Zellij to preserve scrollback).")
					),
					choiceField(
						"tui.resume_cwd", .both(zh: "恢复会话时的工作目录", en: "Working directory when resuming"),
						options: ["current", "session"], fallback: "current",
						.both(zh: "恢复或分叉 session 时使用的工作目录。未设置时，如果你的当前目录与 session 保存的目录不同，Codex 会让你选择。", en: "Working directory to use when resuming or forking a session. When unset, Codex asks you to choose if your current directory differs from the sessions saved directory.")
					),
					boolField(
						"tui.vim_mode_default", .both(zh: "输入框默认 Vim 模式", en: "Vim mode by default"), fallback: false,
						.both(zh: "让输入框以 Vim 普通模式而不是插入模式启动（默认 false）。你仍可以用 `/vim` 按 session 切换。", en: "Start the composer in Vim normal mode instead of insert mode (default: false). You can still toggle it per session with `/vim`.")
					),
					boolField(
						"tui.raw_output_mode", .both(zh: "原始滚动模式", en: "Raw scrollback mode"), fallback: false,
						.both(zh: "让 TUI 以原始回滚模式启动，方便终端里复制（默认 false）。可以用 `/raw` 或默认的 `alt-r` 快捷键切换。", en: "Start the TUI in raw scrollback mode for copy-friendly terminal selection (default: false). You can toggle it with `/raw` or the default `alt-r` key binding.")
					),
					boolField(
						"tui.show_tooltips", .both(zh: "欢迎页提示", en: "Welcome screen tooltips"), fallback: false,
						.both(zh: "在 TUI 欢迎页显示上手提示（默认 true）。", en: "Show onboarding tooltips in the TUI welcome screen (default: true).")
					),
					textField(
						"tui.theme", .both(zh: "语法高亮主题", en: "Syntax highlighting theme"), "",
						.both(zh: "语法高亮主题覆盖（kebab-case 主题名）。", en: "Syntax-highlighting theme override (kebab-case theme name).")
					),
					boolField(
						"hide_agent_reasoning", .both(zh: "隐藏推理事件", en: "Hide reasoning events"), fallback: false,
						.both(zh: "在 TUI 和 `codex exec` 输出里都隐藏推理事件。", en: "Suppress reasoning events in both the TUI and `codex exec` output.")
					),
					boolField(
						"show_raw_agent_reasoning", .both(zh: "显示原始推理内容", en: "Show raw reasoning"), fallback: false,
						.both(zh: "当前模型输出原始推理内容时把它显示出来。", en: "Surface raw reasoning content when the active model emits it.")
					),
					boolField(
						"disable_paste_burst", .both(zh: "禁用粘贴突发检测", en: "Disable paste burst detection"), fallback: false,
						.both(zh: "关闭 TUI 里的突发粘贴检测。", en: "Disable burst-paste detection in the TUI.")
					),
					boolField(
						"windows_wsl_setup_acknowledged", .both(zh: "WSL 引导已确认（仅 Windows）", en: "WSL onboarding acknowledged (Windows only)"), fallback: false,
						.both(zh: "记录 Windows 上手引导是否已确认（仅 Windows）。", en: "Track Windows onboarding acknowledgement (Windows only).")
					),
					boolField(
						"experimental_use_unified_exec_tool", .both(zh: "统一 exec 工具（旧名）", en: "Unified exec tool (legacy name)"), fallback: false,
						.both(zh: "启用统一 exec 的旧键名；请优先使用 `[features].unified_exec` 或 `codex --enable unified_exec`。", en: "Legacy name for enabling unified exec; prefer `[features].unified_exec` or `codex --enable unified_exec`.")
					),
				]
			),
			SettingsSection(
				id: "auth",
				title: .both(zh: "凭据与登录", en: "Credentials & login"),
				icon: "key.horizontal",
				fields: [
					textField(
						"chatgpt_base_url", .both(zh: "ChatGPT 登录 base URL", en: "ChatGPT login base URL"), "",
						.both(zh: "覆盖 ChatGPT 登录流程使用的 base URL。", en: "Override the base URL used during the ChatGPT login flow.")
					),
					choiceField(
						"cli_auth_credentials_store", .both(zh: "CLI 凭据存储", en: "CLI credential store"),
						options: ["file", "keyring", "auto", "ephemeral"], fallback: "file",
						.both(zh: "控制 CLI 把缓存的凭据存放在哪里。", en: "Control where the CLI stores cached credentials.")
					),
					choiceField(
						"mcp_oauth_credentials_store", .both(zh: "MCP OAuth 凭据存储", en: "MCP OAuth credential store"),
						options: ["auto", "file", "keyring"], fallback: "auto",
						.both(zh: "MCP OAuth 凭据的首选存放位置。", en: "Preferred store for MCP OAuth credentials.")
					),
					intField(
						"mcp_oauth_callback_port", .both(zh: "MCP OAuth 回调端口", en: "MCP OAuth callback port"), fallback: nil,
						.both(zh: "MCP OAuth 登录期间本地 HTTP 回调服务器可选的全局固定端口。server 自己的 `oauth.callback_port` 优先。两者都没设置时，Codex 绑定由操作系统选的临时端口。", en: "Optional global fixed port for the local HTTP callback server used during MCP OAuth login. A server-specific `oauth.callback_port` takes precedence. When neither is set, Codex binds to an ephemeral port chosen by the OS.")
					),
					textField(
						"mcp_oauth_callback_url", .both(zh: "MCP OAuth 回调地址", en: "MCP OAuth callback URL"), "",
						.both(zh: "MCP OAuth 登录可选的基础回调 URL，例如 devbox 入口 URL。授权服务器支持 issuer 识别时，新增的预注册客户端会原样使用这个 URL；没有保存回调的既有客户端会追加 server 专属的回调 ID。不支持 issuer 时。", en: "Optional base callback URL for MCP OAuth login, such as a devbox ingress URL. Newly added pre-registered clients use this URL unchanged when the authorization server supports issuer identification; existing clients without a saved callback append a server-specific callback ID. Without issuer support")
					),
					choiceField(
						"forced_login_method", .both(zh: "强制登录方式", en: "Forced login method"),
						options: ["chatgpt", "api"], fallback: "chatgpt",
						.both(zh: "把 Codex 限制为特定的认证方式。", en: "Restrict Codex to a specific authentication method.")
					),
				]
			),
			SettingsSection(
				id: "tools",
				title: .both(zh: "工具与技能", en: "Tools & skills"),
				icon: "wrench.and.screwdriver",
				fields: [
					intField(
						"skills.max_context_tokens", .both(zh: "skills 目录 token 预算", en: "Skills catalog token budget"), fallback: nil, min: 0,
						.both(zh: "可用 skills 目录的 token 预算。默认为模型上下文窗口的 2%。显式取值上限为 `10000` token。", en: "Token budget for the available-skills catalog. Defaults to 2% of the models context window. Explicit values are capped at `10000` tokens.")
					),
					jsonField(
						"skills.config", .both(zh: "单个 skill 的启用开关", en: "Per-skill enablement"),
						.both(zh: "按 skill 的启用覆盖，存放在 config.toml 里。", en: "Per-skill enablement overrides stored in config.toml.")
					),
					boolField(
						"tools.view_image", .both(zh: "启用 view_image 工具", en: "Enable the view_image tool"), fallback: false,
						.both(zh: "启用本地图片附件工具 `view_image`。", en: "Enable the local-image attachment tool `view_image`.")
					),
					choiceField(
						"web_search", .both(zh: "网页搜索模式", en: "Web search mode"),
						options: ["disabled", "cached", "indexed", "live"], fallback: "disabled",
						.both(zh: "网页搜索模式（默认 `\"cached\"`；cached 使用 OpenAI 维护的索引，不访问外部网络；indexed 仅在搜索索引放行时允许外部访问；如果你使用 `--yolo` 或其它完全访问的 sandbox 设置，则默认为 `\"live\"`）。用 `\"live\"` 获得不受限的实时…", en: "Web search mode (default: `\"cached\"`; cached uses an OpenAI-maintained index without external web access; indexed permits external access only when gated by the search index; if you use `--yolo` or another full access sandbox setting, it defaults to `\"live\"`). Use `\"live\"` for unrestricted liv")
					),
				]
			),
		]
	)

	/// Schemas this build knows about, keyed by the descriptor's `schema` value.
	public static let all: [SettingsSchemaDefinition] = [pi087, codex0157, claudeCode]

	public static func definition(for id: String?) -> SettingsSchemaDefinition? {
		guard let id else { return nil }
		return all.first { $0.id == id }
	}
}
