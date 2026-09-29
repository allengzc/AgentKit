#!/usr/bin/env python3
"""Generate the Claude Code settings schema from the upstream reference.

    curl -sL https://code.claude.com/docs/en/settings-reference.md -o /tmp/ck-settings.md
    Tools/make-claude-schema.py > Sources/Surfaces/SettingsSchemaClaude.swift

Deriving the field table from the published reference rather than from memory
means every key, its type and its default come from the source Claude Code itself
documents, and re-running after an upgrade shows exactly what moved.

Labels are the literal JSON keys and help is the upstream English sentence. That
is deliberate: inventing a Chinese label for each of a hundred keys would hide
which key is being edited, and these files are read next to the English docs
anyway. Section titles are Chinese, because the grouping is AgentKit's own.
"""

import re
import sys

SOURCE = "/tmp/ck-settings.md"

# The reference's own topics, in display order, with a Chinese title and icon.
TOPICS = [
    ("Model and responses", "模型与回复", "cpu"),
    ("Permission settings", "权限", "lock.shield"),
    ("Agents, sessions, and worktrees", "Agent 与会话", "person.2"),
    ("Context and memory", "上下文与记忆", "text.book.closed"),
    ("MCP", "MCP", "point.3.connected.trianglepath.dotted"),
    ("Plugins and skills", "插件与 Skills", "puzzlepiece.extension"),
    ("Hooks and automation", "Hooks 与自动化", "bolt"),
    ("Interface and display", "界面与显示", "macwindow"),
    ("Remote, desktop, and notifications", "远程、桌面与通知", "bell"),
    ("Telemetry and updates", "遥测与更新", "chart.bar"),
    ("Environment and providers", "环境与 provider", "network"),
    ("Authentication and accounts", "认证与账号", "key"),
    ("Sandbox and security", "沙箱与安全", "shield.lefthalf.filled"),
    ("Other", "其它", "ellipsis.circle"),
]


def parse_index(text):
    """key -> (short description, topic, scope) from the index table."""
    out = {}
    for line in text.split("\n"):
        if not line.startswith("| [`"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 4:
            continue
        key = re.match(r"\[`(.+?)`\]", cells[0])
        if key:
            out[key.group(1)] = (cells[1], cells[2], cells[3])
    return out


def parse_sections(text):
    """key -> {type, default, help} from the per-key sections."""
    out = {}
    parts = re.split(r"\n### `(.+?)`\n", text)
    for index in range(1, len(parts) - 1, 2):
        key, body = parts[index], parts[index + 1]
        type_match = re.search(r"\* \*\*Type\*\*: (.+)", body)
        default_match = re.search(r"\* \*\*Default\*\*: (.+)", body)
        prose = []
        for line in body.split("\n"):
            stripped = line.strip()
            if stripped.startswith(("*", "```", ">")):
                break
            if stripped:
                prose.append(stripped)
        out[key] = {
            "type": type_match.group(1).strip() if type_match else "",
            "default": default_match.group(1).strip() if default_match else "",
            "help": " ".join(prose)[:600],
        }
    return out


def clean_help(text, limit=280):
    """Markdown links to their text, whitespace collapsed, cut at a word."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text.replace('"', "'")
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut.rstrip(",.;:") + "…"


def swift_string(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    return f'"{escaped}"'


def classify(type_text):
    lowered = type_text.lower()
    options = re.findall(r"`([A-Za-z0-9_.-]+)`", type_text)
    if lowered.startswith("boolean"):
        return "bool", options
    if "array of" in lowered or lowered.startswith("list of"):
        return "list", []
    if lowered.startswith(("number", "integer")):
        return "int", []
    if lowered.startswith(("object", "map of")):
        return "json", []
    if lowered.startswith("string") and ("one of" in lowered or "either" in lowered) and options:
        return "choice", options
    return "text", []


def fallback_literal(kind, default_text):
    stripped = default_text.strip().lower()
    if kind == "bool":
        if stripped.startswith("`true`") or stripped == "true":
            return "true"
        return "false"
    if kind == "int":
        digits = re.search(r"`?(\d+)`?", default_text)
        return digits.group(1) if digits else "nil"
    if kind == "choice":
        options = re.findall(r"`([A-Za-z0-9_.-]+)`", default_text)
        return options[0] if options else ""
    return ""


def main():
    text = open(SOURCE, encoding="utf-8").read()
    index = parse_index(text)
    sections = parse_sections(text)

    # Only keys a user can set in `~/.claude/settings.json`; managed-only and
    # `~/.claude.json`-only keys are not editable there and would be read-only
    # noise in the pane.
    grouped = {}
    for key, (description, topic, scope) in index.items():
        if scope.strip() == "Managed" or "Global config" in scope:
            continue
        if "Managed" in scope and "Any file" not in scope and "User" not in scope:
            continue
        grouped.setdefault(topic, []).append((key, description, scope, sections.get(key, {})))

    order = [title for title, _, _ in TOPICS]
    icons = {title: icon for title, _, icon in TOPICS}
    chinese = {title: name for title, name, _ in TOPICS}

    print("// Generated by Tools/make-claude-schema.py from the upstream settings")
    print("// reference. Do not edit by hand; re-run the script after an upgrade.")
    print("")
    print("import Foundation")
    print("")
    print("extension SettingsSchema {")
    print("\tpublic static let claudeCode = SettingsSchemaDefinition(")
    print('\t\tid: "claude-code",')
    print('\t\ttitle: "Claude Code 设置",')
    print("\t\tsections: [")

    total = 0
    for topic in order:
        entries = grouped.get(topic)
        if not entries:
            continue
        section_id = "claude-" + re.sub(r"[^a-z]+", "-", topic.lower()).strip("-")
        print("\t\t\tSettingsSection(")
        print(f"\t\t\t\tid: {swift_string(section_id)},")
        print(f"\t\t\t\ttitle: {swift_string(chinese.get(topic, topic))},")
        print(f"\t\t\t\ticon: {swift_string(icons.get(topic, 'gear'))},")
        print("\t\t\t\tfields: [")
        for key, description, scope, meta in sorted(entries):
            kind, options = classify(meta.get("type", ""))
            help_text = clean_help(meta.get("help") or description)
            scope_note = "只对 Managed（组织下发）有意义" if "Managed" in scope and "Any file" not in scope else None
            tail = f", scope: {swift_string(scope_note)}" if scope_note else ""
            key_literal, help_literal = swift_string(key), swift_string(help_text)
            if kind == "bool":
                fallback = fallback_literal("bool", meta.get("default", ""))
                print(f"\t\t\t\t\tboolField({key_literal}, {key_literal}, fallback: {fallback}, {help_literal}{tail}),")
            elif kind == "int":
                fallback = fallback_literal("int", meta.get("default", ""))
                print(f"\t\t\t\t\tintField({key_literal}, {key_literal}, fallback: {fallback}, {help_literal}{tail}),")
            elif kind == "choice":
                opts = ", ".join(swift_string(o) for o in options)
                fallback = fallback_literal("choice", meta.get("default", "")) or options[0]
                print(f"\t\t\t\t\tchoiceField({key_literal}, {key_literal}, options: [{opts}], fallback: {swift_string(fallback)}, {help_literal}{tail}),")
            elif kind == "list":
                print(f"\t\t\t\t\tlistField({key_literal}, {key_literal}, {help_literal}),")
            elif kind == "json":
                print(f"\t\t\t\t\tjsonField({key_literal}, {key_literal}, {help_literal}),")
            else:
                print(f"\t\t\t\t\ttextField({key_literal}, {key_literal}, \"\", {help_literal}{tail}),")
            total += 1
        print("\t\t\t\t]\n\t\t\t),")

    print("\t\t]\n\t)")
    print("}")
    print(f"// generated {total} keys across {len(grouped)} topic(s)", file=sys.stderr)


if __name__ == "__main__":
    main()
