# Tools —— 生成的产物、夹具、截图

本目录只讲一件事：**哪些文件不许手改，以及怎么验**。其余见[根规范](../AGENTS.md)。

## 一、生成的产物（不要手改）

| 产物 | 生成脚本 | 输入 |
|---|---|---|
| `Sources/Surfaces/SettingsSchemaClaude.swift` | `Tools/make-claude-schema.py` | 上游[设置参考](https://code.claude.com/docs/en/settings-reference.md) |
| `Resources/Icon.svg`、`Icon-simple.svg`、`Resources/AppIcon.icns` | `Tools/make-icon.py` | 系统 `RoundedRectangle(style:.continuous)` 的真实路径 |

改这两样东西的正确姿势是**改脚本重跑**：

```bash
curl -sL https://code.claude.com/docs/en/settings-reference.md -o /tmp/ck-settings.md
python3 Tools/make-claude-schema.py > Sources/Surfaces/SettingsSchemaClaude.swift

python3 Tools/make-icon.py        # 需要先 ./build.sh 出 Tools/bin/iconpath
```

从**发布文档**派生而不是凭记忆写，是为了让升级后重跑一次就能看出上游哪些键变了。
`claude-schema` 那次就是：claude 2.1.283 的设置表 78 个键，全部对得上官方参考。

图标那条更值得留意：圆角不是圆角矩形，`iconpath.swift` 是**问系统要**那条连续曲率
路径再转成 SVG 的 —— 手搓贝塞尔"看起来差不多"就够了，但会和 Dock 里其它图标不一致。

## 二、夹具（写操作一律先对夹具）

```bash
python3 Tools/make-demo.py            # 生成到 /tmp/agentkit-demo，全假数据
```

它造出一整套配置：三个 agent、provider、会话、skill、项目路径，**全部是编的**。
配合 `AGENTKIT_HOME`（把 `~` / `$HOME` 重定向到那棵树），整个 App 都在夹具里跑。

- 加新 agent 时**同时**在 `make-demo.py` 里造一份**最小但真实**的样本 ——
  描述文件写得对不对，一跑就知道
- 夹具里不许出现任何真实信息（路径、域名、provider id、会话内容）
- 会话时间戳等要保持**确定性**，让截图可复现

## 三、截图

```bash
./Tools/make-screenshots.sh              # 全部
./Tools/make-screenshots.sh skills mcp   # 只重出这两张
```

三个前提，缺一个就会得到**看着正常但其实错了**的图：

1. **显示器要醒着**。休眠时窗口抓取一律失败，全屏抓取会返回一张陈旧的空白帧
   （症状：PNG 只有 11 万字节，正常是 200 万）
2. **App 实例要串行**。`windowid -o` 会列出**已经退出的实例**的窗口，
   抓到上一个正在死亡的窗口 → 图是错位的。脚本里有 `quit_app` 保证这一点
3. **必须带 `-ApplePersistenceIgnoreState YES`**，否则 AppKit 的崩溃恢复弹窗会成为
   唯一窗口，十二张图全是那张弹窗（字节数完全相同，是最好认的信号）

还有一条**不是抓图失败**的现象，别去"修"它：截图里侧栏选中行是灰的（未强调样式）。
`AGENTKIT_OPEN` 是在窗口出现**之后**才改选中项的，而 macOS 的侧栏只在选中项**首帧就定下**
时才画蓝色强调态 —— 启动后再改会画成灰的。旧的那一套图也是这样（15 张里只有默认那张是蓝的）。
量过的对照：同一份构建、同一个面板，不带 `AGENTKIT_OPEN` 启动是蓝的，带上就是灰的。

脚本里已经有**验收**：裁出侧栏区域，小于 6KB（空白）判定失败并重试三次。
**新增截图时照抄这个检查** —— 不要只靠看一眼。

## 四、几个小工具

| 工具 | 用途 |
|---|---|
| `iconpath.swift` | 打印系统连续曲率圆角路径（SVG path data） |
| `windowid.swift` | 找窗口：`-a` 全部 / `-o` 含被遮挡 / `-v` 带尺寸 |
| `click.swift` | 合成点击。**注意**：没有辅助功能权限时事件会被系统静默丢弃，用它得先确认对照组能点动 |
| `bench-skills.swift` + `.sh` | Skills 面板的性能基准：造 50/200/500 个 skill 的夹具，分别量「扫描」「一次 body pass」「一次搜索」「每行解析选中项」；`real` 参数顺带量真机的 skill 根。`perf(views)` 那条提交里的数字都是它跑出来的 —— 结论要能被重跑，`Tools/bench-skills.sh` 就是重跑的入口 |

`Tools/bin/` 是 gitignore 的，由 `./build.sh` 编译。
