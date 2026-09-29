# AgentKit

**一个原生 macOS GUI，用描述文件驱动地配置和管理本地 coding agent。**

[中文](README.md) · [English](README.en.md)

现支持三个 agent：

| Agent | 配置根 | 覆盖的面板 |
|---|---|---|
| **pi**（`@earendil-works/pi-coding-agent`） | `~/.pi/agent` | 模型与 Provider、MCP、Skills、会话、全局指令、子 Agents、通用设置、主题/扩展/Packages |
| **Codex**（`codex-cli`） | `~/.codex` | 模型与 Provider、MCP、Skills、会话、全局指令、通用设置 |
| **Claude Code**（`claude`） | `~/.claude` | MCP、Skills、子 Agents、会话、全局指令、通用设置 |

**支持哪个 agent 由一份 JSON 描述文件决定** —— 加一个新 agent = 加一个 JSON，不改代码。
三个 agent 的字段差异怎么被一张表兜住 → [描述文件](docs/descriptors.md)。

![pi 的通用设置面板](docs/settings.png)

> 截图由 `Tools/make-demo.py` 造的一套假配置渲染而来：provider、会话、skill、项目路径
> 全是编的，**不来自任何人的真实机器**。重新生成 → [截图流水线](docs/development.md#截图流水线)。

> 改这个仓库的代码请先读 [`AGENTS.md`](AGENTS.md)（根规范 + 各目录一份）。本页给使用者。

---

## 快速开始

```bash
./build.sh          # 编译到 out/AgentKit.app（只需要 swiftc）
./install.sh        # 再复制到 /Applications/AgentKit.app 并提示入口
./run-tests.sh      # 全部离线断言，不需要窗口、不需要网络
```

要求：macOS 14+、Xcode 命令行工具（Swift 6.x）、一个用于签名的 Apple Development
证书（可用 `AGENTKIT_SIGN_IDENTITY` 覆盖）。

打开方式：

```bash
open -a AgentKit
AGENTKIT_OPEN=codex/mcp open -a AgentKit              # 直接进某个 agent 的某个面板
AGENTKIT_PROJECT=~/code/my-repo open -a AgentKit      # 指定项目作用域
CODEX_HOME=/tmp/fixture open -a AgentKit              # 换一个配置根（夹具优先调试）
```

界面支持**中文 / 英文**：菜单栏「语言」里切换，选择会被记住。默认跟随系统语言。
面板名、按钮、提示、写入失败的原因、描述文件与设置表的标签都会跟着变；
日志和命令行开关名不翻译。

对着假配置跑、断言怎么加、图标与截图流水线 → [开发与验收](docs/development.md)。

---

## 文档

| 想知道 | 去哪 |
|---|---|
| 八个面板各自能做什么 | [面板](docs/panels.md) |
| 写入会不会弄坏我的配置 | [写入安全](docs/safety.md) |
| 描述文件怎么写、怎么加新 agent | [描述文件](docs/descriptors.md) |
| 怎么构建、跑断言、重出截图 | [开发与验收](docs/development.md) |

---

## 环境变量

| 变量 | 作用 |
|---|---|
| `PI_CODING_AGENT_DIR` | 覆盖 pi 的配置根（pi 描述文件里 `root.env` 声明） |
| `CODEX_HOME` | 覆盖 Codex 的配置根 |
| `AGENTKIT_CONFIG_DIR` | 覆盖描述文件目录（默认 `~/.config/agentkit`） |
| `AGENTKIT_HOME=/tmp/demo` | 把 `~` / `$HOME` 重定向到一次性目录，用于对着夹具跑，不碰真实配置 |
| `AGENTKIT_OPEN=codex/mcp` | 启动直接进指定 agent 的指定面板 |
| `AGENTKIT_NO_ACTIVATE=1` | 启动时不抢焦点（窗口照常出现，供脚本化验证用） |
| `AGENTKIT_PROJECT=~/repo` | 指定项目作用域（等价于在工具栏里选项目） |
| `AGENTKIT_DOC_STATE=…` | 生成文档截图用：置入预览/展开/diff、固定外观与窗口尺寸、让 App 渲染自身并退出 |
| `AGENTKIT_SIGN_IDENTITY` | 构建时指定签名身份 |
| `AGENTKIT_TARGET` | 构建目标三元组，默认 `arm64-apple-macosx14.0` |

日志：

```bash
log show --last 5m --info --predicate 'subsystem == "com.allengzc.agentkit"'
```

---

## 已知限制

摘要，逐条详情在链接的专题页里，不藏。

- **选了项目之后三列可能错位（未修好）**：项目目录里**真的有配置**时，窗口内容会被
  布局得比窗口高（实测：窗口 1100×874，`RootView` 被布局成 1516 高并垂直居中），
  于是三列各自把底部内容画在顶部。空目录不触发，没有项目也不触发。
  根因**未找到** —— 已确认的是「内容的理想高度超过了窗口」，但还没定位到是哪一块
  内容把它撑高的。临时办法：不选项目，或把窗口拉高一些（能减轻但不会消失）。
- **项目作用域要手动选**：GUI 程序没有"当前工作目录"这种有意义的默认值，AgentKit 不去猜 —— [面板](docs/panels.md#项目作用域)。
- **TOML 的结构性改动不是逐字节的**：顶层增删键整份重写，注释会丢，确认页会明说 —— [写入安全](docs/safety.md#结构改动按格式分级)。
- **不接管密钥**：`apiKey` / `env_key` / `auth.json` 一律只做掩码显示 —— [写入安全](docs/safety.md#不接管密钥)。
- **`~/.claude.json` 既是配置也是状态**：claude 几乎每次都改写它，所以写入被拒绝的概率比别的文件高 —— [写入安全](docs/safety.md#被拒绝写入概率更高的文件)。
- **Codex 的会话重命名不支持**：名字存在单独的索引文件里，AgentKit 不代写 —— [面板](docs/panels.md#会话)。
- **Claude Code 的 MCP 面板没有开关**；Claude settings 覆盖 78 项、Codex 覆盖 69 项，未收录的键落在只读的「其它键（保留）」；Packages 只读 —— [面板](docs/panels.md#通用设置)。
- **不做 schema 漂移自动合并**：agent 升级后新增的键不会被猜含义 —— [面板](docs/panels.md#通用设置)。
- **换一种配置格式（YAML / INI）要先写代码**：描述文件只是数据，解析器在 Core 里 —— [描述文件](docs/descriptors.md#加一个新-agent-的步骤)。
- **App 不做沙盒**：必须读写 `~/.pi`、`~/.codex`、`~/.config`、`~/.agents` 并拉起终端；
  项目目录落在 `~/Documents` / `~/Desktop` / `~/Downloads` 时首次访问会触发系统授权弹窗。

完整清单：[面板](docs/panels.md#已知限制) · [写入安全](docs/safety.md#已知限制) · [描述文件](docs/descriptors.md#已知限制)。

---

## License

MIT © 2026 allengzc
