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
	public let label: String
	public let type: SettingFieldType
	public let help: String
	public let fallback: String
	public let scopeNote: String?

	public var id: String { key }
	public var path: [String] { key.split(separator: ".").map(String.init) }
}

public struct SettingsSection: Identifiable {
	public let id: String
	public let title: String
	public let icon: String
	public let fields: [SettingField]
}

public struct SettingsSchemaDefinition: Identifiable {
	public let id: String
	public let title: String
	public let sections: [SettingsSection]

	public var fields: [SettingField] { sections.flatMap(\.fields) }

	public func field(key: String) -> SettingField? {
		fields.first { $0.key == key }
	}

	public var knownKeys: Set<String> { Set(fields.map(\.key)) }
}

// MARK: - Builder helpers

private func boolField(
	_ key: String, _ label: String, fallback: Bool, _ help: String, scope: String? = nil
) -> SettingField {
	SettingField(
		key: key, label: label, type: .bool, help: help,
		fallback: fallback ? "true" : "false", scopeNote: scope
	)
}

private func intField(
	_ key: String, _ label: String, fallback: Int?, min: Int? = nil, max: Int? = nil,
	_ help: String, scope: String? = nil
) -> SettingField {
	SettingField(
		key: key, label: label, type: .integer(min: min, max: max), help: help,
		fallback: fallback.map(String.init) ?? "", scopeNote: scope
	)
}

private func textField(
	_ key: String, _ label: String, _ fallback: String = "", _ help: String,
	type: SettingFieldType = .text, scope: String? = nil
) -> SettingField {
	SettingField(key: key, label: label, type: type, help: help, fallback: fallback, scopeNote: scope)
}

private func choiceField(
	_ key: String, _ label: String, options: [String], fallback: String, _ help: String,
	scope: String? = nil
) -> SettingField {
	SettingField(
		key: key, label: label, type: .choice(options), help: help,
		fallback: fallback, scopeNote: scope
	)
}

private func listField(
	_ key: String, _ label: String, _ help: String, type: SettingFieldType = .textList,
	fallback: String = "[]"
) -> SettingField {
	SettingField(key: key, label: label, type: type, help: help, fallback: fallback, scopeNote: nil)
}

private func jsonField(
	_ key: String, _ label: String, _ help: String, fallback: String = "{}"
) -> SettingField {
	SettingField(key: key, label: label, type: .json, help: help, fallback: fallback, scopeNote: nil)
}

// MARK: - pi 0.87 settings

public enum SettingsSchema {
	public static let pi087 = SettingsSchemaDefinition(
		id: "pi-settings-0.87",
		title: "pi 0.87 设置",
		sections: [
			SettingsSection(
				id: "model",
				title: "模型与思考",
				icon: "cpu",
				fields: [
					textField("defaultProvider", "默认 Provider", "", "启动时使用的 provider。留空表示自动选择。"),
					textField("defaultModel", "默认模型", "", "启动时使用的模型 id。留空表示自动选择。"),
					choiceField(
						"defaultThinkingLevel", "默认思考等级",
						options: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
						fallback: "medium",
						"启动时的思考等级。模型不支持的等级会被忽略。"
					),
					jsonField(
						"modelThinkingLevels", "逐模型思考等级",
						"以 `provider/modelId` 为键指定每个模型启动时的思考等级。"
					),
					jsonField(
						"thinkingBudgets", "思考预算",
						"为 minimal / low / medium / high 覆盖内置的 token 预算。"
					),
					listField(
						"enabledModels", "可循环的模型",
						"启动选择与 Ctrl+P 循环使用的模型匹配式，支持 `provider/*`、`*sonnet*` 等通配。"
					),
					boolField("hideThinkingBlock", "隐藏思考块", fallback: false, "在对话记录里隐藏思考内容。"),
					boolField(
						"showCacheMissNotices", "显示缓存提示", fallback: false,
						"显示明显的缓存未命中、成功预热、压缩用量与 provider 恢复提示。"
					),
					choiceField(
						"cacheWarming", "缓存预热",
						options: ["off", "streaming", "idle"],
						fallback: "streaming",
						"在运行期间（streaming）或两次运行之间（idle）保持可用的 provider 提示缓存。",
						scope: "只能写在 agent 目录级别的 settings.json"
					),
				]
			),
			SettingsSection(
				id: "interaction",
				title: "交互",
				icon: "hand.tap",
				fields: [
					choiceField(
						"steeringMode", "引导消息投递",
						options: ["all", "one-at-a-time"], fallback: "one-at-a-time",
						"排队中的引导消息如何投递。"
					),
					choiceField(
						"followUpMode", "追问投递",
						options: ["all", "one-at-a-time"], fallback: "one-at-a-time",
						"排队中的追问消息如何投递。"
					),
					textField(
						"externalEditor", "外部编辑器", "",
						"外部编辑器快捷键调用的命令。默认为 $VISUAL、$EDITOR 或平台默认值。"
					),
					choiceField(
						"doubleEscapeAction", "双击 Esc",
						options: ["tree", "fork", "none"], fallback: "tree",
						"编辑器为空时连按两次 Esc 的动作。"
					),
					choiceField(
						"treeFilterMode", "/tree 初始过滤",
						options: ["default", "no-tools", "user-only", "labeled-only", "all"],
						fallback: "default",
						"/tree 打开时使用的初始过滤器。"
					),
					choiceField(
						"defaultProjectTrust", "默认项目信任",
						options: ["ask", "always", "never"], fallback: "ask",
						"项目信任的兜底行为。",
						scope: "只能写在 agent 目录级别的 settings.json"
					),
				]
			),
			SettingsSection(
				id: "tools",
				title: "工具",
				icon: "wrench.and.screwdriver",
				fields: [
					listField(
						"defaultTools", "默认启用的工具",
						"启动时启用的内置工具。可选 read、bash、powershell、edit、write、grep、find、ls。空数组会关闭全部内置工具。"
					),
				]
			),
			SettingsSection(
				id: "sessions",
				title: "会话与上下文",
				icon: "clock.arrow.circlepath",
				fields: [
					textField(
						"sessionDir", "会话目录", "",
						"会话存储目录。相对路径从工作目录解析。",
						type: .path
					),
					boolField("compaction.enabled", "自动压缩", fallback: true, "启用自动上下文压缩。"),
					intField(
						"compaction.reserveTokens", "压缩预留 token", fallback: 16384, min: 0,
						"为模型回复预留的 token。"
					),
					intField(
						"compaction.keepRecentTokens", "保留最近 token", fallback: 20000, min: 0,
						"不参与摘要、原样保留的近期 token 数。"
					),
					jsonField(
						"compaction.modelOverrides", "逐模型压缩设置",
						"以 `provider/modelId` 为键覆盖上面的压缩 token 设置。"
					),
					intField(
						"branchSummary.reserveTokens", "分支摘要预留 token", fallback: 16384, min: 0,
						"生成分支摘要时预留的 token。"
					),
					boolField(
						"branchSummary.skipPrompt", "跳过分支摘要提示", fallback: false,
						"跳过分支摘要询问，直接按“不生成摘要”处理。"
					),
				]
			),
			SettingsSection(
				id: "display",
				title: "终端与显示",
				icon: "textformat",
				fields: [
					textField("theme", "主题", "", "内置或自定义主题名，支持 `浅色/深色` 双主题写法。"),
					boolField("quietStartup", "静默启动", fallback: false, "隐藏启动头部。"),
					choiceField(
						"tuiMode", "TUI 模式",
						options: ["regular", "fullscreen"], fallback: "regular",
						"交互式终端界面的模式。"
					),
					choiceField(
						"fullscreenExitOutput", "全屏退出输出",
						options: ["transcript", "resume-hint"], fallback: "transcript",
						"退出全屏模式时打印的内容。"
					),
					choiceField(
						"fullscreenScrollbar", "全屏滚动条",
						options: ["auto", "always", "hidden"], fallback: "auto",
						"全屏对话记录的滚动条行为。"
					),
					boolField(
						"fullscreenCopyOnSelect", "选中即复制", fallback: true,
						"全屏模式下选中文字自动复制。"
					),
					intField("editorPaddingX", "编辑器水平内边距", fallback: 0, min: 0, max: 3, "0 到 3 个字符格。"),
					choiceField(
						"outputPad", "输出内边距",
						options: ["0", "1"], fallback: "1",
						"对话记录的水平内边距。"
					),
					intField(
						"autocompleteMaxVisible", "补全可见条数", fallback: 5, min: 3, max: 20,
						"自动补全同时显示的条目数，3 到 20。"
					),
					boolField(
						"showHardwareCursor", "显示硬件光标", fallback: false,
						"在 Pi 为输入法定位光标时显示终端光标。"
					),
					boolField("terminal.showImages", "显示内联图片", fallback: true, "终端支持时显示内联图片。"),
					intField(
						"terminal.imageWidthCells", "图片宽度（字符格）", fallback: 60, min: 1,
						"内联图片的首选宽度。"
					),
					boolField(
						"terminal.clearOnShrink", "收缩时清行", fallback: false,
						"渲染内容变少时清除空行。"
					),
					boolField(
						"terminal.showTerminalProgress", "终端进度条", fallback: false,
						"在终端标签页显示 OSC 9;4 进度。"
					),
					textField(
						"terminal.hyperlinks", "超链接检测", "auto",
						"覆盖 OSC 8 超链接检测。",
						type: .boolOrAuto
					),
					textField(
						"terminal.images", "内联图片协议", "auto",
						"覆盖内联图片协议检测。",
						type: .choiceOrFalse(["kitty", "iterm2", "auto"])
					),
					textField(
						"terminal.trueColor", "真彩色", "auto",
						"覆盖真彩色检测。",
						type: .boolOrAuto
					),
					boolField(
						"images.autoResize", "自动缩放图片", fallback: true,
						"发送给模型前把图片缩到最大 2000×2000。"
					),
					boolField("images.blockImages", "禁止发送图片", fallback: false, "阻止图片发送给模型。"),
					textField(
						"markdown.codeBlockIndent", "代码块缩进", "  ",
						"渲染代码块时使用的前缀。"
					),
					choiceField(
						"markdown.mermaid", "Mermaid 渲染",
						options: ["off", "final", "streaming"], fallback: "streaming",
						"Mermaid 图表的渲染时机。"
					),
				]
			),
			SettingsSection(
				id: "network",
				title: "网络与重试",
				icon: "network",
				fields: [
					choiceField(
						"transport", "传输方式",
						options: ["auto", "sse", "websocket", "websocket-cached"], fallback: "auto",
						"支持多种传输的 provider 所用的首选传输方式。"
					),
					textField(
						"httpProxy", "HTTP 代理", "",
						"应用于 Pi 管理的 HTTP 客户端的代理地址，会设置 HTTP_PROXY / HTTPS_PROXY。",
						scope: "只能写在 agent 目录级别的 settings.json"
					),
					intField(
						"httpIdleTimeoutMs", "HTTP 空闲超时（毫秒）", fallback: 300000, min: 0,
						"响应头与响应体的空闲超时。0 表示不限制。"
					),
					intField(
						"websocketConnectTimeoutMs", "WebSocket 连接超时（毫秒）", fallback: 15000, min: 0,
						"WebSocket 连接超时。0 表示不限制。"
					),
					boolField("retry.enabled", "自动重试", fallback: true, "对瞬时失败启用 agent 级自动重试。"),
					intField("retry.maxRetries", "最大重试次数", fallback: 3, min: 0, "agent 级最大重试次数。"),
					intField(
						"retry.baseDelayMs", "初始退避（毫秒）", fallback: 2000, min: 0,
						"指数退避的初始延迟。"
					),
					intField(
						"retry.maxAgentDelayMs", "最大退避（毫秒）", fallback: 60000, min: 0,
						"agent 级最大重试延迟。"
					),
					intField(
						"retry.provider.timeoutMs", "provider 请求超时（毫秒）", fallback: nil, min: 0,
						"provider 请求超时，默认取 httpIdleTimeoutMs。"
					),
					intField(
						"retry.provider.maxRetries", "provider 级重试", fallback: 0, min: 0,
						"provider 级重试次数。除非确有必要，保持 0；它会推迟 Pi 自行处理配额与限流错误。"
					),
					intField(
						"retry.provider.maxRetryDelayMs", "provider 最大重试延迟（毫秒）",
						fallback: 60000, min: 0,
						"服务端要求的最大重试延迟。0 表示不限制。"
					),
				]
			),
			SettingsSection(
				id: "shell",
				title: "Shell",
				icon: "terminal",
				fields: [
					textField(
						"shellPath", "Shell 路径", "",
						"自定义 shell 可执行文件路径，支持开头的 `~`。",
						type: .path
					),
					textField("shellCommandPrefix", "命令前缀", "", "拼接到每条 shell 命令前面的前缀。"),
					listField(
						"npmCommand", "npm 命令",
						"用于 npm 包查找与安装的命令与参数，默认 `[\"npm\"]`。"
					),
				]
			),
			SettingsSection(
				id: "resources",
				title: "资源",
				icon: "shippingbox",
				fields: [
					listField(
						"packages", "Pi Packages",
						"npm、git 或本地包来源。数组项可以是字符串，也可以是带 extensions / skills / prompts 过滤的对象。建议在“主题 · 扩展 · Packages”面板里管理。",
						type: .mixedList
					),
					listField("extensions", "扩展路径", "额外的扩展文件或目录。支持 `!pattern`、`+path`、`-path`。"),
					listField("skills", "Skills 路径", "额外的 skill 文件或目录。支持 `!pattern`、`+path`、`-path`。"),
					listField("prompts", "Prompt 模板路径", "额外的 prompt 模板文件或目录。"),
					listField("themes", "主题路径", "额外的主题文件或目录。"),
					boolField(
						"enableSkillCommands", "注册 skill 命令", fallback: true,
						"把 skills 注册成 `/skill:name` 命令。"
					),
				]
			),
			SettingsSection(
				id: "updates",
				title: "更新、遥测与警告",
				icon: "arrow.down.circle",
				fields: [
					boolField("collapseChangelog", "折叠更新日志", fallback: false, "更新后只显示精简的变更日志。"),
					boolField(
						"enableInstallTelemetry", "安装遥测", fallback: true,
						"匿名的安装/更新上报与部分 provider 归属头。不影响更新检查。"
					),
					boolField("enableAnalytics", "分析数据", fallback: false, "选择加入分析数据共享。"),
					boolField(
						"warnings.anthropicExtraUsage", "Anthropic 额外用量警告", fallback: true,
						"当 Anthropic 订阅认证可能产生额外计费时给出警告。"
					),
				]
			),
		]
	)

	/// Schemas this build knows about, keyed by the descriptor's `schema` value.
	public static let all: [SettingsSchemaDefinition] = [pi087]

	public static func definition(for id: String?) -> SettingsSchemaDefinition? {
		guard let id else { return nil }
		return all.first { $0.id == id }
	}
}
