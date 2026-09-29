#!/usr/bin/env python3
"""Generate the Claude Code settings schema from the upstream reference.

    curl -sL https://code.claude.com/docs/en/settings-reference.md -o /tmp/ck-settings.md
    Tools/make-claude-schema.py > Sources/Surfaces/SettingsSchemaClaude.swift

Deriving the field table from the published reference rather than from memory
means every key, its type and its default come from the source Claude Code itself
documents, and re-running after an upgrade shows exactly what moved.

Labels are the literal JSON keys. That is deliberate: inventing a Chinese name
for each of a hundred keys would hide which key is being edited, and these files
are read next to the English docs anyway. They are written as an explicit
`zh`/`en` pair rather than as a plain string so that no value in a shipped
schema carries only one language — a plain label there would be
indistinguishable from a forgotten translation.

Help is bilingual: the English sentence comes from the reference, the Chinese
sentence from `HELP_ZH` below, because the reference has no Chinese edition.
A key the reference gains but `HELP_ZH` lacks stops the script (exit 1) and is
listed by name; it is emitted with English on both sides so the file still
compiles, and the `isPlain` assertion in `Tests/main.swift` turns red with it.

The reference also groups keys into topics. `TOPICS` maps those topic names to
AgentKit's own section titles; a topic the reference carries but `TOPICS` does
not is reported on stderr (it used to be dropped in silence, which hid ~90 keys
after the upstream headings were renamed).
"""

import re
import sys

SOURCE = "/tmp/ck-settings.md"

# The reference's own topics, in display order, with both section titles and an
# icon. The first element must match the reference's topic heading exactly.
TOPICS = [
    ("Model and responses", "模型与回复", "Model and responses", "cpu"),
    ("Permission settings", "权限", "Permissions", "lock.shield"),
    ("Agents, sessions, and worktrees", "Agent 与会话", "Agents, sessions, and worktrees", "person.2"),
    ("Context and memory", "上下文与记忆", "Context and memory", "text.book.closed"),
    ("MCP", "MCP", "MCP", "point.3.connected.trianglepath.dotted"),
    ("Plugins and skills", "插件与 Skills", "Plugins and skills", "puzzlepiece.extension"),
    ("Hooks and automation", "Hooks 与自动化", "Hooks and automation", "bolt"),
    ("Interface and display", "界面与显示", "Interface and display", "macwindow"),
    ("Remote, desktop, and notifications", "远程、桌面与通知", "Remote, desktop, and notifications", "bell"),
    ("Telemetry and updates", "遥测与更新", "Telemetry and updates", "chart.bar"),
    ("Environment and providers", "环境与 provider", "Environment and providers", "network"),
    ("Authentication and accounts", "认证与账号", "Authentication and accounts", "key"),
    ("Sandbox and security", "沙箱与安全", "Sandbox and security", "shield.lefthalf.filled"),
    ("Other", "其它", "Other", "ellipsis.circle"),
]

# Chinese help, one entry per key, keyed by the JSON key so an upstream rename
# shows up as a missing entry instead of silently keeping a stale sentence.
# Terms that stay English: provider, MCP, skills, session, sandbox, hook,
# token, plugin, agent, subagent, server, worktree, prompt.
HELP_ZH = {
    "advisorModel": "选择 Claude 调用服务端 advisor 工具时由哪个模型作答。不设置则关闭 advisor。advisor 的能力必须不低于主模型。可接受的模型组合，以及选了不被接受的模型会怎样，见「选择一个 advisor 模型」。",
    "alwaysThinkingEnabled": "把它设为 false 可以为每个 session 关闭扩展思考。思考默认开启，所以 true 不改变任何行为。多数人通过 /config 设置它，而不是直接编辑文件。在始终思考的模型上，例如 Opus 5.5、Sonnet 5.5 和 Fable 系列，false…",
    "availableModels": "限制人们可以为主 session、subagent、skills 和 advisor 选择哪些模型。组织下发的列表会约束 /model、--model 以及开发者自己文件里的 model 键；不在列表内的模型无法被选中。按默认的前缀匹配，它不会触及…",
    "effortLevel": "为还没有保存过等级的模型设置默认 effort 等级。较低等级在简单任务上更快更便宜，较高等级在复杂问题上推理更深。当你在本机的交互式 session 里运行 /effort low、medium、high 或 xhigh 时…",
    "enforceAvailableModels": "/model 选择器有一个 **Default** 选项，默认模型设置描述了它解析到哪个模型。availableModels 允许列表限制了你能指定的模型，但在默认的前缀匹配下它不会重映射你账号类型的默认模型，所以 **Default** 仍可能…",
    "fallbackModel": "按顺序指定主模型过载或不可用时 Claude Code 可以尝试的备用模型。Claude Code 会在本轮剩余时间里切到链上的下一个可用模型并给出提示。没有配置链时，Claude Code 用同一个模型重试，然后…",
    "fastMode": "在支持的 session 上开启快速模式，用于快速迭代、实时调试这类你要速度、愿意付更高每 token 成本的交互工作。通常不必手动改这个键：运行 /fast 会把 fastMode: true 写入 ~/.claude/settings.json，而运行…",
    "fastModePerSessionOptIn": "通常运行 /fast 会把 fastMode 保存到用户设置里，于是之后每个 session 启动时快速模式都是开的。把这个键设为 true 可以阻止这种行为：已保存的 fastMode: true 不再在 session 启动时开启快速模式，每个人都要在每个 session 里运行 /fast…",
    "language": "让 Claude 默认用英语之外的语言回答。回答语言没有固定列表：Claude Code 会把取值原样作为「始终用该语言回答」的指令传给 Claude，所以任何 Claude 能读懂的语言名都可用。Claude Code 不检查…",
    "maxEffortLevel": "限制一个 session 可以使用的 effort 等级上限，更低的等级仍然可用。任何更高的等级都会按上限执行，包括来自 /effort、/model 选择器、--effort、CLAUDE_CODE_EFFORT_LEVEL、skill 或 subagent 的 effort frontmatter，以及模型自身默认值的等级。Claude…",
    "model": "设置每个新 session 使用的模型，这样就不必每次都用 /model 挑一个。在这里设置并不妨碍你在 session 中途切换。如果管理员设置了组织默认模型来覆盖用户选择，那么即使你在这个键里设置了别的模型，你得到的仍是那个模型…",
    "modelOverrides": "把 Anthropic 模型 ID 映射到 provider 特定的模型 ID，例如 Amazon Bedrock 推理配置文件 ARN。此后每个模型选择器条目在调用 provider API 时都会使用映射后的值。管理员在 Amazon Bedrock、Google Cloud 的 Agent Platform 和 Microsoft…",
    "modelPicker": "列出 /model 选择器提供的模型，顺序按你写的来，标签由你决定，让选择器在内置阵容之后、或替代内置阵容，列出你的组织实际运行的模型。每一行的模型都按原样使用，因此它接受 --model 接受的一切：一个…",
    "modelSettings": "为你使用的每个模型保存 effort 等级。需要 Claude Code v2.1.251 或更高版本。在你机器上的交互式 session 里，当你用 /effort 或 /model 选择器的 effort 滑杆把 low、medium、high 或 xhigh 保存为默认时，Claude Code 会把该等级写到这里…",
    "outputStyle": "按名称选择输出风格。输出风格是一组保存下来的指令，会改变 Claude 的角色、语气和输出格式，例如内置的 Explanatory 和 Learning 风格，或者你自己写的风格。如果你在 session 中途改这个键，Claude 会立即用新风格…",
    "promptCacheTtl": "选择 prompt 缓存为主对话保留多久。这个键适用于你的交互式、-p 和 Agent SDK 轮次，以及 Claude Code 与它们内联运行的辅助请求。一小时的生命周期能让缓存在较长中断后仍然温热，API 会为每次缓存…",
    "showThinkingSummaries": "在交互式 session 中查看 Claude 扩展思考的摘要。如果你希望用 Ctrl+O 展开思考时看到完整摘要，就设置它。未设置或为 false 时，Anthropic API 会隐去思考块，Claude Code 显示一个折叠的占位；第三方 provider 不会…",
    "subagentPromptCacheTtl": "选择 prompt 缓存为主对话之外、Claude Code 发起的请求保留多久。这个键适用于 subagent、workflow，以及 Claude Code 自己的后台与辅助请求，例如压缩和 session 标题。一小时的生命周期能让缓存保持温热…",
    "switchModelsOnFlag": "选择安全分类器标记某个请求之后会发生什么：切换到 fallback 模型继续，还是暂停下来，让你在切换与修改 prompt 之间选择。",
    "ultracode": "让 session 启动时开启 ultracode。开启后，Claude 会为每个实质性任务规划一个 workflow，而不是等你去要求。只有在为你启用了动态 workflow、且你的模型支持 xhigh effort 时，Claude 才会规划 workflow。这个键不改变 session 的…",
    "autoMode": "为 auto mode 分类器拦截和放行的内容添加你自己的规则。用它告诉分类器你的组织信任哪些仓库、bucket 和域名，从而不再拦截常规的内部操作。分类器自带内置的允许与拒绝规则。包含…",
    "autoMode.classifyAllShell": "在 auto mode 生效期间，让每条 Bash 和 PowerShell 命令都经过 auto mode 分类器。默认情况下，auto mode 只暂停那些可能执行任意代码的允许规则：例如 Bash(*) 这类工具级和通配规则，以及解释器或 shell 包装前缀…",
    "disableAutoMode": "把 auto mode 从 Shift+Tab 循环里移除。任何本来会以 auto mode 启动的 session——无论来自 --permission-mode auto、设置文件还是内置默认值——都会改为以 default 启动。管理员在 managed settings 里设置它，防止其组织里的开发者…",
    "permissions": "控制哪些工具 Claude 不用询问就能使用、哪些总是先提示、哪些被禁止，并设置 session 启动时的权限模式。下面每个 permissions.* 键都嵌套在这个对象里。",
    "permissions.additionalDirectories": "让 Claude 可以访问你启动目录之外的目录，作为额外的工作目录。大多数 .claude/ 配置不会从这些目录里被发现。",
    "permissions.allow": "列出 Claude Code 不经询问就批准的工具调用。在 MCP 规则里，* 只能出现在 mcp__<server>__ 前缀之后的工具名中，例如 mcp__github__get_*，不能出现在 server 名里。",
    "permissions.ask": "列出即使处于本来会直接批准的权限模式（例如 acceptEdits 或 bypassPermissions）也要向你确认的工具调用。在 dontAsk 模式下，Claude Code 会拒绝匹配的工具调用，而不是提示你。",
    "permissions.blockReadsOutsideWorkingDirectories": "阻止 Claude 用 Read、Grep、Glob 和 LSP 工具读取 session 工作目录之外的路径，在所有权限模式下都生效，包括 bypassPermissions。通过 Claude Code 能识别的文件命令（例如 cat）读取匹配路径的 Bash 命令会提示…",
    "permissions.defaultMode": "设置新 session 启动时使用的权限模式。不设置时，session 以你所处界面的内置默认模式启动。",
    "permissions.deny": "列出 Claude Code 禁止的工具调用。用它保护存放 API key、密钥或环境变量值的文件：Claude Code 会把匹配的文件排除在文件发现和搜索结果之外，拒绝读取它们，并阻止对匹配路径使用 Edit 和 Write 工具。Read 和 Edit…",
    "permissions.disableBypassPermissionsMode": "阻止任何人进入 bypassPermissions 模式。Claude Code 随后会拒绝 --dangerously-skip-permissions 标志，并忽略 agent 定义里的 permissionMode: bypassPermissions，于是 subagent 按父 session 的权限模式运行。",
    "skipAutoPermissionPrompt": "跳过 Claude Code 在你第一次自己进入 auto mode 时显示的那条一次性说明——例如通过你自己的设置或模式选择器进入，而不是由内置默认值让 session 以它启动。Claude Code 只显示该说明一次，然后…",
    "skipDangerousModePermissionPrompt": "跳过 Claude Code 在 session 进入 bypassPermissions 模式之前显示的确认对话框，无论来源是 --dangerously-skip-permissions 还是 defaultMode: 'bypassPermissions'。你接受过一次该对话框后，Claude Code 会在你的用户设置里把这里写成 true。",
    "useAutoModeDuringPlan": "选择 Claude Code 是否用 auto mode 分类器审查计划模式下的 shell 命令。默认为 true 时，只要 auto mode 可用，分类器就会在规划期间审查每条命令，你不会看到提示，关键路径上的删除除外。设为 false 会得到…",
    "agent": "把主线程作为指定的 subagent 运行，这样 Claude Code 会把该 subagent 的系统 prompt、工具限制和模型应用到你的 session。同一个键也为从 claude agents 派发的 session 设置默认 agent。",
    "crossSessionInbound": "选择这个 session 如何处理来自你其它 Claude Code session 的消息。没有适用取值时，Claude Code 会按两个 session 的权限模式类别逐条判断。需要 Claude Code v2.1.224 或更高版本。",
    "disableAgentView": "关闭后台 agent 和 agent 视图：claude agents、--bg、/background 以及按需 supervisor。在 managed settings 里设置它，可为整个组织强制生效。",
    "isolatePeerMachines": "在 Claude 的 SendMessage 触达你这台机器之外的某个 session 之前，要求你明确批准；见「跨机器消息需要批准」。即使处于 bypassPermissions 模式也会出现批准提示。",
    "processWrapper": "在 macOS 和 Linux 上，在 Claude Code 启动的后台进程前面放一个企业启动器命令。Claude Code 会把自己的命令行追加到启动器后面运行，所以启动器必须 exec 进入 Claude Code；见「在企业启动器后面运行 Claude Code」…",
    "teammateMode": "选择 Claude Code 在哪里显示 agent team 的队友：你的主终端窗格内，还是终端支持时的分屏。见「选择显示模式」。",
    "worktree": "配置 Claude Code 如何为 --worktree、EnterWorktree 工具以及隔离的 subagent 和后台 session 创建和管理 git worktree。",
    "worktree.baseRef": "选择新 worktree 从哪个 ref 分叉。'fresh' 从 origin/<默认分支> 分叉，得到与远端一致的干净工作树；'head' 从你当前的本地 HEAD 分叉，因此未推送的提交和功能分支状态都会出现在 worktree 里。",
    "worktree.bgIsolation": "选择后台 session 如何隔离它们的文件修改。取值为 'worktree' 时，Claude Code 在 session 调用 EnterWorktree 之前阻止在主检出里使用 Edit 和 Write；取值为 'none' 时，后台任务直接修改工作副本。对于 git worktree…的仓库，设为 'none'。",
    "worktree.sparsePaths": "通过 git sparse-checkout 只检出每个 worktree 里列出的目录。Claude Code 只把这些目录和根级文件写到磁盘，在大型 monorepo 里更快；见「只检出你需要的目录」。",
    "worktree.symlinkDirectories": "把主仓库里的目录软链到每个 worktree，这样就不必在磁盘上重复占用大目录。",
    "allowedMcpServers": "允许人们添加哪些 MCP server 的允许列表。任何不匹配条目的 server，无论定义在哪里都会被 Claude Code 阻止，包括 plugin server、用 --mcp-config 传入的 server，以及来自 claude.ai 的 server。内置 server，例如 Claude in Chrome、ide server…",
    "deniedMcpServers": "阻止特定的 MCP server。匹配的 server 无论定义在哪里，Claude Code 都拒绝加载，包括 plugin server、用 --mcp-config 传入的 server、来自 managed-mcp.json 的 server、来自 managedMcpServers 的 server，以及它自己去拉取的 claude.ai 连接器。进程内…",
    "disableClaudeAiConnectors": "关闭 Claude Code 自己去拉取的 claude.ai MCP 连接器，使它既不拉取也不连接它们。任何设置文件里的 true 都会生效：仓库里签入的项目 .claude/settings.json 可以让这个仓库退出这些连接器，但项目级的 false 无法覆盖…",
    "disabledMcpjsonServers": "拒绝项目 .mcp.json 文件里定义的特定 server，使 Claude Code 永不连接它们、也不请求你批准。任何设置文件里的拒绝都会生效，包括签入仓库的项目 .claude/settings.json。",
    "enableAllProjectMcpServers": "不提示就批准项目 .mcp.json 文件里定义的所有 MCP server。当你在批准对话框里选择批准全部 server 时，Claude Code 会把这个键写入 .claude/settings.local.json。",
    "enabledMcpjsonServers": "批准项目 .mcp.json 文件里定义的特定 server，使 Claude Code 不经询问就连接它们。当你在批准对话框里批准某个 server 时，Claude Code 会把这个键写入 .claude/settings.local.json。",
    "disableBundledSkills": "关闭 Claude Code 随附的 skills 和 workflow。Claude Code 会完全移除随附的 skills 和 workflow，而 /init 这类内置命令仍然可以输入，只是对模型隐藏。",
    "disableSkillShellExecution": "关闭来自用户、项目、plugin 或额外目录来源的 skills 与自定义命令里 !... 和 ! 块的内联 shell 执行。Claude Code 会把每条命令替换为 [shell command execution disabled by policy]，而不是运行它。",
    "enabledPlugins": "按 plugin-name@marketplace-name 为键单独开关 plugin。在任何作用域都没有条目的 plugin 会回落到它的 defaultEnabled 值。当你用 /plugin 或 claude plugin enable 启用或禁用某个 plugin 时，Claude Code 会替你写这个键。",
    "extraKnownMarketplaces": "按名称注册额外的 plugin 市场，这样打开这个仓库的人、或你的 managed settings 覆盖到的所有人，都不必自己添加就能得到该市场。Claude Code 会注册每个它还不认识的市场。某个 plugin 是否…",
    "pluginConfigs": "保存你在 plugin 的 userConfig 配置对话框里给出的非敏感答案，以 plugin ID 为键。你在对话框里填写时，Claude Code 会把这个键写入你的用户设置，所以不必手动编辑它。Claude Code 把敏感选项存储在 macOS…",
    "skillOverrides": "不编辑 skill 的 SKILL.md 就隐藏或折叠它。Claude Code 会把每个 skill 名称下的值应用到它看到的 skill 列表和你的 / 自动补全上。",
    "syncClaudeAiPlugins": "关闭为你的 claude.ai 账号启用的 plugin 的下载。在你用 claude.ai 账号登录的终端 session 和 Cowork session 开始时，Claude Code 会把它们下载到 ~/.claude/plugins/synced/，并把每个都作为 <name>@synced 加载。设…",
    "syncClaudeAiSkills": "关闭为你的 claude.ai 账号启用的 skills 的下载。在你用 claude.ai 账号登录的终端 session（交互式或非交互式）以及 Cowork 和 cloud session 里，Claude Code 会把它们下载到 ~/.claude/skills/synced/。设 false…",
    "allowedHttpHookUrls": "限制 HTTP hook 可以访问哪些 URL。当你定义了这个键，只有当 HTTP hook 的 URL 匹配其中一个模式时 Claude Code 才运行它，其余的一律阻止、不运行；空数组会阻止所有 HTTP hook。",
    "disableAllHooks": "关闭 hook、任何自定义状态栏，以及任何自定义文件建议命令。用它临时关掉这一切，而不必从设置里删除它们。",
    "disableWorkflows": "为你的设置覆盖到的所有人关闭动态 workflow 和随附的 workflow 命令，例如组织通过 managed settings 下发。如果你只想为自己开关 workflow，请改用 enableWorkflows，/config 里的 **Dynamic workflows** 开关写的就是这个键…",
    "enableWorkflows": "当你所在套餐的默认值不合意时，为自己开关动态 workflow。它在 /config 里显示为 **Dynamic workflows**，开启时把这个键写入你的用户设置，切回套餐默认时再移除它。要为其它人关闭 workflow…",
    "hooks": "在 Claude Code 生命周期的各个节点（例如工具调用之前、session 启动时）把你自己的命令、prompt、agent、HTTP 请求或 MCP 工具作为 hook 运行；hooks 参考列出了每个事件、它的负载和退出码。每个事件映射到一个 matcher…",
    "httpHookAllowedEnvVars": "HTTP hook 可以把环境变量的值放进请求头，例如 Authorization: Bearer $HOOK_TOKEN 头，但只能用于该 hook 在自己的 allowedEnvVars 里列出的变量。这个键为所有 HTTP hook 给那份列表设一个外层上限：hook 可以…",
    "workflowKeywordTriggerEnabled": "选择在 prompt 里输入关键词 ultracode 是否触发动态 workflow。设为 false 可以只是打出这个词而不触发。",
    "workflowSizeGuideline": "设置 Claude 在它编写的动态 workflow 里瞄准的 agent 数量。Claude Code 把这个值作为建议而不是强制上限发给 Claude：'small' 要求少于 5 个 agent，'medium' 少于 10 个，'large' 少于 50。当你想约束一个…时选 'small'。",
    "agentPushNotifEnabled": "允许 Claude 在它认为值得时给你的手机发推送通知，例如一个长任务完成时。Claude Code 会把这个选择同步到你的账号，推送在 Remote Control 连接期间到达。在 /config 里显示为 **Push when Claude…**。",
    "awaySummaryEnabled": "当你离开几分钟后回到终端时，显示一行 session 回顾。设为 false，或在 /config 里关掉 **Session recap**，即可停止回顾。",
    "disableArtifact": "<Warning> 已废弃，由 enableArtifact 取代。Claude Code 仍把 disableArtifact: true 视为等价于 enableArtifact: false，并忽略 disableArtifact: false。</Warning> 请改用 enableArtifact 关闭 Artifact 工具，该工具把 session 输出发布为…",
    "disableDeepLinkRegistration": "阻止 Claude Code 向操作系统注册 claude-cli:// 协议处理器，否则它会在你发出交互式 session 的第一条 prompt 后注册。深链接让外部工具能带着预填 prompt 打开 Claude Code session。在…里设置它。",
    "disableRemoteControl": "关闭 Remote Control：Claude Code 随后会拒绝 claude remote-control、--remote-control 标志、自动启动和 session 内开关，并报告你的组织策略已禁用它。在 managed settings 里设置它，以便按设备做 MDM 强制。",
    "enableArtifact": "关闭 Artifact 工具，该工具把 session 输出发布为 claude.ai 上的私有网页。当你在 /config 里关掉 **Artifacts** 一行时，Claude Code 会把这个键写入你的用户设置，所以通常不必手动编辑它。需要 Claude Code v2.1.196 或更高版本。",
    "inputNeededNotifEnabled": "当有权限提示或问题在等待你输入时，在你的手机上收到推送通知。Claude Code 只在 Remote Control 连接期间发送这些通知。在 /config 里显示为 **Push when actions required**。",
    "preferredNotifChannel": "选择任务完成或有权限提示在等待时，Claude Code 如何通知你。在 /config 里显示为 **Local notifications**。",
    "remote.defaultEnvironmentId": "为你在 CLI 里创建的 cloud session（例如用 claude --cloud）挑选默认 cloud 环境。当你用 /remote-env 选择环境时，Claude Code 会把这个键写入你的用户设置。",
    "remoteControlAtStartup": "每个交互式 session 启动时自动连接 Remote Control，而不是等待 /remote-control。设为 true 开启自动连接，设为 false 关闭。在 /config 里显示为 **Enable Remote Control for all sessions**。",
    "sshConfigs": "把 SSH 连接加入 Desktop 环境下拉列表。管理员用它给团队分发共享连接。你在 managed settings 里定义的连接会显示为 managed，用户可以选择它们，但不能在应用里编辑或删除。",
}

MISSING_ZH = []


def parse_index(text):
    """key -> (short description, topic, scope) from the index table."""
    out = {}
    for line in text.split("\n"):
        if not line.startswith("| [`"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 4:
            continue
        key = re.match(r"\[`(.+?)`\]", cells[0])
        if key:
            out[key.group(1)] = (cells[1], cells[2], cells[3])
    return out


def parse_sections(text):
    """key -> {type, default, help} from the per-key sections."""
    out = {}
    parts = re.split(r"\n### `(.+?)`\n", text)
    for index in range(1, len(parts) - 1, 2):
        key, body = parts[index], parts[index + 1]
        type_match = re.search(r"\* \*\*Type\*\*: (.+)", body)
        default_match = re.search(r"\* \*\*Default\*\*: (.+)", body)
        prose = []
        for line in body.split("\n"):
            stripped = line.strip()
            if stripped.startswith(("*", "```", ">")):
                break
            if stripped:
                prose.append(stripped)
        out[key] = {
            "type": type_match.group(1).strip() if type_match else "",
            "default": default_match.group(1).strip() if default_match else "",
            "help": " ".join(prose)[:600],
        }
    return out


def clean_help(text, limit=280):
    """Markdown links to their text, whitespace collapsed, cut at a word."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text.replace('"', "'")
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut.rstrip(",.;:") + "…"


def chinese_help(key, english):
    """The Chinese sentence for a key, or the English one plus a loud warning."""
    zh = HELP_ZH.get(key)
    if zh is None:
        MISSING_ZH.append(key)
        return english
    return zh


def swift_string(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{escaped}"'


def both(zh, en):
    return f".both(zh: {swift_string(zh)}, en: {swift_string(en)})"


def classify(type_text):
    lowered = type_text.lower()
    options = re.findall(r"`([A-Za-z0-9_.-]+)`", type_text)
    if lowered.startswith("boolean"):
        return "bool", options
    if "array of" in lowered or lowered.startswith("list of"):
        return "list", []
    if lowered.startswith(("number", "integer")):
        return "int", []
    if lowered.startswith(("object", "map of")):
        return "json", []
    if lowered.startswith("string") and ("one of" in lowered or "either" in lowered) and options:
        return "choice", options
    return "text", []


def fallback_literal(kind, default_text):
    stripped = default_text.strip().lower()
    if kind == "bool":
        if stripped.startswith("`true`") or stripped == "true":
            return "true"
        return "false"
    if kind == "int":
        digits = re.search(r"`?(\d+)`?", default_text)
        return digits.group(1) if digits else "nil"
    if kind == "choice":
        options = re.findall(r"`([A-Za-z0-9_.-]+)`", default_text)
        return options[0] if options else ""
    return ""


def emit_field(kind, key, help_zh, help_en, meta, options, scope_note):
    """One field, one statement, four lines: the point is that a reviewer can
    read the two languages side by side without unfolding a paragraph."""
    label = both(key, key)
    head = f'\t\t\t\t\t{kind}Field(\n\t\t\t\t\t\t{swift_string(key)}, {label}'
    middle = ""
    tail = []
    if kind == "bool":
        middle = f", fallback: {fallback_literal('bool', meta.get('default', ''))}"
    elif kind == "int":
        middle = f", fallback: {fallback_literal('int', meta.get('default', ''))}"
    elif kind == "choice":
        opts = ", ".join(swift_string(o) for o in options)
        fallback = fallback_literal("choice", meta.get("default", "")) or options[0]
        middle = f", options: [{opts}], fallback: {swift_string(fallback)}"
    elif kind == "text":
        middle = ', ""'
    if scope_note:
        tail.append(f"scope: {both(scope_note[0], scope_note[1])}")
    tail_text = (",\n\t\t\t\t\t\t" + ", ".join(tail) + ",") if tail else ""
    return (
        head
        + middle
        + ",\n\t\t\t\t\t\t"
        + both(help_zh, help_en)
        + tail_text
        + "\n\t\t\t\t\t),"
    )


def main():
    text = open(SOURCE, encoding="utf-8").read()
    index = parse_index(text)
    sections = parse_sections(text)

    # Only keys a user can set in `~/.claude/settings.json`; managed-only and
    # `~/.claude.json`-only keys are not editable there and would be read-only
    # noise in the pane.
    grouped = {}
    for key, (description, topic, scope) in index.items():
        if scope.strip() == "Managed" or "Global config" in scope:
            continue
        if "Managed" in scope and "Any file" not in scope and "User" not in scope:
            continue
        grouped.setdefault(topic, []).append((key, description, scope, sections.get(key, {})))

    order = [title for title, _, _, _ in TOPICS]
    icons = {title: icon for title, _, _, icon in TOPICS}
    titles = {title: (zh, en) for title, zh, en, _ in TOPICS}

    # A topic the reference renamed used to disappear in silence, taking every
    # key under it with it. Say it out loud instead.
    unmapped = {topic: keys for topic, keys in grouped.items() if topic not in order}
    if unmapped:
        detail = ", ".join(f"{topic!r} ({len(keys)})" for topic, keys in sorted(unmapped.items()))
        dropped = sum(len(keys) for keys in unmapped.values())
        print(
            f"!! {dropped} key(s) in {len(unmapped)} topic(s) are not in TOPICS and were skipped: {detail}",
            file=sys.stderr,
        )

    print("// Generated by Tools/make-claude-schema.py from the upstream settings")
    print("// reference. Do not edit by hand; re-run the script after an upgrade.")
    print("//")
    print("// Labels are the literal JSON keys — the key identifies the setting in")
    print("// ~/.claude/settings.json, so naming it in Chinese would hide which key is")
    print("// being edited. They are written as a zh/en pair rather than a plain string")
    print("// so that no shipped schema carries a value in one language only.")
    print("")
    print("import Foundation")
    print("")
    print("extension SettingsSchema {")
    print("\tpublic static let claudeCode = SettingsSchemaDefinition(")
    print('\t\tid: "claude-code",')
    print(f"\t\ttitle: {both('Claude Code 设置', 'Claude Code settings')},")
    print("\t\tsections: [")

    total = 0
    for topic in order:
        entries = grouped.get(topic)
        if not entries:
            continue
        section_id = "claude-" + re.sub(r"[^a-z]+", "-", topic.lower()).strip("-")
        zh_title, en_title = titles[topic]
        print("\t\t\tSettingsSection(")
        print(f"\t\t\t\tid: {swift_string(section_id)},")
        print(f"\t\t\t\ttitle: {both(zh_title, en_title)},")
        print(f"\t\t\t\ticon: {swift_string(icons.get(topic, 'gear'))},")
        print("\t\t\t\tfields: [")
        for key, description, scope, meta in sorted(entries):
            kind, options = classify(meta.get("type", ""))
            english = clean_help(meta.get("help") or description)
            scope_note = None
            if "Managed" in scope and "Any file" not in scope:
                scope_note = (
                    "只对 Managed（组织下发）有意义",
                    "Only meaningful for managed (organization-distributed) settings",
                )
            print(emit_field(kind, key, chinese_help(key, english), english, meta, options, scope_note))
            total += 1
        print("\t\t\t\t]\n\t\t\t),")

    print("\t\t]\n\t)")
    print("}")
    print(f"// generated {total} keys across {len(grouped)} topic(s)", file=sys.stderr)

    if MISSING_ZH:
        print(
            f"!! no Chinese help for {len(MISSING_ZH)} key(s); add them to HELP_ZH: "
            + ", ".join(sorted(MISSING_ZH)),
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
