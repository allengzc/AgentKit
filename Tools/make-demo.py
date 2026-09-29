#!/usr/bin/env python3
"""Generate the demo configuration the screenshots are taken against.

    Tools/make-demo.py [root]      # default root: /tmp/agentkit-demo

Nothing here comes from a real machine: the providers, models, sessions, skills
and project paths are all invented. Combined with `AGENTKIT_HOME` (which makes
the app resolve `~` inside this tree), a screenshot can be produced end to end
without the author's own configuration ever being read.

`Tools/make-screenshots.sh` calls this, launches the app once per surface and
captures the window.
"""

import json
import os
import shutil
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/agentkit-demo"
HOME = ROOT

PROJECT_A = os.path.join(ROOT, "projects/orchard-api")
PROJECT_B = os.path.join(ROOT, "projects/orchard-web")


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(path, mode)


def write_json(path, value, mode=0o644):
    write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n", mode)


def pi_sessions(root):
    """Two project groups, a few sessions each, in pi's jsonl shape."""
    header = lambda sid, cwd, stamp, parent=None: json.dumps({
        "type": "session",
        "id": sid,
        "cwd": cwd,
        "timestamp": stamp,
        **({"parentSession": parent} if parent else {}),
    }, ensure_ascii=False)

    def message(role, text, tokens, cost, stamp):
        return json.dumps({
            "type": "message",
            "id": f"m-{stamp}",
            "timestamp": stamp,
            "message": {
                "role": role,
                "content": [{"type": "text", "text": text}],
                "usage": {"totalTokens": tokens, "cost": {"total": cost}},
            },
        }, ensure_ascii=False)

    def name(sid, title):
        return json.dumps({"type": "session_info", "id": sid, "name": title}, ensure_ascii=False)

    plan = [
        (PROJECT_A, "2026-09-28T09:12:04.000Z", "s-9f2c1a", "把分页参数收敛成一个类型",
         [("user", "帮我把这三个接口的分页参数收敛成一个类型。", 1840, 0.0042),
          ("assistant", "先看现在各自是怎么写的。", 5210, 0.0131),
          ("user", "用 PageRequest 吧，顺带把校验也放进去。", 8940, 0.0224)]),
        (PROJECT_A, "2026-09-28T14:40:51.000Z", "s-4b81de", "排查导出 CSV 的编码问题",
         [("user", "导出的 CSV 在 Excel 里全是乱码。", 2210, 0.0051),
          ("assistant", "是少写了 BOM，改一下响应的编码头。", 6890, 0.0163)]),
        (PROJECT_B, "2026-09-27T20:05:12.000Z", "s-71ac02", "首页首屏的字体加载",
         [("user", "首屏字体会闪一下，能治吗。", 3120, 0.0074),
          ("assistant", "把字体文件提前 preload，并且加 font-display: swap。", 9140, 0.0238)]),
        (PROJECT_B, "2026-09-26T11:22:38.000Z", "s-08d3f1", "把构建时间从 42s 压下来",
         [("user", "构建太慢了。", 1420, 0.0033),
          ("assistant", "大头在重复解析 Markdown，加一层缓存就够。", 7380, 0.0181)]),
    ]

    for cwd, stamp, sid, title, turns in plan:
        folder = cwd.replace("/", "-")
        path = os.path.join(root, "sessions", folder, f"{stamp.replace(':', '-')}_{sid}.jsonl")
        lines = [header(sid, cwd, stamp)]
        for index, (role, text, tokens, cost) in enumerate(turns):
            lines.append(message(role, text, tokens, cost, f"{stamp}-{index}"))
        lines.append(name(sid, title))
        write(path, "\n".join(lines) + "\n")


def codex_sessions(root):
    """Codex's recursive layout, a payload-shaped header and a session index."""
    plan = [
        ("2026-09-28", "2026-09-28T09:30:00.000Z", "01JC4W2M8Q7ZK3", PROJECT_A,
         "梳理导出模块的分层", "demo-model", 128400,
         [("user", "帮我看下导出模块的分层是不是太浅了。"),
          ("assistant", "它的三个职责可以拆开。"),
          ("user", "那就拆。"),
          ("assistant", "拆完了，测试也补上了。")]),
        ("2026-09-27", "2026-09-27T16:02:11.000Z", "01JC1P7T2R5XA9", PROJECT_B,
         "给表单加上一次提交前的确认", "demo-model-2", 76200,
         [("user", "提交前加个确认吧。"),
          ("assistant", "确认弹窗只在检测到未保存改动时出现。")]),
        ("2026-09-25", "2026-09-25T08:44:03.000Z", "01JBX0K4N8QW2E", PROJECT_A,
         "把日志里的时间统一成 ISO8601", "demo-model", 45300,
         [("user", "日志时间格式太乱了。"),
          ("assistant", "统一成 ISO8601，并且带上时区。")]),
    ]

    index_lines = []
    for day, stamp, sid, cwd, title, model, tokens, turns in plan:
        year, month, date = day.split("-")
        path = os.path.join(root, "sessions", year, month, date, f"rollout-{stamp}-{sid}.jsonl")
        lines = [json.dumps({
            "timestamp": stamp,
            "type": "session_meta",
            "payload": {"id": sid, "cwd": cwd, "model_provider": model},
        }, ensure_ascii=False)]
        for role, text in turns:
            lines.append(json.dumps({
                "timestamp": stamp,
                "type": "response_item",
                "payload": {"role": role, "content": [{"type": "text", "text": text}]},
            }, ensure_ascii=False))
        lines.append(json.dumps({
            "timestamp": stamp,
            "type": "event_msg",
            "payload": {"type": "token_count", "info": {"total_token_usage": {"total_tokens": tokens}}},
        }, ensure_ascii=False))
        write(path, "\n".join(lines) + "\n")
        index_lines.append(json.dumps({"id": sid, "thread_name": title, "updated_at": stamp}, ensure_ascii=False))
    write(os.path.join(root, "session_index.jsonl"), "\n".join(index_lines) + "\n")


def skill(directory, name, description, extra_front=None, body="", files=None):
    lines = ["---", f"name: {name}", f"description: {description}"]
    for key, value in (extra_front or {}).items():
        lines.append(f"{key}: {value}")
    lines += ["---", "", body.rstrip(), ""]
    write(os.path.join(directory, "SKILL.md"), "\n".join(lines))
    for relative, content in (files or {}).items():
        write(os.path.join(directory, relative), content)


def main():
    if os.path.exists(ROOT):
        shutil.rmtree(ROOT)
    os.makedirs(ROOT)

    agent = os.path.join(HOME, ".pi/agent")

    # ---- settings / models -------------------------------------------------
    write_json(os.path.join(agent, "settings.json"), {
        "defaultProvider": "example",
        "defaultModel": "demo-model",
        "defaultThinkingLevel": "high",
        "theme": "graphite-light/graphite-dark",
        "hideThinkingBlock": False,
        "quietStartup": True,
        "enableSkillCommands": True,
        "terminal": {"showTerminalProgress": False},
        "images": {"blockImages": False},
        "externalEditor": "/usr/bin/vi",
        "packages": ["@demo/toolkit"],
    })

    write_json(os.path.join(agent, "models.json"), {
        "providers": {
            "example": {
                "name": "Example Gateway",
                "baseUrl": "https://llm.example.com/v1",
                "api": "openai-completions",
                "apiKey": "sk-demo-not-a-real-key",
                "models": [
                    {"id": "demo-model", "name": "Demo Model", "reasoning": True,
                     "input": ["text", "image"], "contextWindow": 400000, "maxTokens": 100000},
                    {"id": "demo-model-2", "name": "Demo Model 2", "reasoning": True,
                     "input": ["text"], "contextWindow": 200000, "maxTokens": 64000},
                ],
            },
            "local-llama": {
                "name": "Local llama.cpp",
                "baseUrl": "http://127.0.0.1:8080/v1",
                "api": "openai-completions",
                "models": [{"id": "qwen3-8b", "name": "qwen3 8B", "contextWindow": 32000}],
            },
        }
    })

    write(os.path.join(agent, "AGENTS.md"), """# 全局指令

## 提交前

- 改动落盘前跑一遍测试，别只看编译过没过。
- 提交信息写清楚**为什么**，而不是改了什么 —— 改了什么 diff 里有。

## 依赖

- 新增依赖要先说明理由，能不加就不加。
- 版本锁定到 patch，不要用 `^`。
""")

    write_json(os.path.join(agent, "mcp-adapter.json"), {
        "mcpServers": {
            "filesystem": {
                "command": "/opt/homebrew/bin/mcp-filesystem",
                "args": ["--root", "/Users/dev/projects"],
            }
        }
    })

    # ---- shared MCP layer --------------------------------------------------
    write_json(os.path.join(HOME, ".config/mcp/mcp.json"), {
        "mcpServers": {
            "github": {
                "command": "/opt/homebrew/bin/mcp-github",
                "env": {"GITHUB_TOKEN": "ghp_demo_not_a_real_token"},
            },
            "blender": {
                "command": "/Applications/Blender.app/Contents/MacOS/blender",
                "args": ["--background", "--python", "/opt/mcp/blender_server.py"],
            },
        }
    })

    # ---- skills ------------------------------------------------------------
    skills = os.path.join(agent, "skills")
    skill(
        os.path.join(skills, "pdf-tools"), "pdf-tools",
        "Fill in PDF forms and extract tables from them. Use when the user hands "
        "over a PDF and asks for specific fields, totals or a summary table.",
        extra_front={"license": "MIT", "allowed-tools": "read, write, bash"},
        body="## 做什么\n\n读取 PDF 表单域，填写后另存，不覆盖原文件。",
        files={
            "references/fields.md": "# 常见表单域\n\n- `AcroForm` 文本域\n- 复选框\n- 签字域\n",
            "scripts/fill.py": "import sys\n\n# demo placeholder\nprint('fill', sys.argv[1:])\n",
        },
    )
    skill(
        os.path.join(skills, "changelog-writer"), "changelog-writer",
        "Turn a range of commits into a changelog entry written for users, not for "
        "the people who wrote the code.",
        body="## 规则\n\n- 只写用户能感知的变化\n- 每条一句话，动词开头\n",
        files={
            "references/style.md": "# 文风\n\n不要写「优化了」。写清楚优化了什么。\n",
            "references/example.md": "## 1.4.0\n\n- 导出 CSV 现在带 BOM，Excel 不再乱码。\n",
            "scripts/collect.sh": "#!/bin/sh\n# demo placeholder\ngit log --oneline \"$1..$2\"\n",
            "assets/icon.png": "",
        },
    )
    skill(
        os.path.join(skills, "incident-notes"), "incident-notes",
        "Write a blameless incident note from a messy timeline. Use after an "
        "outage or a data incident has been resolved.",
        body="## 结构\n\n时间线 → 影响 → 根因 → 后续动作\n",
        files={"references/template.md": "# 模板\n\n- 什么时候发现的\n- 影响了谁\n"},
    )
    # A skill that validates badly, so the pane shows its warning banner.
    skill(
        os.path.join(skills, "broken-example"), "broken-example", "",
        body="这个 skill 没写 description，pi 不会加载它。",
    )

    # ---- subagents ---------------------------------------------------------
    write(os.path.join(agent, "agents/code-reviewer.md"), """---
name: code-reviewer
description: Review a diff for correctness and regressions before shipping.
model: demo-model
tools: read, grep, bash
---

只看这次改动的 diff，不要通读整个仓库。

按严重程度排序输出，每条给出文件与行号。
""")
    write(os.path.join(agent, "agents/planner.md"), """---
name: planner
description: Turn a vague request into a sequenced plan with checkpoints.
model: demo-model-2
---

计划要写成可勾选的步骤，每步说清验收条件。
""")

    # ---- themes / extensions ----------------------------------------------
    write_json(os.path.join(agent, "themes/graphite.json"), {
        "name": "graphite",
        "colors": {"background": "#1c1c1e", "foreground": "#e5e5e7", "accent": "#7aa2f7"},
    })
    write_json(os.path.join(agent, "themes/graphite.json.off"), {
        "name": "graphite-light",
        "colors": {"background": "#f7f7f8", "foreground": "#1c1c1e", "accent": "#3b6fd4"},
    })
    write(os.path.join(agent, "extensions/demo-extension.js"),
          "// demo placeholder\nexport const name = 'demo-extension';\n")

    # ---- pi sessions -------------------------------------------------------
    pi_sessions(agent)

    # ---- a second, shared skill root --------------------------------------
    skill(
        os.path.join(HOME, ".agents/skills/shared-notes"), "shared-notes",
        "Keep a shared notebook of decisions the whole team can read.",
        files={"references/index.md": "# 索引\n\n- 2026-09 决定用 SQLite 存本地缓存\n"},
    )

    # ---- codex -------------------------------------------------------------
    codex = os.path.join(HOME, ".codex")
    write(os.path.join(codex, "config.toml"), """model_provider = "example"
model = "demo-model"
model_reasoning_effort = "high"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[tui]
notifications = true

[history]
persistence = "save-all"

[model_providers.example]
name = "Example Gateway"
base_url = "https://llm.example.com/v1"
env_key = "EXAMPLE_API_KEY"
wire_api = "responses"

[model_providers.local]
name = "Local llama.cpp"
base_url = "http://127.0.0.1:8080/v1"
wire_api = "chat"

[mcp_servers.github]
command = "/opt/homebrew/bin/mcp-github"
args = ["--toolsets", "repos,issues"]

[mcp_servers.filesystem]
command = "/opt/homebrew/bin/mcp-filesystem"
args = ["--root", "/Users/dev/projects"]

[mcp_servers.experimental]
command = "/opt/homebrew/bin/mcp-experimental"
enabled = false
""")
    write(os.path.join(codex, "AGENTS.md"),
          "# Codex 全局指令\n\n- 改动小步提交，一次一件事。\n")
    skill(
        os.path.join(codex, "skills/release-notes"), "release-notes",
        "Draft release notes from a milestone, grouped by what a user would notice.",
        files={"references/voice.md": "# 口吻\n\n平实，不吹。\n"},
    )
    codex_sessions(codex)

    # ---- project-level configuration --------------------------------------
    write_json(os.path.join(PROJECT_A, ".pi/mcp-adapter.json"), {
        "mcpServers": {
            "orchard-db": {
                "command": "/opt/homebrew/bin/mcp-postgres",
                "args": ["--dsn", "postgres://localhost/orchard_dev"],
            }
        }
    })
    write(os.path.join(PROJECT_A, "AGENTS.md"),
          "# orchard-api\n\n- 数据库迁移一律往前写，不回滚。\n- 接口改动要同时更新 `docs/openapi.yaml`。\n")
    write_json(os.path.join(PROJECT_B, ".pi/mcp-adapter.json"), {
        "mcpServers": {
            "storybook": {"command": "/usr/local/bin/mcp-storybook", "args": ["--port", "6006"]}
        }
    })

    # ---- report ------------------------------------------------------------
    total = sum(len(files) for _, _, files in os.walk(ROOT))
    print(f"demo fixture: {ROOT} ({total} files)")
    print(f"  pi    -> {agent}")
    print(f"  codex -> {codex}")


if __name__ == "__main__":
    main()
