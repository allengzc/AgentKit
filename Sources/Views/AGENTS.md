# Sources/Views —— 布局陷阱与验收

本目录只讲一件事：**改完 UI 怎么证明它是对的**。其余见[根规范](../../AGENTS.md)。

SwiftUI 界面。`8 个 Pane + 组件`，最大的层（≈5400 行）—— 也是**唯一测不到**的一层。
所以这一页的规矩不是风格偏好，是"用血换来的"。

`Panes/<名字>Pane.swift` 里的逻辑应该尽量薄：计算在 `Surfaces`，这里只放布局和绑定。

## 一、六个已知的布局陷阱

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

**6. 菜单项要限宽，只能用固定 `width`，`maxWidth` 在 NSMenu 里不生效。**
菜单宽度 = 最宽那一项的 ideal size，**没有任何人提出更小的宽度**，所以
`.frame(maxWidth: 260)` 会和完全不设上限一模一样 —— 实测两次都是 587pt。
→ 菜单里的路径用 `.frame(width: 260)` + `.lineLimit(1)` + `.truncationMode(.middle)`，
并给 `.help(完整路径)`。实测 587 → 307pt（−48%）。
（项目作用域菜单那次：一行 82 字符的路径把菜单撑到 587pt，把窗口挤变形。
 更值得记的是我第一次"改完"量出来还是 587pt，因为**只改了一处、漏了另一处** ——
 所以这条的验收方式和第 5 条一样：量，不是看。）

## 二、异步状态：先看清谁在什么时候写

`scan()` 这类方法内部是 `Task.detached` + `await MainActor.run`，**调用即返回**。
所以 `.task { scan(); 用结果 }` 里的"用结果"看到的是旧值。
→ 要在 `MainActor.run` 的收尾里做事，或者观察状态变化。

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

## 四、改完顺手清掉调试钩子

排查时经常加环境变量钩子（`AGENTKIT_DEBUG_*`）。它们**必须**在提交前删掉，
或者提升成 `DocumentationState` 里那种正式、有文档的开关。
`grep -rn "AGENTKIT_DEBUG" Sources/` 在提交前跑一遍。
