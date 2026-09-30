# Sources/Views —— 布局陷阱与验收

本目录只讲一件事：**改完 UI 怎么证明它是对的**。其余见[根规范](../../AGENTS.md)。

SwiftUI 界面。`8 个 Pane + 组件`，最大的层（≈5400 行）—— 也是**唯一测不到**的一层。
所以这一页的规矩不是风格偏好，是"用血换来的"。

`Panes/<名字>Pane.swift` 里的逻辑应该尽量薄：计算在 `Surfaces`，这里只放布局和绑定。

## 一、七个已知的布局陷阱

每条都对应一个真实发生过的 bug。

**1. `HStack` / `VStack` 会按子视图尺寸收缩。**
主从布局（左边列表 + 右边详情）如果不给显式贪心 frame，某个空状态会让整行collapse，
列表被挤到一边。
→ 主从那一行必须 `.frame(maxWidth: .infinity, maxHeight: .infinity)`。
（`ResourcesPane` 那次：列表被推到中间，右边一大片空。）

**2. `Spacer` 放进横向 `ScrollView` 会拿到无限宽度的提议。**
行会被撑到无限宽，固定宽度的行号栏飘到中间、正文跑到屏幕外 —— 看起来像"整个 diff 是空的"。
→ diff 那种要横向对齐的列表**只用纵向滚动**，靠 `lineLimit` + 截断处理长行。
（`DiffSheet` 那次。）

**3. 列表里的名字必须 `lineLimit(1)` + 中间截断。**
不限制的话，同一行里几个 `Text` 互相争宽度，长名字会被压成**每行一个字母**竖排。
（Skills 随包文件那次：`competition-ad-certificate-absue` 变成一列字母。）

**4. 用 `List(selection:)` 桥接"字符串路径"会把相对路径喂给
`URL(fileURLWithPath:)`。**
它按进程工作目录解析，GUI 的工作目录是 `/` —— 选中 `AGENTS.MD` 打开的是 `/AGENTS.MD`，
而且**不报错**。
→ 选中项存一个**类型化的槽位**（`enum Slot`），URL 只能来自 `PathResolver`。
（全局指令面板那次。）

**5. 需要展开/折叠时优先用系统的 `DisclosureGroup(isExpanded:)`。**
自绘 chevron + Button + 自己维护 Set，命中判定就全是自己的责任；而展开是**必须每次
都成功**的交互。用系统的同时把状态绑成 `Binding`，既能被程序驱动、又拿到原生动画与
无障碍。（Skills 随包文件那次。）

**6. 菜单项的宽度只能靠自己截断 —— 任何 `frame` 在菜单里都不保证生效。**
菜单宽度 = 最宽那一项的 ideal size，而且 **SwiftUI 会把 `Menu` 里自定义 `Button`
的 label 压平成纯文本再交给 AppKit**：`.frame(width:)`、`.font()`、`HStack` 里的
第二个 `Text` 全部被丢掉。两种写法都试过：

| label | 菜单实测宽 |
|---|---|
| `Text(路径)` | 370pt |
| `.frame(width: 260).lineLimit(1).truncationMode(.middle)` | **370pt（没生效）** |
| `HStack { 截断文本; 徽标 }` | 370pt，**徽标不画** |

→ 唯一可靠的做法是**在字符串层面截断**：把整行拼成一个字符串，按列数自己截
（中文/emoji 算 2 列），外面仍然套 `.frame`/`.truncationMode` —— 今天是空操作，
将来系统恢复 view hosting 时截断会保住头尾。实测：52 字符和 111 字符的路径，
菜单宽度都是 **313pt**。
（项目作用域菜单那次。更值得记的是这条已经错过两轮：第一轮 `.frame(maxWidth:)`
没生效，第二轮以为换成固定 `width` 就好了 —— 直到系统升级后独立复现才发现
**两个都不生效**。菜单里的东西，只能在拿到真实菜单尺寸之后再声称修好。）

**7. `.listStyle(.sidebar)` 会在面板内部画出窗口侧栏那份材质。**
面板自己的主列表（左边那一列）用 `.sidebar` 是为了拿到行样式和胶囊选中，但它同时
paints 侧栏的**半透明材质**；而这一列和真正的侧栏只隔一条 1pt 分隔线，于是两列灰
连成一片。实测（用户截图，2x）：侧栏 `rgb(242,246,246)`、面板那一列 `rgb(230,230,234)`，
而且两者都是**同样的左上圆角**，眼睛看到的是"两个面板"而不是"一条边界"。
→ 面板内部的主列表统一走 `paneListBackground()`（`Components.swift`）：
`.scrollContentBackground(.hidden)` + 扁平的 `controlBackgroundColor`。实测改成
`rgb(254,254,254)`，和详情区一致，只留分隔线；选中胶囊的颜色不受影响（改前改后都是
同一个灰/蓝，取决于窗口是否在前台）。
（设置面板那次，用户原话"这个灰色面板穿到了左边的侧边栏感觉不和谐"。四个用了
`.sidebar` 的面板一起改了，否则修完反而和另外两个面板不一致。）

## 二、异步状态：先看清谁在什么时候写

`scan()` 这类方法内部是 `Task.detached` + `await MainActor.run`，**调用即返回**。
所以 `.task { scan(); 用结果 }` 里的"用结果"看到的是旧值。
→ 要在 `MainActor.run` 的收尾里做事，或者观察状态变化。

**文件监听的批次是"整棵树"级别的，别拿它当"我的文件变了"。**
`DirectoryWatcher` 监视的是每个声明路径**最近的存在祖先**（为了发现还不存在的路径），
所以回调里会带上 agent 自己运行时的写入。实测：往 `~/.pi/agent/sessions/` 追加内容，
2.5 秒内 6 个批次 —— 一个在 `externalChangeToken` 上无条件重载的面板，等于每秒重载
2.4 次。面板要用 `ExternalChange.touches(我的路径, changed: model.externalChangePaths)`
先筛一遍；"外部改动"这种事应当**标记为过期 + 让用户点一下**，而不是替他决定何时重扫。

## 三、验收：截图 + 机器判定

改完必须渲染出来看。**但光看不够。**

侧栏整列空白那次，我看着截图说"没问题"；直到把侧栏区域裁出来量字节，
三张图**完全一致（3794 字节）** —— 三张都是空的。眼睛会被"看起来很正常"骗过。

```bash
# 1. 起 App，抓窗口
AGENTKIT_NO_ACTIVATE=1 AGENTKIT_HOME=/tmp/agentkit-demo AGENTKIT_OPEN=pi/skills \
  ./out/AgentKit.app/Contents/MacOS/AgentKit -ApplePersistenceIgnoreState YES &
Tools/bin/windowid -a -o -v AgentKit          # 列出窗口及尺寸，挑最大的那个
screencapture -x -o -l <wid> /tmp/shot.png

# 2. 把要验的区域裁出来量一下（空白区域压缩后会小一个数量级）
sips -c 420 230 --cropOffset 150 12 /tmp/shot.png --out /tmp/probe.png
stat -f%z /tmp/probe.png
```

`Tools/make-screenshots.sh` 已经把这条写死了：侧栏区域 < 6KB 判定失败并重试。
**新增截图时照着加验收**，不要只看一眼就交。

三个必须做：

- **`AGENTKIT_NO_ACTIVATE=1`** —— 不加的话每次起 App 都会成为前台应用。验证要起很多次，
  在你正在用机器时这是不可忍受的。它让 App 以 accessory 身份运行：窗口照常出现、
  照常可抓，但不抢焦点。**量过**：加之前前台从别的应用变成 AgentKit，加之后不变
- `-ApplePersistenceIgnoreState YES`（见下）
- 清理用 `pkill -x AgentKit`，**不要用 `-f`**（`-f` 会匹配到 swiftc 的命令行，
  把正在编译的进程一起杀掉）

还要注意：
- `-ApplePersistenceIgnoreState YES` 是必需的 —— 否则 AppKit 的"上次意外退出"弹窗
  会成为唯一的窗口，你会得到一张弹窗的截图
- **别用 App 自渲染**（`CALayer.render` / `cacheDisplay`）代替截屏：
  侧栏是 `NSVisualEffectView` 画的、材质由窗口服务器合成，不在图层树里 ——
  自渲染会**静默丢掉整列侧栏**，产出一张"看着很正常、左边少一列"的图

### 三个会骗过你的量法（都实测过）

- **`sips --cropOffset 0 0` 等于不写 offset**：它会退回**居中裁剪**，而且不报错。
  用 `sips -c 420 230 --cropOffset 150 12` 这种非零 offset，或者干脆自己解 PNG
  （截图是 8bit RGBA、非交错，`zlib` + 反滤波三十行就够，别为此装 Pillow）。
  裁出来的东西不是你指定的区域时，第一反应应该是"offset 是不是 0"。
- **`AGENTKIT_NO_ACTIVATE=1` 会让交通灯不进截图**。accessory 身份下窗口内容
  **逐像素相同**（实测：同一夹具、同一尺寸，加与不加标志的两张图在 y 方向零位移、
  平均通道差 3.9/255，差异只在标题栏那几个圆点），但红/黄/绿三个按钮不合成进
  `screencapture -l` 的结果。**所以"左上角没有红绿灯"不能判定截图失败** ——
  判据要换成"面板头部（标题 + 搜索框）在不在"。反过来，`docs/` 那套图是**会激活**的
  跑法（脚本里没有 `NO_ACTIVATE`），它们有红绿灯。
- **`AGENTKIT_DOC_STATE=size:WxH` 钉的是窗口 frame，不是内容尺寸**
  （`window.setFrame`，含标题栏），而且**截图里"顶部被切掉"未必是抓图的问题**：
  窗内容理想高度一旦超过窗口，整个 `NavigationSplitView` 会被布局到窗口之外并居中，
  工具栏/面板标题/搜索框就被挤出窗口顶部。实测触发条件是**面板头部多出一条 `InfoBanner`**，
  与列表长度无关（Skills 面板：5 个 skill + 2 条横幅 → 错位；500 个 skill + 1 条横幅 → 正常），
  HEAD 同样复现 → 是既有 bug，见 README「已知限制」。看到可疑的偏移先量
  「第一处墨迹在 y 多少」，再决定是自己改坏了还是撞上了它。

## 四、改完顺手清掉调试钩子

排查时经常加环境变量钩子（`AGENTKIT_DEBUG_*`）。它们**必须**在提交前删掉，
或者提升成 `DocumentationState` 里那种正式、有文档的开关。
`grep -rn "AGENTKIT_DEBUG" Sources/` 在提交前跑一遍。
