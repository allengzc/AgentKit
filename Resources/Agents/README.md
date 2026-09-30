# 三个 agent 的标记

侧栏头部那个小标记由描述文件里的三个可选键决定：`iconImage`（这张图）> `glyph`（画的字）>
`icon`（SF Symbol）。`pi` 没有 logo —— 它的身份就是字母 π，所以它是 `glyph`。

`claude.svg` 与 `openai.svg` 是从 [gilbarbara/logos](https://github.com/gilbarbara/logos)
取的（该仓库本身 MIT；这些图形是各家**商标**，在此仅用于指代对应的产品）：

| 文件 | 对应 | 出处（取的时候是这个路径） |
|---|---|---|
| `claude.svg` | Claude Code（Anthropic） | `logos/claude-icon.svg` |
| `openai.svg` | Codex（OpenAI） | `logos/openai-icon.svg` |

两条注意：

- 这两个文件是**原样**放进来的，不要手改。App 里用 `renderingMode(.template)` 按各自的
  `tint` 着色，所以文件里自带的 `fill` 不影响显示 —— 这也是深色模式下能看清的原因
  （OpenAI 的 mark 本身是黑的，直接贴上去在深色里就是一块看不见的黑）。
- 想换掉 / 去掉：删掉对应文件与描述文件里的 `iconImage` 就退回 `glyph` / `icon`。
  商标归属各自的公司，这个仓库只是用它们表示"这是哪家的 agent"。
