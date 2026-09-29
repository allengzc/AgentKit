# AgentKit

一个原生 macOS GUI，用来配置和管理本地的 coding agent。

现在支持 **pi**（`@earendil-works/pi-coding-agent`）：模型、MCP、Skills、会话、
全局指令、子 agents、通用设置、主题/扩展/Packages，八个面板。
**支持哪个 agent 由一份 JSON 描述文件决定** —— 加一个新 agent = 加一个 JSON，不改代码。

![通用设置](docs/settings.png)

---

## 为什么是描述文件驱动的

本地 coding agent 的配置从来不是"一个文件"。以 pi 为例：

| 配置面 | 真实位置 |
|---|---|
| 设置 | `~/.pi/agent/settings.json`（约 68 个键、9 个分组） |
| 模型 | `~/.pi/agent/models.json`（provider + model），`models-store.json` 只是缓存 |
| MCP | **六层**配置按优先级合并，另有 7 种其它工具的配置可导入 |
| Skills | `<根>/skills/`、`~/.agents/skills/`（含符号链接），项目 `.pi/skills/` |
| 会话 | `<根>/sessions/<cwd 分组>/*.jsonl`（tree 结构，JSONL） |
| 指令 | `AGENTS.override.md` / `AGENTS.md` / `SYSTEM.md` / `APPEND_SYSTEM.md`，加上沿途的项目级文件 |
| 子 agents | `<根>/agents/*.md`（frontmatter + 正文） |

把这些硬编码进一个 App，等于每支持一个新 agent 就重写一遍。AgentKit 的做法是：

- **描述文件（数据）** 声明路径、层次、形状；
- **面板处理器（代码）** 是一组有限且封闭的形状：`typed-json`、`providers-map`、
  `mcp-servers-map`、`skill-dirs`、`jsonl-sessions`、`md-frontmatter`、`md`；
- 描述文件引用到本版本不认识的 `kind`，那个面板降级成占位符，**其它面板照常可用，不崩**。

内置的 `pi.json` 在 [`Resources/Agents/pi.json`](Resources/Agents/pi.json)，
可以当作写新描述文件的模板。

---

## 快速开始

```bash
./build.sh          # 编译到 out/AgentKit.app（只需要 swiftc）
./install.sh        # 再复制到 /Applications/AgentKit.app 并提示入口
./run-tests.sh      # 308 项离线断言，不需要窗口、不需要网络
```

要求：macOS 14+、Xcode 命令行工具（Swift 6.x）、一个用于签名的 Apple Development
证书（可用 `AGENTKIT_SIGN_IDENTITY` 覆盖）。

打开方式：

```bash
open -a AgentKit
AGENTKIT_OPEN=pi/mcp open -a AgentKit          # 直接进某个面板
PI_CODING_AGENT_DIR=/tmp/fixture open -a AgentKit   # 换一个配置根（夹具优先调试）
```

---

## 八个面板

### 模型与 Provider

![模型](docs/models.png)

从 `models.json` 读 provider 与 model；`models-store.json` 只读，用来补全上下文
窗口等详情。`apiKey` **只显示"已配置"**：AgentKit 从不读取、显示或记录密钥明文，
检查认证走 `pi auth check --provider X --json --no-refresh`。
编辑 provider 是**合并**而不是替换，`compat`、`headers` 这类 AgentKit 不认识的键原样保留。

### MCP 服务器

![MCP](docs/mcp.png)

按优先级合并全部配置层，标出每个服务器的**来源层**与**被覆盖的层**。
它还会指出"看起来配好了其实已经死了"的文件 —— 例如本机真实存在的情况：

```
/Users/dev/.pi/agent/mcp.json 已经不会被读取
pi-mcp-adapter 已经不再读取这个文件：生效的是 ~/.config/mcp/mcp.json（共享全局层）。
```

上图是本机的真实案例（已修复）：`imports` 迁到了 `mcp-adapter.json`，
`mcpServers` 并入共享全局层，死文件改名为 `mcp.json.bak-agentkit-*`。之后诊断徽标消失。

一键修复是一个**分步计划**（迁移 adapter 专属键 → 并入服务器 → 重命名旧文件），
每一步的 diff 都展示在确认页里，任何一步失败就停下。

### Skills

![Skills](docs/skills.png)

递归查找 `SKILL.md`，**穿过符号链接**（一个链接到别处仓库的 skill 目录也能正常列出），同时剪掉 `.git` / `node_modules` / `.venv` / `logs` 这类目录并限制
深度。校验规则对齐 pi：缺 `description` 即"不会被加载"，`name` 必须符合 Agent
Skills 规范。

### 会话

![会话](docs/sessions.png)

列表只用每个文件的**第一行**（header），消息数 / token / 成本由后台流式统计并按
`(大小, mtime)` 缓存，所以 143 个会话也能秒开。支持搜索、按项目或按时间分组、
在终端恢复、导出 HTML、重命名、移到废纸篓。

### 全局指令 / 子 Agents / 通用设置 / 主题 · 扩展 · Packages

![子 Agents](docs/subagents.png)

- **全局指令**：Markdown 编辑 + 预览，列出 override / instructions / SYSTEM / APPEND_SYSTEM
  的生效关系，并从项目目录向上发现沿途命中的 `AGENTS.md`。
- **子 Agents**：frontmatter 表单（name / description / model / tools）+ 正文编辑，
  `model` 会对着当前模型列表校验；`tools: read, grep` 这种逗号写法原样保留。
- **通用设置**：按官方 settings 文档逐键生成的表单，含类型、枚举、范围与默认值，
  标注"只能写在 agent 目录级别"的键，未收录的键进入只读的"其它键（保留）"区。
- **主题 · 扩展 · Packages**：沿用 pi 的 `.off` 后缀约定做启用/停用，Packages 区读
  `settings.packages` 并可运行 `pi list` 核对。

---

## 写入安全

这是这个工具最不能出错的地方，所以所有写入都收敛到同一条路径：

1. **读**：记下 `(大小, mtime, sha256)`。JSON 解析失败 → 该文件全部编辑入口禁用，
   只提供原文视图与外部编辑器，**绝不覆盖**。
2. **改**：在保序、保留未知键的 JSON 树上做点号路径合并。
3. **写**：先把改动渲染成文本，再走同目录临时文件 → `fsync` → `rename` 原子替换，
   并保留原文件权限（`models.json` / `auth.json` 是 0600，写回后仍是 0600）。
4. **外科式修改**：改动只有一个或多个叶子值时，AgentKit 把新字面量**拼接进原始字节**，
   不改动任何没碰过的行 —— 包括你自己写成一行的那种对象。只有结构性改动
   （增删键、数组长度变化）才整体重写。
5. **备份**：写入前在同目录生成 `<文件>.bak-agentkit-YYYYMMDD-HHMMSS`，每个文件保留 10 份。
6. **确认**：任何写入都先弹 diff，确认才落盘。
7. **并发**：落盘前比对 sha256，不一致就中止并提示"文件已被外部（很可能是 pi）改动"。
8. **运行中提示**：检测到 agent CLI 在跑就提示改动需要 `/reload` 或重启；会话重命名
   这类会改写进行中文件的动作直接禁用。
9. **护栏**：解析后的写入路径必须落在描述文件声明的 `scopeGuard` 内。

会话重命名是唯一会改会话文件的操作，做法与 pi 的 `/name` 一致：追加一条
`session_info` 记录，前置条件是 agent 未在运行 + 先生成备份。

### 夹具优先

开发与验收都先对着副本跑，确认无误再碰真实配置：

```bash
rsync -a ~/.pi/agent/ /tmp/agentkit-fixture/agent/
PI_CODING_AGENT_DIR=/tmp/agentkit-fixture/agent \
AGENTKIT_CONFIG_DIR=/tmp/agentkit-fixture/config \
  ./out/AgentKit.app/Contents/MacOS/AgentKit
```

---

## 描述文件

放在 `~/.config/agentkit/agents/*.json`（可用 `AGENTKIT_CONFIG_DIR` 覆盖）。
`id` 与内置相同的会**整体覆盖**内置那一份，侧边栏会标「自定义描述」。

```jsonc
{
  "descriptorVersion": 1,
  "id": "pi",
  "name": "Pi",
  "subtitle": "@earendil-works/pi-coding-agent",
  "icon": "terminal.fill",

  "root": { "env": "PI_CODING_AGENT_DIR", "default": "~/.pi/agent" },

  "detect": {
    "paths": ["~/.pi", "~/.pi-desktop"],
    "cli": {
      "name": "pi",
      "package": "@earendil-works/pi-coding-agent",
      "loginShellLookup": true,
      "candidates": ["~/.nvm/versions/node/*/bin/pi", "/opt/homebrew/bin/pi"]
    }
  },

  "write": {
    "backup": { "suffix": ".bak-agentkit", "keep": 10 },
    "scopeGuard": ["$ROOT", "$HOME", "/tmp"]
  },

  "surfaces": [
    { "id": "settings", "kind": "settings", "title": "通用设置",
      "file": "$ROOT/settings.json", "schema": "pi-settings-0.87" },

    { "id": "mcp", "kind": "mcp", "title": "MCP 服务器",
      "layers": [ { "path": "~/.config/mcp/mcp.json", "precedence": 10, "shared": true, "writable": true } ],
      "legacy": [ { "path": "$ROOT/mcp.json", "notice": "…", "fix": { "action": "rename", "to": "$ROOT/mcp-adapter.json" } } ] },

    { "id": "skills", "kind": "skills", "title": "Skills",
      "roots": [ { "path": "$ROOT/skills", "scope": "user", "writable": true } ],
      "ignore": [".git", "node_modules", ".venv"], "maxDepth": 6 }
  ]
}
```

路径 token：`~`、`$ROOT`（agent 根）、`$CWD`（当前项目）、`$APP`（AgentKit 支持目录）、
`$HOME`。`*` 只允许出现在 `cli.candidates`，并且按版本号取最高的那个。

`settings` 面板的 `schema` 指向一份**内置的强类型字段表**（`pi-settings-0.87`，
按 pi 官方 settings 文档逐键编写）。想更简单地接一个 agent，也可以在描述文件里用
其它形状（`providers-map`、`md-frontmatter`、`md`、`jsonl-sessions`）而完全不写代码。

写坏了不会崩：侧边栏会给出解析失败的原因，其它 agent 照常可用。

---

## 环境变量

| 变量 | 作用 |
|---|---|
| `PI_CODING_AGENT_DIR` | 覆盖 pi 的配置根（描述文件里 `root.env` 声明） |
| `AGENTKIT_CONFIG_DIR` | 覆盖描述文件目录（默认 `~/.config/agentkit`） |
| `AGENTKIT_OPEN=pi/mcp` | 启动直接进指定 agent 的指定面板 |
| `AGENTKIT_SIGN_IDENTITY` | 构建时指定签名身份 |
| `AGENTKIT_TARGET` | 构建目标三元组，默认 `arm64-apple-macosx14.0` |

日志：

```bash
log show --last 5m --info --predicate 'subsystem == "com.allengzc.agentkit"'
```

---

## 已知限制

- **只支持 pi**。架构已经为其它 agent 留好接口（描述文件 + 7 种形状 + 内置 schema
  机制），但 v1 只内置了 pi 这一份。
- **Skills 的启用/停用是 AgentKit 自己的约定**（把目录移到同级 `.disabled/`），
  因为 pi 没有单个 skill 的开关，只有全局的 `enableSkillCommands`。界面里写明了这一点。
- **不接管密钥**：`apiKey` 仍在 `models.json` / `auth.json` 里，AgentKit 只做掩码显示。
- **会话重命名**会向会话文件追加一行；agent 在运行时会禁用这个操作。
- **Packages 只读**：`settings.packages` 的增删请用 `pi install` / `pi remove`。
- **不做 schema 漂移自动合并**：pi 升级后新增的设置键会落到"其它键（保留）"里，
  AgentKit 不会猜它的含义。
- App 不做沙盒（必须读写 `~/.pi`、`~/.config`、`~/.agents` 并拉起终端）；
  项目目录落在 `~/Documents`、`~/Desktop`、`~/Downloads` 时首次访问会触发系统授权弹窗。

---

## 目录结构

```
Sources/Core/        JSON 树与无损读写、路径解析、描述文件、Markdown/frontmatter、进程
Sources/Surfaces/    各面板的纯逻辑（无 UI）：MCP 合并、会话解析、skills 扫描、设置 schema
Sources/App/         状态、写入控制器、Finder/终端动作
Sources/Views/       SwiftUI 界面
Resources/Agents/    内置描述文件
Tests/main.swift     离线断言
```

## License

MIT © 2026 allengzc
