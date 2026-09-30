# 描述文件

**描述文件是数据，处理器是代码。** 加一个新 agent = 加一个 JSON，不改代码。
回到 [README](../README.md)。想改描述文件的 schema 本身，先读根 [`AGENTS.md`](../AGENTS.md)。

---

## 为什么是描述文件驱动的

本地 coding agent 的配置从来不是"一个文件"，而且**同一个概念在不同 agent 里形状都不一样**。
三个 agent 摆在一张表里看：

| 配置面 | pi | Codex | Claude Code |
|---|---|---|---|
| 会话头部 | 第一行 | 第一行 | **没有头部行**，`sessionId` 每行都有、`cwd` 只在部分行上 |
| 会话的消息类型 | 一种 | 一种 | **两种**（`user` + `assistant`） |
| token | 每条一个总数 | 累计事件取最后一个 | **四个字段相加**（含两种 cache） |
| 会话名 | 文件内的记录 | 单独的索引文件 | 不保存，所以不能改名 |
| 指令文件 | `AGENTS.md` | `AGENTS.md` | `CLAUDE.md` / `CLAUDE.local.md` |
| MCP 开关 | `disabled` | `enabled` | **没有**，所以这个面板不提供开关 |
| 子 Agents | `~/.pi/agent/agents` | 无 | `~/.claude/agents` |

下面这张表是老的两个 agent 的细节对照：

| 配置面 | pi | Codex |
|---|---|---|
| 格式 | JSON | **TOML**（`config.toml`） |
| provider 容器 | `providers` | `model_providers` |
| 字段拼写 | `baseUrl` / `api` / `apiKey` | `base_url` / `wire_api` / `env_key` |
| MCP 容器 | `mcpServers`（多文件分层） | `mcp_servers`（单文件） |
| 服务器开关 | `disabled = true` | `enabled = false`（**极性相反**） |
| 会话布局 | `sessions/<cwd 分组>/<时间戳>.jsonl` | `sessions/<年>/<月>/<日>/rollout-*.jsonl` |
| 会话字段 | 顶层 `id` / `cwd` | 全部嵌在 `payload` 下 |
| 会话名 | 文件里的 `session_info` 记录 | 单独的 `session_index.jsonl` |
| token 统计 | 每条消息的 `usage`（求和） | `event_msg` 里的累计值（取最后一个） |

把这些硬编码进一个 App，等于每支持一个新 agent 就重写一遍。AgentKit 的做法是：

- **描述文件（数据）** 声明路径、层次、字段名、形状；
- **面板处理器（代码）** 是一组有限且封闭的文件形状：`typed-json`、`providers-map`、
  `mcp-servers-map`、`skill-dirs`、`jsonl-sessions`、`md-frontmatter`、`md`；
- 描述文件引用到本版本不认识的 `kind`，那个面板降级成占位符，**其它面板照常可用，不崩**。

内置描述文件在 [`Resources/Agents/`](../Resources/Agents)：[`pi.json`](../Resources/Agents/pi.json)、
[`codex.json`](../Resources/Agents/codex.json)、[`claude.json`](../Resources/Agents/claude.json)。

---

## 放在哪

放在 `~/.config/agentkit/agents/*.json`（可用 `AGENTKIT_CONFIG_DIR` 覆盖）。
`id` 与内置相同的会**整体覆盖**内置那一份，侧边栏会标「自定义描述」。

**写坏了不会崩**：侧边栏会给出解析失败的原因，其它 agent 照常可用。

---

## 一份描述文件长什么样

```jsonc
{
  "descriptorVersion": 1,
  "id": "codex",
  "name": "Codex",
  "icon": "chevron.left.forwardslash.chevron.right",
  "glyph": "⬡",              // 侧栏头部那个标记里画的字（可不写）
  "tint": "#10A37F",         // 标记的底色，#RRGGBB（可不写）

  "root": { "env": "CODEX_HOME", "default": "~/.codex" },
  "detect": {
    "paths": ["~/.codex"],
    "cli": { "name": "codex", "loginShellLookup": true,
             "candidates": ["~/.nvm/versions/node/*/bin/codex", "/opt/homebrew/bin/codex"] }
  },

  "write": { "backup": { "suffix": ".bak-agentkit", "keep": 10 },
             "scopeGuard": ["$ROOT", "$HOME", "/tmp"] },

  "surfaces": [
    { "id": "settings", "kind": "settings", "title": "通用设置",
      "file": "$ROOT/config.toml", "format": "toml", "schema": "codex-0.157" },

    { "id": "mcp", "kind": "mcp", "title": "MCP 服务器", "format": "toml",
      "serverKey": "mcp_servers",           // 容器名
      "toggleKey": "enabled",               // 开关叫 enabled
      "toggleDisabledValue": false,         // 而且 false 才表示停用
      "layers": [ { "path": "$ROOT/config.toml", "precedence": 10, "writable": true } ] },

    { "id": "sessions", "kind": "sessions", "title": "会话",
      "root": "$ROOT/sessions",
      "sessions": {
        "recursive": true,                  // sessions/年/月/日/
        "headerType": "session_meta",
        "header": { "id": "payload.id", "cwd": "payload.cwd", "timestamp": "timestamp" },
        "index": { "file": "$ROOT/session_index.jsonl", "key": "id", "value": "thread_name" },
        "message": { "type": "response_item", "payload": "payload",
                     "role": "role", "text": "content" } } }
  ]
}
```

**路径 token**：`~`、`$ROOT`（agent 根）、`$CWD`（当前项目）、`$APP`（AgentKit 支持目录）、
`$HOME`。`*` 只允许出现在 `cli.candidates`，并且按版本号取最高的那个。

`icon` 是 SF Symbol，`glyph` / `tint` 只影响侧栏头部那个小标记：`glyph` 优先（pi 的 mark
是字母 π，没有对应的 SF Symbol），`tint` 不是 `#RRGGBB` 就当没写、退回 App 自己的色。
两个键都不写 = 只画 `icon` 的符号。**面板的顺序和图标不由描述文件决定**：顺序按 `kind`
统一（见 [面板](panels.md)），同一个 `kind` 在哪个 agent 里都是同一个图标。

`format` 不写就按扩展名判断（`.toml` → TOML，其余 JSON）。

`write.scopeGuard` 是写入护栏：解析后的目标必须落在这些前缀里，见[写入安全](safety.md)。

---

## 加一个新 agent 的步骤

1. 复制 `Resources/Agents/pi.json` 或 `codex.json`；
2. 改 `id` / `name` / `root`；
3. 按目标 agent 的真实文件结构调整各面板的路径与字段名；
4. 丢进 `~/.config/agentkit/agents/`，重启 App。

不需要重新编译。`settings` 面板的 `schema` 指向一份**内置的强类型字段表**；如果目标
agent 没有对应的 schema，那个面板会显示"找不到 schema"并降级，其它面板照常。

写坏了不会崩：侧边栏会给出解析失败的原因，其它 agent 照常可用。

---

## 已知限制

- **内置三个 agent**（pi、Codex、Claude Code）。架构为其它 agent 留好了接口，但描述文件
  只是数据 —— 如果目标 agent 用了第三种配置格式（YAML / INI），需要先给 Core 加一个解析器。
- **`kind` / `shape` 是封闭集合**：引用到不认识的形状，那个面板降级成占位符，不会崩，
  也不会自动变出新功能。想加形状之前先问：这是真的新形状，还是现有形状缺一个字段？
- **`schema` 是内置的**：新增 agent 若没有对应 schema，`settings` 面板降级，其余面板照常。
- **`*` 通配只在 `cli.candidates` 生效**，路径里别指望通配符。

想知道每个面板对应哪种形状与字段，见[面板](panels.md)。
