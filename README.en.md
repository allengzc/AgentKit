# AgentKit

**A native macOS GUI that configures and manages local coding agents, driven by descriptors.**

[中文](README.md) · English

Three agents are supported today:

| Agent | Config root | Panels covered |
|---|---|---|
| **pi** (`@earendil-works/pi-coding-agent`) | `~/.pi/agent` | Models & Providers, MCP, Skills, Sessions, Instructions, Subagents, Settings, Themes/Extensions/Packages |
| **Codex** (`codex-cli`) | `~/.codex` | Models & Providers, MCP, Skills, Sessions, Instructions, Settings |
| **Claude Code** (`claude`) | `~/.claude` | MCP, Skills, Subagents, Sessions, Instructions, Settings |

**Which agents exist is decided by a JSON descriptor**, not by code — adding an agent means
adding a JSON file. How one table absorbs three different on-disk formats → [Descriptors](docs/descriptors.md).

![The pi Settings panel](docs/settings.png)

> Every screenshot is rendered from a fake configuration built by `Tools/make-demo.py`:
> the providers, sessions, skills and project paths are invented and **come from no one's
> real machine**. Regenerate them → [Screenshot pipeline](docs/development.md#截图流水线).
> Note: these screenshots were captured with the Chinese interface, before UI localization
> landed — they are layout references, not English UI mockups.

> Working on this repository? Read [`AGENTS.md`](AGENTS.md) first (root rules plus one per
> directory). This page is for users.

---

## Quick start

```bash
./build.sh          # compile to out/AgentKit.app (swiftc is all it needs)
./install.sh        # then copy to /Applications/AgentKit.app
./run-tests.sh      # all offline assertions — no window, no network
```

The interface is available in **Chinese and English**: switch it from the
**Language** menu in the menu bar and the choice is remembered. It follows the
system language by default. Panel names, buttons, prompts, the reasons a
write was refused, and the labels in descriptors and settings schemas all
follow it; log messages and command line switch names do not.

Requirements: macOS 14+, Xcode command line tools (Swift 6.x), and an Apple Development
certificate for signing (override with `AGENTKIT_SIGN_IDENTITY`).

Launching:

```bash
open -a AgentKit
AGENTKIT_OPEN=codex/mcp open -a AgentKit              # jump straight to one agent's panel
AGENTKIT_PROJECT=~/code/my-repo open -a AgentKit      # pin a project scope
CODEX_HOME=/tmp/fixture open -a AgentKit              # use another config root (fixture-first debugging)
```

Running against fake config, writing assertions, icons and the screenshot pipeline →
[Development & verification](docs/development.md).

---

## Documentation

| Question | Where to go |
|---|---|
| What can each of the eight panels do? | [Panels](docs/panels.md) |
| Will writing break my config? | [Write safety](docs/safety.md) |
| How do I write a descriptor, or add an agent? | [Descriptors](docs/descriptors.md) |
| How do I build, test, and regenerate screenshots? | [Development & verification](docs/development.md) |

> The topic pages under `docs/` are written in Chinese for now, and they stay close to the
> source. This README is the English entry point; the tables above cover what each agent can do.

---

## Environment variables

| Variable | Effect |
|---|---|
| `PI_CODING_AGENT_DIR` | Overrides pi's config root (declared as `root.env` in pi's descriptor) |
| `CODEX_HOME` | Overrides Codex's config root |
| `AGENTKIT_CONFIG_DIR` | Overrides the descriptor directory (default `~/.config/agentkit`) |
| `AGENTKIT_HOME=/tmp/demo` | Redirects `~` / `$HOME` into a throwaway tree, so you can run against a fixture without touching real config |
| `AGENTKIT_OPEN=codex/mcp` | Boots straight into the given agent's given panel |
| `AGENTKIT_PROJECT=~/repo` | Sets the project scope (same as picking a project in the toolbar) |
| `AGENTKIT_DOC_STATE=…` | Documentation screenshots only: force a preview/expand/diff state, fix appearance and window size, render and quit |
| `AGENTKIT_SIGN_IDENTITY` | Signing identity used at build time |
| `AGENTKIT_TARGET` | Build target triple, default `arm64-apple-macosx14.0` |

Logs:

```bash
log show --last 5m --info --predicate 'subsystem == "com.allengzc.agentkit"'
```

---

## Known limitations

A summary; the details live on the linked topic pages. Nothing is hidden.

- **Project scope is chosen by hand**: a GUI has no meaningful "current working directory",
  so AgentKit does not guess — [Panels](docs/panels.md#项目作用域).
- **Structural TOML edits are not byte-for-byte**: adding or removing a top-level key
  rewrites the file and drops comments, which the confirmation sheet states plainly —
  [Write safety](docs/safety.md#结构改动按格式分级).
- **AgentKit never takes custody of secrets**: `apiKey` / `env_key` / `auth.json` are shown
  masked only — [Write safety](docs/safety.md#不接管密钥).
- **`~/.claude.json` is both config and state**: `claude` rewrites it on nearly every run,
  so writes there are rejected more often than elsewhere —
  [Write safety](docs/safety.md#被拒绝写入概率更高的文件).
- **Codex sessions cannot be renamed**: the names live in a separate index file AgentKit
  deliberately never writes — [Panels](docs/panels.md#会话).
- **Claude Code's MCP panel has no toggles**; the Claude settings table covers 78 keys and
  Codex's covers 69, with anything unrecognised kept read-only under "Other keys (preserved)";
  Packages are read-only — [Panels](docs/panels.md#通用设置).
- **No automatic schema-drift merging**: keys added by an agent upgrade are never guessed at —
  [Panels](docs/panels.md#通用设置).
- **Supporting another format (YAML / INI) means writing code**: descriptors are data, but the
  parser lives in Core — [Descriptors](docs/descriptors.md#加一个新-agent-的步骤).
- **The app is not sandboxed**: it has to read and write `~/.pi`, `~/.codex`, `~/.config`,
  `~/.agents` and launch a terminal, so a project under `~/Documents` / `~/Desktop` /
  `~/Downloads` triggers a system permission prompt on first access.

Full lists: [Panels](docs/panels.md#已知限制) · [Write safety](docs/safety.md#已知限制) ·
[Descriptors](docs/descriptors.md#已知限制) (all Chinese).

---

## License

MIT © 2026 allengzc
