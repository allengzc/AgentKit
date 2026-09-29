# AgentKit 规范

给**改这个仓库的人**（包括 agent）看的。使用者文档在 [`README.md`](README.md)。
本页只放**跨目录的原则和索引**；具体规则在各目录自己的文件里，不在这里重复。

一句话：**一个原生 macOS GUI，用描述文件驱动地配置和管理本地 coding agent。**
`pi` / `Codex` / `Claude Code` 三个 agent 共用同一套面板处理器。

---

## 1. 三条不可动的原则

**一、描述文件是数据，处理器是代码。**
加一个新 agent = 加一个 JSON，不改代码。处理器是一组**封闭**的形状：
`typed-json`、`providers-map`、`mcp-servers-map`、`skill-dirs`、`jsonl-sessions`、
`md-frontmatter`、`md`。描述文件引用到不认识的 `kind` / `shape`，那个面板降级成
占位符，**其它面板照常可用**。
→ 想加形状之前先问：这是真的新形状，还是现有形状缺一个字段？

**二、写入安全不可回退。**
所有写盘收敛到一条路径。宁可拒绝写入并说明原因，也不要"尽力而为"地写坏别人的配置。
→ 红线九条在 [`Sources/Core/AGENTS.md`](Sources/Core/AGENTS.md)。

**三、不许崩，尤其是"用户没做什么特别的事"的时候。**
解析不了的配置文件 → 该文件禁用编辑、给原文视图，绝不覆盖。
读不动的东西 → 空状态里说清楚为什么，不要静默消失。

---

## 2. 开工前

```bash
./run-tests.sh      # 760 项离线断言，先跑它建基线（以脚本输出为准）
./build.sh          # swiftc → out/AgentKit.app
./install.sh        # 再拷到 /Applications
```

**任何写操作先对着夹具跑**，别拿真实配置试：

```bash
python3 Tools/make-demo.py                      # 全假配置 → /tmp/agentkit-demo
AGENTKIT_HOME=/tmp/agentkit-demo ./out/AgentKit.app/Contents/MacOS/AgentKit
```

`AGENTKIT_HOME` 让整个 App 把 `~` / `$HOME` 解析到那棵树 —— 这是**产品功能**，
不是测试特权。

---

## 3. 两条最贵的经验

**逻辑不许长在 `Sources/Views` 里。** 那一层测不到，而测不到的代码会带病到用户手上。
判据：**这段能不能写成一条断言？** 能，就不属于 Views。
→ 边界与例外：[`Sources/Surfaces/AGENTS.md`](Sources/Surfaces/AGENTS.md)

**改完 UI 必须渲染出来看，并且让机器验收。** 这一路 4 个 bug 里 3 个是"读代码读不出来"
的；第 4 个（侧栏整列空白）更值得记 —— **我看着截图说"没问题"**，直到把侧栏区域裁出来
量字节，三张图完全一致（3794），才证明三张都是空的。眼睛会被"看起来很正常"骗过。
→ 五个布局陷阱与验收命令：[`Sources/Views/AGENTS.md`](Sources/Views/AGENTS.md)

**不猜，先复现。** 崩溃、布局错位、点击失效都先做最小复现。复现不出来的，
说清是猜的，别把猜测写成结论。渲染出来的现象和代码里的推断冲突时，**以现象为准**。

---

## 4. 三条红线

| 红线 | 细则 |
|---|---|
| **生成的代码不许手改** | 改生成脚本重跑 → [`Tools/AGENTS.md`](Tools/AGENTS.md) |
| **仓库里不许有真实数据** | 真实路径 / 真实配置内容 / 真实截图；截图只能来自夹具 → [`Tools/AGENTS.md`](Tools/AGENTS.md) |
| **写盘只走一条路径** | 备份、哈希比对、按字节替换、`scopeGuard` → [`Sources/Core/AGENTS.md`](Sources/Core/AGENTS.md) |

隐私这条踩过一次：`docs/` 下 13 张截图拍的是真实配置，**已经进了 git 历史**，
后来用 `filter-branch` 重写才清掉。

---

## 5. 目录与文件路由

```
Sources/Core/        JSON/TOML 树、写入、路径解析、描述文件、进程
Sources/Surfaces/    各面板的纯逻辑（无 UI）
Sources/App/         状态、项目作用域、写入控制器
Sources/Views/       SwiftUI 界面（Panes/ 每个面板一个文件）
Resources/Agents/    内置描述文件，一个 agent 一个 JSON
Tools/               构建与验证小工具、夹具生成器、截图脚本
Tests/main.swift     全部断言
docs/                截图（全部由夹具生成）
```

改哪个面板就改 `Sources/Views/Panes/<名字>Pane.swift` + 对应的
`Sources/Surfaces/<名字>Surface.swift`。**新面板先写 Surface 和它的断言，再接 View。**

---

## 6. 提交与文档

- 格式在前面：类型前缀、范围清单、检查脚本、钩子安装都在 [`docs/commits.md`](docs/commits.md)，
  这里只说原则、不抄那张表（抄两处必然漂移）
- 提交信息用中文，**说清为什么这么改，而不是改了什么**（改了什么 diff 里有）；
  修 bug 的带上"根因是什么、怎么证的"
- 一次提交一件事
- 已知限制写进 `README.md` 的「已知限制」，**不藏**。宁可写着"这里没做"，
  也不要让用户撞上一个静默的失败
- 交付时说清哪些是**断言保证**的、哪些是**截图确认**的、哪些**没验** →
  [`Tests/AGENTS.md`](Tests/AGENTS.md)
- 规范与代码不一致时：**指出来**，不要默默照其中一方做。
  这条规范本身也可以被质疑和修改

---

## 分目录规则

- [`Sources/Core/AGENTS.md`](Sources/Core/AGENTS.md) — 写入安全红线
- [`Sources/Surfaces/AGENTS.md`](Sources/Surfaces/AGENTS.md) — 逻辑层的边界
- [`Sources/Views/AGENTS.md`](Sources/Views/AGENTS.md) — 布局陷阱与验收
- [`Tools/AGENTS.md`](Tools/AGENTS.md) — 生成的产物、夹具、截图
- [`Tests/AGENTS.md`](Tests/AGENTS.md) — 断言怎么写
