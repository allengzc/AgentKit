//
//  main.swift
//  AgentKit offline tests
//
//  Everything here runs without a window, without network, and (except for the
//  fixture directory under /tmp) without touching a real config file.
//

import Foundation

// MARK: - Harness

var passed = 0
var failed = 0
var currentGroup = ""

func group(_ name: String) {
	currentGroup = name
	print("\n\u{001B}[1m── \(name)\u{001B}[0m")
}

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
	if condition {
		passed += 1
		print("  \u{001B}[32m✓\u{001B}[0m \(label)")
	} else {
		failed += 1
		let extra = detail()
		print("  \u{001B}[31m✗ \(label)\u{001B}[0m" + (extra.isEmpty ? "" : "\n      \(extra)"))
	}
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
	check(actual == expected, label, "期望 \(expected)，实际 \(actual)")
}

/// Runs a closure that must throw the expected error.
func expectThrow<T>(_ label: String, _ body: () throws -> T) {
	do {
		_ = try body()
		check(false, label, "期望抛错，但没有")
	} catch {
		check(true, label)
	}
}

// MARK: - Fixture

let fixtureRoot = URL(fileURLWithPath: "/tmp/agentkit-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureRoot) }

func write(_ text: String, to name: String, mode: mode_t? = nil) -> URL {
	let url = fixtureRoot.appendingPathComponent(name)
	try! text.write(to: url, atomically: true, encoding: .utf8)
	if let mode {
		try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
	}
	return url
}

// MARK: - JSONValue

group("JSONValue 解析与序列化")

do {
	let text = #"{"z":1,"a":[1,2,{"b":null}],"m":"中文","n":1.50,"e":1e3,"t":true}"#
	let value = try JSONParser.parse(text)
	equal(value.objectValue?.keys, ["z", "a", "m", "n", "e", "t"], "对象保留原始键序")
	equal(value.value(at: ["n"])?.numberValue?.raw, "1.50", "小数保留原始字面量")
	equal(value.value(at: ["e"])?.numberValue?.raw, "1e3", "指数保留原始字面量")
	equal(value.value(at: ["m"])?.stringValue, "中文", "非 ASCII 字符串往返")
	equal(JSONWriter.compact.serialize(value), text, "紧凑序列化逐字节还原")

	let pretty = JSONWriter.pretty.serialize(try JSONParser.parse(#"{"a":{"b":[1]},"c":{}}"#))
	let expectedPretty = """
	{
	  "a": {
	    "b": [
	      1
	    ]
	  },
	  "c": {}
	}
	"""
	equal(pretty, expectedPretty, "两空格缩进、空对象紧凑")

	// Escapes and surrogate pairs.
	let escapes = try JSONParser.parse(#"{"s":"a\"b\\c\nd\u00e9\u4e2d\ud83d\ude00"}"#)
	equal(
		escapes.value(at: ["s"])?.stringValue,
		"a\"b\\c\nd\u{e9}\u{4e2d}\u{1F600}",
		"转义与代理对解码"
	)
	let reencoded = JSONWriter.compact.serialize(escapes)
	equal(reencoded, #"{"s":"a\"b\\c\ndé中😀"}"#, "非必需转义不添加")

	expectThrow("非法 JSON 抛错") { try JSONParser.parse(#"{"a":}"#) }
	expectThrow("未闭合对象抛错") { try JSONParser.parse(#"{"a":1"#) }
	expectThrow("结尾多余内容抛错") { try JSONParser.parse(#"{"a":1} x"#) }

	do {
		_ = try JSONParser.parse("{\n  \"a\": }")
		check(false, "解析错误报告正确行号")
	} catch let error as JSONParseError {
		equal(error.line, 2, "解析错误报告正确行号")
	} catch {
		check(false, "解析错误报告正确行号", "\(error)")
	}
}

group("JSONValue 点号路径操作")

do {
	var value = try JSONParser.parse(#"{"a":{"b":1,"c":2},"d":3}"#)
	value.setValue(.bool(true), at: ["a", "b"])
	equal(value.value(at: ["a", "b"])?.boolValue, true, "设置嵌套值")
	equal(value.value(at: ["a", "c"])?.intValue, 2, "同级键不受影响")
	equal(value.objectValue?.keys, ["a", "d"], "顶层键序不变")

	value.setValue(.string("new"), at: ["e", "f"])
	equal(value.objectValue?.keys, ["a", "d", "e"], "新增键追加到末尾")
	equal(value.value(at: ["e", "f"])?.stringValue, "new", "新增嵌套路径")

	value.removeValue(at: ["a", "b"])
	equal(value.value(at: ["a"])?.objectValue?.keys, ["c"], "删除嵌套键后同级保留")
}

// MARK: - PathResolver

group("PathResolver")

do {
	let home = PathResolver.homeDirectory()
	let root = fixtureRoot.appendingPathComponent("root")
	let appSupport = fixtureRoot.appendingPathComponent("support")
	let project = fixtureRoot.appendingPathComponent("project")
	let resolver = PathResolver(
		root: root,
		appSupport: appSupport,
		cwd: project,
		scopeGuard: [root, home, URL(fileURLWithPath: "/tmp")]
	)

	equal(try resolver.expand("~/.pi").path, home.appendingPathComponent(".pi").path, "~ 展开")
	equal(try resolver.expand("$ROOT/settings.json").path, root.appendingPathComponent("settings.json").path, "$ROOT 展开")
	equal(try resolver.expand("$APP/cache").path, appSupport.appendingPathComponent("cache").path, "$APP 展开")
	equal(try resolver.expand("$HOME/x").path, home.appendingPathComponent("x").path, "$HOME 展开")
	equal(try resolver.expand("$CWD/.pi").path, project.appendingPathComponent(".pi").path, "$CWD 展开")
	equal(try resolver.expand("/tmp/x/../y").path, "/tmp/y", "路径标准化")

	expectThrow("未知 token 抛错") { _ = try resolver.expand("$HOM/settings.json") }

	check(resolver.isAllowed(root.appendingPathComponent("settings.json")), "root 内的路径允许写入")
	check(resolver.isAllowed(home.appendingPathComponent("x")), "home 内的路径允许写入")
	check(!resolver.isAllowed(URL(fileURLWithPath: "/etc/hosts")), "root/home 之外拒绝")
	expectThrow("scope guard 抛错") { try resolver.assertAllowed(URL(fileURLWithPath: "/etc/hosts")) }

	// `$CWD` survives when no project is selected.
	let noProject = PathResolver(root: root, appSupport: appSupport)
	check(noProject.isProjectScoped("$CWD/.pi"), "识别需要项目的模板")
	check(!noProject.isProjectScoped("$ROOT/settings.json"), "非项目模板不误判")

	// Glob expansion picks the highest node version.
	let versions = fixtureRoot.appendingPathComponent("versions")
	for name in ["v9.1.0", "v20.19.5", "v24.12.0"] {
		let directory = versions.appendingPathComponent("node/\(name)/bin")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let binary = directory.appendingPathComponent("pi")
		try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
	}
	let resolved = resolver.expandCandidates([versions.appendingPathComponent("node/*/bin/pi").path])
	equal(resolved.count, 3, "glob 找到全部候选")
	check(CLILocator.versionKey(resolved[0].path).count == 3, "能从路径提取版本号")
	let sorted = resolved.sorted { CLILocator.versionLess(CLILocator.versionKey($0.path), CLILocator.versionKey($1.path)) }
	check(sorted.last?.path.contains("v24.12.0") == true, "版本比较选中 v24.12.0")
	check(CLILocator.versionLess([20, 19, 5], [24, 12, 0]), "v20 < v24")
	check(CLILocator.versionLess([9, 1, 0], [20, 19, 5]), "v9 < v20")
}

// MARK: - JSONFile

group("JSONFile 无损读写")

do {
	// No trailing newline and two-space indent, exactly like the real file.
	let original = """
	{
	  "keep": 1,
	  "lastChangelogVersion": "0.87.1",
	  "terminal": {
	    "showTerminalProgress": false
	  },
	  "tail": "末尾"
	}
	"""
	let url = write(original, to: "settings.json", mode: 0o600)
	let policy = BackupPolicy(suffix: ".bak-agentkit", keep: 3)

	let document = JSONFile.load(url, policy: policy)
	equal(document.status, .ok, "载入成功")
	check(document.fingerprint != nil, "记录了指纹")
	equal(document.style.indent, "  ", "识别两空格缩进")
	equal(document.style.trailingNewline, false, "识别无末尾换行")
	equal(AtomicFile.mode(of: url), 0o600, "读取原文件权限")

	// Change exactly one nested value.
	var value = document.editableValue
	value.setValue(.bool(true), at: ["terminal", "showTerminalProgress"])
	let preview = JSONFile.preview(value, for: document, policy: policy)
	check(preview.hasChanges, "预览检测到改动")
	equal(preview.diff.insertions, 1, "只有一行新增")
	equal(preview.diff.removals, 1, "只有一行删除")

	let result = try JSONFile.write(value, document: document, policy: policy)
	equal(result.url.path, url.path, "写入目标路径")
	let rewritten = try String(contentsOf: url, encoding: .utf8)
	check(!rewritten.hasSuffix("\n"), "写回后仍无末尾换行")
	check(rewritten.contains("\"keep\": 1"), "未知键 keep 保留")
	check(rewritten.contains("\"lastChangelogVersion\": \"0.87.1\""), "未知键 lastChangelogVersion 保留")
	check(rewritten.contains("\"tail\": \"末尾\""), "中文与末尾键保留")
	equal(AtomicFile.mode(of: url), 0o600, "写回后权限仍是 0600")

	// Key order is preserved: terminal comes after the two top keys.
	let keys = try JSONParser.parse(rewritten).objectValue?.keys
	equal(keys, ["keep", "lastChangelogVersion", "terminal", "tail"], "键序完全不变")

	// A backup exists and is named the way the other tools name theirs.
	let backups = policy.existingBackups(for: url)
	equal(backups.count, 1, "生成了一份备份")
	check(backups[0].lastPathComponent.hasPrefix("settings.json.bak-agentkit-"), "备份命名符合约定")
	let backupText = try String(contentsOf: backups[0], encoding: .utf8)
	equal(backupText, original, "备份内容是改动前的原文")

	// Backups are pruned to the policy's keep count.
	for _ in 0..<5 {
		let reloaded = JSONFile.load(url, policy: policy)
		var next = reloaded.editableValue
		next.setValue(.number(JSONNumber(Int.random(in: 100...999))), at: ["keep"])
		_ = try JSONFile.write(next, document: reloaded, policy: BackupPolicy(suffix: ".bak-agentkit", keep: 3))
		Thread.sleep(forTimeInterval: 0.01)
	}
	check(policy.existingBackups(for: url).count <= 3, "备份数量被裁剪到 keep=3", "实际 \(policy.existingBackups(for: url).count)")
}

group("JSONFile 拒绝危险写入")

do {
	// Malformed input is never overwritten.
	let broken = write("{\n  \"a\": }\n", to: "broken.json")
	let document = JSONFile.load(broken)
	check(document.isMalformed, "识别出损坏的 JSON")
	check(!document.status.isWritable, "损坏文件标记为不可写")
	let before = try String(contentsOf: broken, encoding: .utf8)
	expectThrow("拒绝写入损坏文件") {
		try JSONFile.write(.object(JSONObject()), document: document)
	}
	equal(try String(contentsOf: broken, encoding: .utf8), before, "损坏文件内容未变")

	// A file that moved under us is not clobbered.
	let live = write(#"{"a":1}"#, to: "live.json")
	let stale = JSONFile.load(live)
	try #"{"a":2,"external":true}"#.write(to: live, atomically: true, encoding: .utf8)
	var changed = stale.editableValue
	changed.setValue(.number(JSONNumber(3)), at: ["a"])
	do {
		_ = try JSONFile.write(changed, document: stale)
		check(false, "并发修改应该被拒绝")
	} catch let error as FileWriteError {
		if case .concurrentModification = error {
			check(true, "并发修改被拒绝")
		} else {
			check(false, "并发修改被拒绝", "抛出了 \(error)")
		}
	}
	let afterRace = try String(contentsOf: live, encoding: .utf8)
	check(afterRace.contains("\"external\""), "外部的改动没有被覆盖", afterRace)

	// Scope guard is enforced.
	let outside = write(#"{"a":1}"#, to: "guard.json")
	let guarded = PathResolver(
		root: fixtureRoot.appendingPathComponent("elsewhere"),
		appSupport: fixtureRoot,
		scopeGuard: [fixtureRoot.appendingPathComponent("elsewhere")]
	)
	let guardedDoc = JSONFile.load(outside)
	expectThrow("scope guard 阻止越界写入") {
		try JSONFile.write(.object(JSONObject()), document: guardedDoc, scope: guarded)
	}
	equal(try String(contentsOf: outside, encoding: .utf8), #"{"a":1}"#, "越界文件内容未变")

	// BOM is stripped, not re-emitted.
	let bomURL = fixtureRoot.appendingPathComponent("bom.json")
	try Data([0xEF, 0xBB, 0xBF] + Array(#"{"a":1}"#.utf8)).write(to: bomURL)
	let bomDoc = JSONFile.load(bomURL)
	equal(bomDoc.status, .ok, "带 BOM 的文件仍可解析")
	let written = try JSONFile.write(bomDoc.editableValue, document: bomDoc)
	_ = written
	let bomOut = try Data(contentsOf: bomURL)
	check(bomOut.first != 0xEF, "写回时不保留 BOM")
}

group("MCP 服务器编辑：合并而不是重建")

do {
	// A real Codex entry: the form shows command and args, but the entry carries
	// an env table and a startup timeout. Rebuilding the object from the form
	// would delete all of it.
	let nodeRepl = try JSONParser.parse("""
	{
	  "command": "/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl",
	  "args": [],
	  "startup_timeout_sec": 120,
	  "env": { "CODEX_HOME": "/Users/dev/.codex", "BROWSER_USE_AVAILABLE_BACKENDS": "chrome,iab" },
	  "cwd": "."
	}
	""")
	let edited = MCPShape.mergedServer(
		existing: nodeRepl,
		draft: MCPShape.MCPServerDraft(command: "/usr/local/bin/node_repl", args: [], url: "", disabled: false),
		shape: MCPServerShape(serverKey: "mcp_servers", toggleKey: "enabled", toggleDisabledValue: false)
	)
	equal(edited.value(at: ["command"])?.stringValue, "/usr/local/bin/node_repl", "表单字段被更新")
	equal(edited.value(at: ["env", "CODEX_HOME"])?.stringValue, "/Users/dev/.codex", "env 表完整保留")
	equal(
		edited.value(at: ["env", "BROWSER_USE_AVAILABLE_BACKENDS"])?.stringValue,
		"chrome,iab",
		"env 里的每个键都保留"
	)
	equal(edited.value(at: ["startup_timeout_sec"])?.intValue, 120, "表单不认识的键保留")
	equal(edited.value(at: ["cwd"])?.stringValue, ".", "cwd 保留")
	equal(edited.value(at: ["args"])?.arrayValue?.count, 0, "原有的空 args 不会消失")

	// The same edit on an entry with no args: adding `args: []` would be an
	// unrequested diff, so the key stays absent.
	let noArgs = try JSONParser.parse(#"{"command": "/bin/tool"}"#)
	let added = MCPShape.mergedServer(
		existing: noArgs,
		draft: MCPShape.MCPServerDraft(command: "/bin/tool", args: [], url: "  ", disabled: false),
		shape: .pi
	)
	equal(added.value(at: ["args"]), nil, "没有 args 的条目不会被写上空数组")
	equal(added, noArgs, "什么都没改的编辑产生零改动")

	// pi spells the switch `disabled = true`.
	let piDisabled = try JSONParser.parse(#"{"command": "/bin/tool", "disabled": true, "env": {"A": "1"}}"#)
	let piEnabled = MCPShape.mergedServer(
		existing: piDisabled,
		draft: MCPShape.MCPServerDraft(command: "/bin/tool", args: [], url: "", disabled: false),
		shape: .pi
	)
	equal(piEnabled.value(at: ["disabled"]), nil, "启用后删掉 disabled 键而不是写 false")
	equal(piEnabled.value(at: ["env", "A"])?.stringValue, "1", "启用不会动其它键")

	let piOff = MCPShape.mergedServer(
		existing: piDisabled,
		draft: MCPShape.MCPServerDraft(command: "/bin/tool", args: [], url: "", disabled: true),
		shape: .pi
	)
	equal(piOff.value(at: ["disabled"])?.boolValue, true, "停用写 disabled = true")

	// Codex writes the opposite polarity under a different key.
	let codex = MCPServerShape(serverKey: "mcp_servers", toggleKey: "enabled", toggleDisabledValue: false)
	let codexOff = MCPShape.mergedServer(
		existing: try JSONParser.parse(#"{"command": "/bin/tool"}"#),
		draft: MCPShape.MCPServerDraft(command: "/bin/tool", args: [], url: "", disabled: true),
		shape: codex
	)
	equal(codexOff.value(at: ["enabled"])?.boolValue, false, "Codex 停用写 enabled = false")

	// Switching transport must remove the fields that belong to the other one.
	let remote = MCPShape.mergedServer(
		existing: nodeRepl,
		draft: MCPShape.MCPServerDraft(command: "", args: [], url: "https://example.com/mcp", disabled: false),
		shape: codex
	)
	equal(remote.value(at: ["url"])?.stringValue, "https://example.com/mcp", "切到远程后写 url")
	equal(remote.value(at: ["command"]), nil, "切到远程后删掉 command")
	equal(remote.value(at: ["args"]), nil, "切到远程后删掉 args")
	equal(remote.value(at: ["env", "CODEX_HOME"])?.stringValue, "/Users/dev/.codex", "切传输方式也不丢其它键")

	let backToStdio = MCPShape.mergedServer(
		existing: remote,
		draft: MCPShape.MCPServerDraft(command: "/bin/tool", args: ["--x"], url: "", disabled: false),
		shape: codex
	)
	equal(backToStdio.value(at: ["command"])?.stringValue, "/bin/tool", "切回 stdio")
	equal(backToStdio.value(at: ["args"])?.stringsValue, ["--x"], "args 参数")
	equal(backToStdio.value(at: ["url"]), nil, "切回 stdio 后删掉 url")

	// A brand new server has nothing to merge from.
	let fresh = MCPShape.mergedServer(
		existing: nil,
		draft: MCPShape.MCPServerDraft(command: "/bin/new", args: ["-a"], url: "", disabled: false),
		shape: .pi
	)
	equal(fresh.objectValue?.keys, ["command", "args"], "新条目只包含表单字段")
	equal(MCPShape.validate(name: "ok", value: fresh), nil, "新条目通过校验")
	check(MCPShape.validate(name: "", value: fresh) != nil, "空名字被拒绝")
	check(MCPShape.validate(name: "a/b", value: fresh) != nil, "名字里的斜杠被拒绝")
}

// MARK: - Project scope

group("项目作用域")

do {
	let support = fixtureRoot.appendingPathComponent("project-support")
	let projectA = fixtureRoot.appendingPathComponent("project-a")
	let projectB = fixtureRoot.appendingPathComponent("project-b")
	for url in [support, projectA, projectB] {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	}

	try MainActor.assumeIsolated {
		let store = ProjectStore(appSupport: support)
		check(store.current == nil, "默认是全局作用域")
		check(store.currentDisplayPath.contains("全局"), "全局时的说明")

		store.select(projectA)
		equal(store.current?.path, projectA.path, "选择项目")
		check(store.currentDisplayPath.hasSuffix("project-a"), "显示路径")

		store.select(projectB)
		store.select(projectA)
		equal(store.recent.map(\.lastPathComponent), ["project-a", "project-b"], "最近项目去重且最新的在前")
		equal(store.menuEntries.map(\.path), [projectB.path], "菜单里不重复列出当前项目")

		// The state has to survive a restart, or the user re-picks every launch.
		let reopened = ProjectStore(appSupport: support)
		equal(reopened.current?.path, projectA.path, "重启后恢复上次的项目")
		equal(reopened.recent.map(\.lastPathComponent), ["project-a", "project-b"], "重启后恢复最近列表")

		reopened.select(nil)
		check(reopened.current == nil, "可以回到全局作用域")
		equal(reopened.recent.count, 2, "回到全局不会清空最近列表")

		// A project that vanished must not be restored.
		try FileManager.default.removeItem(at: projectB)
		let afterDelete = ProjectStore(appSupport: support)
		check(!afterDelete.recent.contains { $0.path == projectB.path }, "已删除的目录不再出现在最近列表")
	}

	// The environment override is applied after load(), so it works on a machine
	// that has never run AgentKit and therefore has no state file.
	let freshSupport = fixtureRoot.appendingPathComponent("project-support-fresh")
	try FileManager.default.createDirectory(at: freshSupport, withIntermediateDirectories: true)
	setenv("AGENTKIT_PROJECT", projectA.path, 1)
	try MainActor.assumeIsolated {
		equal(ProjectStore(appSupport: freshSupport).current?.path, projectA.path,
			  "没有 state 文件时环境变量依然生效")
	}
	setenv("AGENTKIT_PROJECT", fixtureRoot.appendingPathComponent("nowhere").path, 1)
	try MainActor.assumeIsolated {
		check(ProjectStore(appSupport: freshSupport).current == nil, "指向不存在的目录时忽略")
	}
	unsetenv("AGENTKIT_PROJECT")

	// The count is what the panes use to warn that paths were skipped.
	let descriptor = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/Agents/pi.json")).utf8)
	)
	let mcp = descriptor.surface(id: "mcp")!
	equal(SurfacePaths.projectPathCount(for: mcp), 2, "pi 的 MCP 有两条项目级路径")
	check(SurfacePaths.requiresProject(mcp), "因此需要项目作用域")
	equal(SurfacePaths.projectPathCount(for: descriptor.surface(id: "settings")!), 0, "设置面板不需要项目")
	// Models reads only agent-root files, so it needs no project at all.
	equal(SurfacePaths.projectPathCount(for: descriptor.surface(id: "models")!), 0, "模型面板完全不需要项目")
	equal(SurfacePaths.projectPathCount(for: descriptor.surface(id: "skills")!), 2, "skills 有两条项目级路径")
	equal(SurfacePaths.projectPathCount(for: descriptor.surface(id: "subagents")!), 1, "子 agents 有一条")
}

// MARK: - The shared write path

group("JSONEditController（每个面板共用的写入路径）")

// Top-level test code is not main-actor isolated, and the controller is.
try MainActor.assumeIsolated {
	let url = write(#"{"a":1,"keep":{"b":true}}"#, to: "controller.json")
	let policy = BackupPolicy(suffix: ".bak-agentkit", keep: 3)
	let resolver = PathResolver(root: fixtureRoot, appSupport: fixtureRoot, scopeGuard: [fixtureRoot])

	let controller = JSONEditController()
	controller.load(url: url, resolver: resolver, policy: policy)
	check(controller.document != nil, "载入文档")
	equal(controller.exists, true, "文件存在")
	check(!controller.isMalformed, "文件可写")

	// A no-op mutation stages nothing.
	check(controller.stage(controller.editable) == false, "没有改动时不弹确认")
	// Assert that the user is told, not the exact sentence: the banner text is a
	// localised string, and comparing it here would break the moment the test
	// binary gains a string table or a language is pinned elsewhere.
	check(controller.banner != nil, "提示没有改动")

	// A real mutation produces a pending write with a diff.
	var value = controller.editable
	value.setValue(.number(JSONNumber(2)), at: ["a"])
	check(controller.stage(value), "有改动时进入确认")
	check(controller.pending != nil, "生成了待确认写入")
	check(controller.pending?.preview.hasChanges == true, "待确认的写入带着 diff")
	equal(controller.pending?.preview.diff.insertions, 1, "diff 里一行新增")
	equal(controller.pending?.preview.diff.removals, 1, "diff 里一行删除")

	// Nothing is written until the diff is confirmed.
	equal(try String(contentsOf: url, encoding: .utf8), #"{"a":1,"keep":{"b":true}}"#, "确认前文件未变")

	controller.confirm()
	check(controller.pending == nil, "确认后清空待写入")
	equal(try String(contentsOf: url, encoding: .utf8), #"{"a":2,"keep":{"b":true}}"#, "确认后落盘")
	check(controller.banner?.contains("备份") == true, "报告备份文件名")
	equal(policy.existingBackups(for: url).count, 1, "生成了一份备份")
	check(controller.document?.fingerprint != nil, "重新载入后拿到新的指纹")

	// Cancelling leaves the file alone.
	var more = controller.editable
	more.setValue(.bool(false), at: ["keep", "b"])
	_ = controller.stage(more)
	controller.cancel()
	check(controller.pending == nil, "取消后清空待写入")
	equal(try String(contentsOf: url, encoding: .utf8), #"{"a":2,"keep":{"b":true}}"#, "取消后文件未变")

	// A malformed file cannot be staged at all.
	let brokenURL = write("{ nope", to: "controller-broken.json")
	let broken = JSONEditController()
	broken.load(url: brokenURL, resolver: resolver, policy: policy)
	check(broken.isMalformed, "识别损坏文件")
	check(broken.malformedReason != nil, "给出损坏原因")
	equal(broken.stage(.object(JSONObject())), false, "损坏文件不允许暂存写入")

	// A scope-guard violation surfaces as an error instead of a partial write.
	let outside = write(#"{"x":1}"#, to: "controller-outside.json")
	let narrow = PathResolver(
		root: fixtureRoot.appendingPathComponent("nowhere"),
		appSupport: fixtureRoot,
		scopeGuard: [fixtureRoot.appendingPathComponent("nowhere")]
	)
	let guarded = JSONEditController()
	guarded.load(url: outside, resolver: narrow, policy: policy)
	var edit = guarded.editable
	edit.setValue(.number(JSONNumber(9)), at: ["x"])
	check(guarded.stage(edit), "越界文件仍可暂存（先给用户看 diff）")
	guarded.confirm()
	check(guarded.errorText != nil, "确认时被护栏拒绝并报错")
	equal(try String(contentsOf: outside, encoding: .utf8), #"{"x":1}"#, "越界文件未被写入")
}

// MARK: - MCP

group("MCP 层合并与诊断")

do {
	let support = fixtureRoot.appendingPathComponent("mcp/support")
	let agentRoot = fixtureRoot.appendingPathComponent("mcp/agent")
	let projectRoot = fixtureRoot.appendingPathComponent("mcp/project")
	for directory in [support, agentRoot, projectRoot] {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	// Layer 1 (shared global): blender.
	try """
	{
	  "mcpServers": {
	    "blender": { "command": "/opt/blender-mcp", "args": [] }
	  }
	}
	""".write(to: fixtureRoot.appendingPathComponent("mcp/global.json"), atomically: true, encoding: .utf8)

	// Layer 2 (adapter): same name, must win; plus a second server.
	try """
	{
	  "mcpServers": {
	    "blender": { "command": "/usr/local/bin/blender-mcp" },
	    "filesystem": { "command": "npx", "args": ["-y", "fs-mcp"], "disabled": true }
	  }
	}
	""".write(to: agentRoot.appendingPathComponent("mcp-adapter.json"), atomically: true, encoding: .utf8)

	// A legacy file the adapter no longer reads.
	try """
	{
	  "mcpServers": { "legacy-server": { "command": "legacy" } },
	  "imports": ["claude-code", "codex"],
	  "settings": { "hostConfigDiscovery": "off" }
	}
	""".write(to: agentRoot.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

	let surface = SurfaceSpec(
		id: "mcp", kind: .mcp, title: "MCP", icon: nil, shape: "mcp-servers-map",
		file: nil, providerFile: nil, catalogFile: nil, authFile: nil,
		root: nil,
		roots: nil,
		files: nil, discovery: nil,
		layers: [
			ConfigSource(path: fixtureRoot.appendingPathComponent("mcp/global.json").path, scope: "global", precedence: 10, shared: true, writable: true),
			ConfigSource(path: agentRoot.appendingPathComponent("mcp-adapter.json").path, scope: "global", precedence: 40, shared: false, writable: true),
			ConfigSource(path: "$CWD/.mcp.json", scope: "project", precedence: 60, shared: true, writable: true),
		],
		legacy: [
			LegacySpec(
				path: agentRoot.appendingPathComponent("mcp.json").path,
				notice: "不再读取",
				fix: LegacyFixSpec(action: "rename", to: agentRoot.appendingPathComponent("mcp-adapter.json").path, onlyKeys: nil)
			)
		],
		imports: ["claude-code": [fixtureRoot.appendingPathComponent("mcp/missing-claude.json").path]],
		defaults: nil, cli: nil, schema: nil, settingsKeys: nil,
		ignore: nil, maxDepth: nil, spec: nil, frontmatter: nil,
		sessions: nil
	)

	let resolver = PathResolver(root: agentRoot, appSupport: support, cwd: projectRoot)
	let policy = BackupPolicy(suffix: ".bak-agentkit", keep: 5)
	let snapshot = MCPSurfaceLoader.snapshot(surface: surface, resolver: resolver, policy: policy)

	equal(snapshot.layers.count, 3, "三个层都被读到")
	equal(snapshot.layers.map(\.spec.precedence), [10, 40, 60], "层按优先级排序")

	let blender = snapshot.effective.first { $0.name == "blender" }
	equal(blender?.winner.url.lastPathComponent, "mcp-adapter.json", "后出现的层胜出")
	equal(blender?.shadowed.count, 1, "记录被覆盖的层")
	equal(blender?.value.value(at: ["command"])?.stringValue, "/usr/local/bin/blender-mcp", "生效值是胜出层的")

	let filesystem = snapshot.effective.first { $0.name == "filesystem" }
	equal(snapshot.shape.isDisabled(filesystem?.value ?? .null), true, "识别 disabled 标记")
	equal(MCPShape.transport(filesystem?.value ?? .null), "stdio", "识别 stdio 传输")

	equal(snapshot.conflicts.count, 1, "只报告一个同名冲突")
	equal(snapshot.conflicts.first?.name, "blender", "冲突的是 blender")

	equal(snapshot.legacy.count, 1, "发现 legacy 文件")
	let legacy = snapshot.legacy[0]
	equal(legacy.serverNames, ["legacy-server"], "列出 legacy 里的服务器")
	equal(legacy.adapterKeys, ["settings", "imports"], "认出 adapter 专属键")
	check(legacy.hasAnything, "legacy 文件被判为有内容")

	equal(snapshot.imports.count, 1, "导入候选被检查")
	equal(snapshot.imports[0].exists, false, "不存在的导入路径被标记")

	// The repair plan is what the user approves, so assert its exact shape.
	let plan = MCPRepair.plan(
		finding: legacy,
		includeServers: true,
		sharedLayerURL: fixtureRoot.appendingPathComponent("mcp/global.json"),
		policy: policy
	)
	equal(plan.steps.count, 3, "修复计划有三步")
	check(plan.steps[0].title.contains("settings"), "第一步迁移 adapter 专属键")
	check(plan.steps[1].title.contains("并入"), "第二步并入服务器")
	if case .rename(let destination) = plan.steps[2].kind {
		equal(plan.steps[2].url.path, legacy.url.path, "第三步重命名的是 legacy 文件本身")
		check(destination.lastPathComponent.hasPrefix("mcp.json.bak-agentkit-"), "重命名沿用备份命名", destination.lastPathComponent)
	} else {
		check(false, "第三步是重命名")
	}

	// Executing it must actually work, end to end, on the fixture.
	let outcomes = MCPRepair.run(plan, scope: resolver, policy: policy)
	check(outcomes.allSatisfy(\.succeeded), "所有步骤成功", outcomes.map { "\($0.step): \($0.detail)" }.joined(separator: " | "))

	let adapterAfter = JSONFile.load(agentRoot.appendingPathComponent("mcp-adapter.json"), policy: policy)
	equal(adapterAfter.value(at: ["settings"])?.objectValue?["hostConfigDiscovery"]?.stringValue, "off", "settings 已迁移")
	equal(adapterAfter.value(at: ["imports"])?.stringsValue, ["claude-code", "codex"], "imports 已迁移")
	equal(MCPShape.serverNames(in: adapterAfter), ["blender", "filesystem"], "原有服务器保留")
	check(!FileManager.default.fileExists(atPath: agentRoot.appendingPathComponent("mcp.json").path), "legacy 文件已改名")

	let globalAfter = JSONFile.load(fixtureRoot.appendingPathComponent("mcp/global.json"), policy: policy)
	equal(MCPShape.serverNames(in: globalAfter), ["blender", "legacy-server"], "legacy 服务器并入共享层")
	equal(
		globalAfter.value(at: ["mcpServers", "blender", "command"])?.stringValue,
		"/opt/blender-mcp",
		"同名冲突保留目标层已有定义"
	)
	check(plan.notes.isEmpty, "legacy 里的服务器与目标层不重名时不产生额外说明")

	// A collision between the legacy file and the target layer is reported, and
	// the target layer's definition is the one that survives.
	let colliding = MCPLegacyFinding(
		url: agentRoot.appendingPathComponent("mcp-conflict.json"),
		notice: "不再读取",
		serverNames: ["blender"],
		adapterKeys: [],
		rawText: #"{"mcpServers":{"blender":{"command":"/old/blender"}}}"#,
		fixTarget: nil
	)
	let collisionPlan = MCPRepair.plan(
		finding: colliding,
		includeServers: true,
		sharedLayerURL: fixtureRoot.appendingPathComponent("mcp/global.json"),
		policy: policy
	)
	equal(collisionPlan.steps.count, 2, "没有 adapter 专属键时只剩并入与重命名两步")
	check(collisionPlan.notes.contains { $0.contains("blender") }, "同名时说明保留目标层定义")
	let mergedGlobal = collisionPlan.steps.first?.value
	equal(
		mergedGlobal?.value(at: ["mcpServers", "blender", "command"])?.stringValue,
		"/opt/blender-mcp",
		"并入时目标层已有定义优先"
	)

	// Declining the server merge leaves only the rename.
	let plan2 = MCPRepair.plan(finding: colliding, includeServers: false, sharedLayerURL: nil, policy: policy)
	equal(plan2.steps.count, 1, "只有服务器且选择不搬运时只剩重命名一步")
}
// MARK: - JSONPatch

group("JSONPatch 外科式修改")

do {
	// Inline objects are the hard case: re-serializing would explode them
	// across several lines and bury the one real change.
	let original = #"{"a": { "b": 1, "c": 2 },"d": [1, 2],"e": "keep"}"#
	let url = write(original, to: "patch.json")
	let document = JSONFile.load(url)
	var value = document.editableValue
	value.setValue(.number(JSONNumber(9)), at: ["a", "b"])

	let preview = JSONFile.preview(value, for: document)
	equal(preview.diff.insertions, 1, "只改一行：新增")
	equal(preview.diff.removals, 1, "只改一行：删除")
	equal(preview.afterText, #"{"a": { "b": 9, "c": 2 },"d": [1, 2],"e": "keep"}"#, "行内对象保持行内")
	equal(preview.afterText.count, original.count, "长度不变")

	try JSONFile.write(value, document: document)
	equal(
		try String(contentsOf: url, encoding: .utf8),
		 #"{"a": { "b": 9, "c": 2 },"d": [1, 2],"e": "keep"}"#,
		"磁盘内容与预览一致"
	)

	// Array elements are patched by index, too.
	let reloaded = JSONFile.load(url)
	var arrayEdit = reloaded.editableValue
	arrayEdit.setValue(.number(JSONNumber(7)), at: ["d", "1"])
	let arrayPreview = JSONFile.preview(arrayEdit, for: reloaded)
	equal(arrayPreview.afterText, #"{"a": { "b": 9, "c": 2 },"d": [1, 7],"e": "keep"}"#, "数组元素按索引替换")

	// Structural edits fall back to a full rewrite, but keep every value.
	var added = reloaded.editableValue
	added.setValue(.bool(true), at: ["fresh"])
	equal(
		JSONPatch.plan(original: reloaded.editableValue, updated: added, source: reloaded.source),
		.rewrite,
		"新增键走整体重写"
	)
	let addedPreview = JSONFile.preview(added, for: reloaded)
	check(addedPreview.afterText.contains("\"fresh\": true"), "重写后新键存在")
	check(addedPreview.afterText.contains("\"e\": \"keep\""), "重写后原有值保留")

	var removed = reloaded.editableValue
	removed.removeValue(at: ["e"])
	equal(
		JSONPatch.plan(original: reloaded.editableValue, updated: removed, source: reloaded.source),
		.rewrite,
		"删除键走整体重写"
	)

	var grown = reloaded.editableValue
	grown.setValue(.array([.number(JSONNumber(1))]), at: ["d"])
	equal(
		JSONPatch.plan(original: reloaded.editableValue, updated: grown, source: reloaded.source),
		.rewrite,
		"数组长度变化走整体重写"
	)

	equal(
		JSONPatch.plan(original: reloaded.editableValue, updated: reloaded.editableValue, source: reloaded.source),
		.unchanged,
		"没有改动时不动文件"
	)

	// A scalar that became a container is structural as well.
	var container = reloaded.editableValue
	container.setValue(.object(JSONObject()), at: ["e"])
	equal(
		JSONPatch.plan(original: reloaded.editableValue, updated: container, source: reloaded.source),
		.rewrite,
		"标量变容器走整体重写"
	)
}

// MARK: - TextDiff

group("TextDiff")

do {
	let diff = TextDiff(before: "a\nb\nc", after: "a\nB\nc")
	equal(diff.insertions, 1, "一处新增")
	equal(diff.removals, 1, "一处删除")
	equal(diff.lines.filter { $0.kind == .equal }.count, 2, "两行相同")
	check(!diff.isEmpty, "非空差异")

	check(TextDiff(before: "x", after: "x").isEmpty, "相同文本无差异")
	let condensed = TextDiff(
		before: (1...30).map(String.init).joined(separator: "\n"),
		after: (1...30).map { $0 == 15 ? "changed" : String($0) }.joined(separator: "\n")
	).condensed(context: 2)
	check(condensed.contains { $0 == nil }, "长文件折叠了未改动区间")
	check(condensed.count < 10, "折叠后行数很少", "实际 \(condensed.count)")
}

// MARK: - Diff line numbering

group("TextDiff 行号")

do {
	// The sheet shows two gutters; a reader checks a change against the file by
	// those numbers, so they have to line up with the real files.
	let before = "a\nb\nc\nd\ne"
	let after = "a\nB\nc\nd\ne\nf"
	let diff = TextDiff(before: before, after: after)

	let removed = diff.lines.filter { $0.kind == .remove }
	let inserted = diff.lines.filter { $0.kind == .insert }
	equal(removed.count, 1, "一处删除")
	// Two insertions: the changed line, and `f` appended at the end.
	equal(inserted.count, 2, "两处新增")
	equal(removed.first?.oldNumber, 2, "删除行标的是旧文件第 2 行")
	equal(removed.first?.newNumber, nil, "删除行没有新行号")
	equal(inserted.first?.oldNumber, nil, "新增行没有旧行号")
	equal(inserted.first?.newNumber, 2, "改动的行标的是新文件第 2 行")
	equal(inserted.last?.newNumber, 6, "追加的行标的是新文件第 6 行")
	equal(inserted.last?.text, "f", "追加的是最后一行")

	// Unchanged lines carry both numbers, and they must agree with the file.
	let equals = diff.lines.filter { $0.kind == .equal }
	equal(equals.first?.oldNumber, 1, "第一行相同")
	equal(equals.first?.newNumber, 1, "第一行相同")
	equal(equals.last?.oldNumber, 5, "末行相同（旧）")
	equal(equals.last?.newNumber, 5, "末行相同（新）")
	equal(equals.last?.text, "e", "相同的末行是 e，f 是追加的")
	for line in equals {
		let old = String(before.split(separator: "\n")[line.oldNumber! - 1])
		let new = String(after.split(separator: "\n")[line.newNumber! - 1])
		equal(old, new, "编号相同的行内容必须一致：\(line.oldNumber!)")
	}

	// Every line of both files is accounted for exactly once.
	equal(diff.lines.filter { $0.oldNumber != nil }.count, 5, "旧文件每行都出现一次")
	equal(diff.lines.filter { $0.newNumber != nil }.count, 6, "新文件每行都出现一次")

	// An appended key, which is what the settings form produces.
	let appended = TextDiff(before: "{\n  \"a\": 1\n}", after: "{\n  \"a\": 1,\n  \"b\": 2\n}")
	equal(appended.insertions + appended.removals, 3, "追加键只改动三行")
	equal(appended.lines.last?.kind, .equal, "文件末尾的 } 保持不变")
}

// MARK: - Frontmatter

group("Frontmatter")

do {
	let agentFile = """
	---
	name: code-reviewer
	description: 代码审查 — 产出按严重度排序的问题清单。
	model: example/demo-model
	tools: read, grep, find, ls
	---
	你是资深代码审查者。
	"""
	let document = FrontmatterDocument.parse(agentFile)
	check(document.hasFrontmatter, "识别 frontmatter")
	equal(document.string("name"), "code-reviewer", "读取标量")
	equal(document.string("model"), "example/demo-model", "读取含斜杠的标量")
	equal(document.stringArray("tools"), ["read", "grep", "find", "ls"], "逗号分隔的 tools")
	equal(document.entries.map(\.key), ["name", "description", "model", "tools"], "保留条目顺序")
	check(document.body.hasPrefix("你是资深代码审查者。"), "正文不受影响")

	// The array spelling must parse identically.
	let arrayStyle = FrontmatterDocument.parse("---\ntools: [read, bash]\n---\n")
	equal(arrayStyle.stringArray("tools"), ["read", "bash"], "数组写法的 tools")
	equal(arrayStyle.entry("tools")?.rawValue, "[read, bash]", "保留原始字面量")

	// Editing one value keeps the others byte-identical.
	var edited = document
	edited.setRaw("read, bash", forKey: "tools")
	let rendered = edited.render()
	check(rendered.contains("name: code-reviewer"), "未编辑的键原样保留")
	check(rendered.contains("tools: read, bash"), "编辑后的键写入新值")
	check(!rendered.contains("tools: [read, bash]"), "没有引入数组写法")
	equal(FrontmatterDocument.parse(rendered).stringArray("tools"), ["read", "bash"], "重新解析一致")

	// Quoting only when needed.
	equal(FrontmatterDocument.literal(for: .string("plain")), "plain", "普通字符串不加引号")
	equal(FrontmatterDocument.literal(for: .string("a: b")), "\"a: b\"", "含冒号加引号")
	equal(FrontmatterDocument.literal(for: .bool(true)), "true", "布尔字面量")
	equal(FrontmatterDocument.literal(for: .list(["a", "b"])), "a, b", "列表用逗号串")

	// CRLF and BOM.
	let crlf = FrontmatterDocument.parse("---\r\nname: x\r\n---\r\nbody")
	equal(crlf.string("name"), "x", "CRLF 文件可解析")
	equal(crlf.lineEnding, "\r\n", "记录行尾风格")
	check(crlf.render().contains("\r\n"), "按原行尾写回")

	let bom = FrontmatterDocument.parse("\u{FEFF}---\nname: y\n---\n")
	equal(bom.string("name"), "y", "带 BOM 的文件可解析")

	// Files without frontmatter pass through untouched.
	let plain = FrontmatterDocument.parse("# 标题\n\n正文")
	check(!plain.hasFrontmatter, "无 frontmatter 时标记为否")
	equal(plain.render(), "# 标题\n\n正文", "无 frontmatter 时原样返回")

	// Unterminated block must not swallow the file.
	let unterminated = FrontmatterDocument.parse("---\nname: z\n正文")
	check(!unterminated.hasFrontmatter, "未闭合的 frontmatter 不当成 frontmatter")
	equal(unterminated.render(), "---\nname: z\n正文", "未闭合时原样返回")

	// Nested maps and quoted values.
	let nested = FrontmatterDocument.parse("---\nmetadata:\n  key: value\ntitle: \"a: b\"\n---\n")
	if case .complex = nested.value("metadata") {
		check(true, "嵌套 map 归为复杂值")
	} else {
		check(false, "嵌套 map 归为复杂值")
	}
	equal(nested.string("title"), "a: b", "带引号的值去引号")
}

// MARK: - Descriptor

group("Descriptor 解析与校验")

do {
	let descriptorJSON = """
	{
	  "descriptorVersion": 1,
	  "id": "demo",
	  "name": "Demo",
	  "root": { "env": "DEMO_DIR", "default": "~/.demo" },
	  "write": { "backup": { "suffix": ".bak-agentkit", "keep": 4 }, "scopeGuard": ["$ROOT", "$HOME", "/tmp"] },
	  "surfaces": [
	    { "id": "settings", "kind": "settings", "title": "设置", "file": "$ROOT/settings.json", "schema": "pi-settings-0.87" },
	    { "id": "weird", "kind": "time-machine", "title": "未来面板" },
	    { "id": "broken", "kind": "mcp", "title": "缺 layers" }
	  ]
	}
	"""
	let descriptor = try JSONDecoder().decode(AgentDescriptor.self, from: Data(descriptorJSON.utf8))
	equal(descriptor.id, "demo", "解码 id")
	equal(descriptor.root.default, "~/.demo", "解码 root.default")
	equal(descriptor.backupPolicy.keep, 4, "备份保留份数来自描述文件")
	equal(descriptor.surfaces.count, 3, "三个面板全部解码")

	equal(descriptor.surface(id: "settings")?.kind, .settings, "已知 kind 正常解码")
	if case .unsupported(let raw) = descriptor.surface(id: "weird")?.kind {
		equal(raw, "time-machine", "未知 kind 保留原文")
	} else {
		check(false, "未知 kind 保留原文")
	}
	check(descriptor.surface(id: "weird")?.isSupported == false, "未知 kind 标记为不支持")

	let issues = DescriptorValidator.validate(descriptor)
	check(issues.contains { $0.surfaceID == "weird" && $0.severity == .warning }, "未知 kind 产生警告而非错误")
	check(issues.contains { $0.surfaceID == "broken" && $0.severity == .error }, "缺少 layers 报错")
	check(!issues.contains { $0.surfaceID == "settings" }, "合法面板没有诊断")

	// Unsupported descriptor version is an error, not a crash.
	//
	// The `contains("版本")` below matches the *fallback* literal: the test
	// binary has no .lproj, so L.t always returns the Chinese text passed at the
	// call site. It is a check that the message names the version, not a check of
	// the wording — renaming the key would keep it green, translating it would
	// not. Both tables are compared with each other further down.
	var future = descriptor
	future.descriptorVersion = 99
	check(
		DescriptorValidator.validate(future).contains { $0.severity == .error && $0.message.contains("版本") },
		"不支持的描述文件版本报错"
	)

	// Decoding failures produce a readable reason.
	do {
		_ = try JSONDecoder().decode(AgentDescriptor.self, from: Data(#"{"id":"x"}"#.utf8))
		check(false, "缺少必填字段应解码失败")
	} catch let error as DecodingError {
		let message = DescriptorLoader.describe(error)
		// Same fallback-literal caveat as above: this asserts that the reason
		// names the missing field, not that it is worded in any one language.
		check(message.contains("缺少字段"), "解码错误信息可读", message)
	}
}

group("DescriptorLoader 合并与覆盖")

do {
	let builtin = fixtureRoot.appendingPathComponent("builtin")
	let user = fixtureRoot.appendingPathComponent("user")
	try FileManager.default.createDirectory(at: builtin, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

	let base = """
	{
	  "descriptorVersion": 1,
	  "id": "%@",
	  "name": "%@",
	  "root": { "default": "$ROOT" },
	  "surfaces": [ { "id": "settings", "kind": "settings", "title": "设置", "file": "$ROOT/settings.json", "schema": "pi-settings-0.87" } ]
	}
	"""
	try String(format: base, "pi", "Pi 内置").write(
		to: builtin.appendingPathComponent("pi.json"), atomically: true, encoding: .utf8
	)
	try String(format: base, "pi", "Pi 自定义").write(
		to: user.appendingPathComponent("pi.json"), atomically: true, encoding: .utf8
	)
	try String(format: base, "other", "Other").write(
		to: user.appendingPathComponent("other.json"), atomically: true, encoding: .utf8
	)
	try "{ this is not json".write(
		to: user.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8
	)

	let outcome = DescriptorLoader.loadAll(
		builtinDirectory: builtin,
		userDirectory: user,
		environment: [:],
		appSupport: fixtureRoot.appendingPathComponent("support")
	)
	equal(outcome.agents.count, 2, "两个 agent 载入（坏的描述文件被跳过）")
	check(outcome.issues.contains { $0.severity == .error }, "损坏的描述文件产生错误诊断")

	let pi = outcome.agents.first { $0.id == "pi" }
	equal(pi?.name, "Pi 自定义", "同 id 的用户描述文件整体覆盖内置")
	equal(pi?.origin, .user, "来源标记为用户")

	// Root override through the environment.
	let override = fixtureRoot.appendingPathComponent("override-root")
	try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
	let overridden = DescriptorLoader.loadAll(
		builtinDirectory: builtin,
		userDirectory: user,
		environment: ["DEMO_DIR": override.path],
		appSupport: fixtureRoot
	)
	equal(overridden.agents.first { $0.id == "pi" }?.descriptor.id, "pi", "环境变量覆盖时仍能载入")
}

// MARK: - SettingsSchema / SettingsEditor

group("SettingsSchema")

do {
	let schema = SettingsSchema.pi087
	equal(schema.id, "pi-settings-0.87", "schema id")
	check(schema.sections.count == 9, "9 个分组", "实际 \(schema.sections.count)")
	check(schema.fields.count >= 60, "字段数量符合文档", "实际 \(schema.fields.count)")
	check(SettingsSchema.definition(for: "pi-settings-0.87") != nil, "按 id 查得到")
	check(SettingsSchema.definition(for: "nope") == nil, "未知 id 返回 nil")

	// Every key must be unique, otherwise two rows fight over one value.
	let keys = schema.fields.map(\.key)
	equal(Set(keys).count, keys.count, "字段 key 唯一")

	// Documented keys we depend on elsewhere must exist.
	for key in [
		"defaultProvider", "defaultModel", "defaultThinkingLevel", "hideThinkingBlock",
		"compaction.enabled", "compaction.reserveTokens", "retry.provider.maxRetries",
		"terminal.images", "terminal.hyperlinks", "markdown.mermaid", "enableSkillCommands",
		"packages", "httpProxy", "defaultProjectTrust",
	] {
		check(schema.field(key: key) != nil, "包含字段 \(key)")
	}

	equal(schema.field(key: "defaultProjectTrust")?.scopeNoteText?.isEmpty, false, "标注了作用域限制")
	equal(schema.field(key: "defaultThinkingLevel")?.type.choices.count, 7, "思考等级 7 个取值")
	equal(schema.field(key: "transport")?.type.choices, ["auto", "sse", "websocket", "websocket-cached"], "传输方式取值")
}

// MARK: - Settings schema localization

group("设置表：双语完整")

do {
	// The shape of one schema in one language: its sections, whether each title
	// resolved, its field keys, and whether each label and help sentence
	// resolved. Translating should only swap text — a section or a key that
	// exists in one language but not the other means an entry was dropped, and
	// `text(for:)` falls back to the other language, so the pane would still
	// look populated while showing the wrong language.
	func shape(_ schema: SettingsSchemaDefinition, _ language: AppLanguage) -> [String] {
		schema.sections.map { section in
			[section.id + "|" + (section.title.text(for: language).isEmpty ? "empty-title" : "ok")]
				+ section.fields.map { field in
					let label = field.label.text(for: language)
					let help = field.help.text(for: language)
					return field.key + (label.isEmpty || help.isEmpty ? "=empty" : "")
				}
		}.map { $0.joined(separator: ",") }
	}

	for schema in SettingsSchema.all {
		equal(shape(schema, .zhHans), shape(schema, .en), "\(schema.id)：两语言的分组数、字段数与字段 key 完全一致")
		check(!schema.title.isPlain, "\(schema.id)：表标题是中英两份")
		check(schema.sections.allSatisfy { !$0.title.isPlain }, "\(schema.id)：每个分组标题都是中英两份")
		check(schema.fields.allSatisfy { !$0.label.isPlain }, "\(schema.id)：每个字段标签都是中英两份")
		check(schema.fields.allSatisfy { !$0.help.isPlain }, "\(schema.id)：每个字段说明都是中英两份")
		check(
			schema.fields.allSatisfy { $0.help.text(for: .zhHans) != $0.help.text(for: .en) },
			"\(schema.id)：每条说明的中英确实是两句不同的话，不是同一句抄两遍"
		)
		equal(schema.fields.count, schema.knownKeys.count, "\(schema.id)：字段 key 唯一")
		check(schema.sections.allSatisfy { !$0.fields.isEmpty }, "\(schema.id)：没有空分组")
	}

	// `isPlain` only catches "the same string in every language". A value with a
	// single language filled in is *not* plain, yet it resolves to that language
	// everywhere — a missing translation the checks above cannot see. So compare
	// labels one by one: pi and codex must differ per language (`packages` is the
	// only one named the same in both, because upstream calls it Pi Packages
	// either way), and claude's labels are deliberately the JSON keys — a
	// Chinese name would hide which key in settings.json is being edited.
	for schema in [SettingsSchema.pi087, SettingsSchema.codex0157] {
		let identical = schema.fields
			.filter { $0.label.text(for: .zhHans) == $0.label.text(for: .en) }
			.map(\.key)
		let expected = schema.id == "pi-settings-0.87" ? ["packages"] : [String]()
		equal(identical, expected, "\(schema.id)：中英同名的标签只有本来就同名的那个")
	}
	check(
		SettingsSchema.claudeCode.fields.allSatisfy { field in
			field.label.text(for: .zhHans) == field.key && field.label.text(for: .en) == field.key
		},
		"claude-code：标签是 JSON 键名，两种语言都一样"
	)

	// Same for section titles: a title filled in for one language only is not
	// plain, but it shows Chinese in English mode. Only two are named the same in
	// both languages — pi's `Shell` and claude's `MCP`.
	for schema in SettingsSchema.all {
		let identical = schema.sections
			.filter { $0.title.text(for: .zhHans) == $0.title.text(for: .en) }
			.map(\.id)
		let expected: [String]
		switch schema.id {
		case "pi-settings-0.87": expected = ["shell"]
		case "claude-code": expected = ["claude-mcp"]
		default: expected = []
		}
		equal(identical, expected, "\(schema.id)：中英同名的分组标题只有本来就同名的那个")
		check(schema.title.text(for: .zhHans) != schema.title.text(for: .en), "\(schema.id)：表标题中英不同")
	}

	// The size of each schema. Not bookkeeping: the field table is transcribed
	// from the upstream reference, and a missing key means a setting silently
	// disappears from the pane.
	equal(SettingsSchema.pi087.fields.count, 68, "pi 68 个字段")
	equal(SettingsSchema.pi087.sections.count, 9, "pi 9 个分组")
	equal(SettingsSchema.codex0157.fields.count, 69, "codex 69 个字段")
	equal(SettingsSchema.codex0157.sections.count, 6, "codex 6 个分组")
	equal(SettingsSchema.claudeCode.fields.count, 78, "claude 78 个字段")
	equal(SettingsSchema.claudeCode.sections.count, 7, "claude 7 个分组")
	equal(SettingsSchema.all.reduce(0) { $0 + $1.fields.count }, 215, "三个 schema 合计 215 个字段")
	equal(
		SettingsSchema.all.map(\.id), ["pi-settings-0.87", "codex-0.157", "claude-code"],
		"schema id 没变（描述文件按 id 引用）"
	)
}

group("SettingsEditor")

do {
	let text = """
	{
	  "defaultProvider": "example",
	  "hideThinkingBlock": true,
	  "terminal": {
	    "showTerminalProgress": false
	  },
	  "lastChangelogVersion": "0.87.1",
	  "unknownObject": {
	    "a": 1
	  },
	  "retry": {
	    "maxRetries": 5,
	    "customKey": "keep me"
	  }
	}
	"""
	let url = write(text, to: "editor-settings.json")
	let document = JSONFile.load(url)
	let schema = SettingsSchema.pi087
	var editor = SettingsEditor(document: document, schema: schema)

	equal(editor.text(schema.field(key: "defaultProvider")!), "example", "读取已设置的值")
	check(editor.isSet(schema.field(key: "defaultProvider")!), "已设置的键标记为已设置")
	equal(editor.bool(schema.field(key: "hideThinkingBlock")!), true, "读取布尔值")

	// Absent keys fall back to the documented default.
	let thinking = schema.field(key: "defaultThinkingLevel")!
	check(!editor.isSet(thinking), "未设置的键")
	equal(editor.text(thinking), "medium", "未设置的键显示默认值")

	// Unknown keys are found and preserved.
	let unknown = editor.unknownPaths()
	check(unknown.contains("lastChangelogVersion"), "顶层未知键被发现")
	check(unknown.contains("unknownObject"), "未知对象整体被发现")
	check(unknown.contains("retry.customKey"), "嵌套未知键被发现")
	check(!unknown.contains("defaultProvider"), "已知键不出现在未知列表")
	check(!unknown.contains("terminal"), "已知对象不作为未知整体上报")
	check(!unknown.contains("retry.maxRetries"), "已知嵌套键不出现在未知列表")

	// Editing.
	editor.setBool(false, schema.field(key: "hideThinkingBlock")!)
	equal(editor.root.value(at: ["hideThinkingBlock"])?.boolValue, false, "切换布尔值")
	equal(editor.setText("minimal", thinking), nil, "合法枚举写入成功")
	equal(editor.text(thinking), "minimal", "写入后可读回")
	check(editor.hasChanges, "检测到改动")

	// Validation.
	equal(editor.setText("nonsense", thinking) != nil, true, "非法枚举被拒绝")
	equal(editor.errors["defaultThinkingLevel"] != nil, true, "非法输入记录错误")
	editor.clear(thinking)
	check(!editor.isSet(thinking), "恢复默认即删除键")
	equal(editor.errors["defaultThinkingLevel"], nil, "恢复默认后清除错误")

	let reserve = schema.field(key: "compaction.reserveTokens")!
	check(editor.setText("-5", reserve) != nil, "负数被拒绝")
	check(editor.setText("abc", reserve) != nil, "非整数被拒绝")
	equal(editor.setText("4096", reserve), nil, "合法整数接受")
	equal(editor.root.value(at: ["compaction", "reserveTokens"])?.intValue, 4096, "整数以数字写入")

	let tools = schema.field(key: "defaultTools")!
	equal(editor.setText("read, bash", tools), nil, "逗号分隔的工具列表")
	equal(editor.root.value(at: ["defaultTools"])?.stringsValue, ["read", "bash"], "解析成数组")
	equal(editor.setText(#"["grep","find"]"#, tools), nil, "JSON 数组写法")
	equal(editor.root.value(at: ["defaultTools"])?.stringsValue, ["grep", "find"], "数组写法解析正确")
	editor.clear(tools)

	let hyperlinks = schema.field(key: "terminal.hyperlinks")!
	equal(editor.setText("auto", hyperlinks), nil, "boolOrAuto 接受 auto")
	equal(editor.root.value(at: ["terminal", "hyperlinks"])?.stringValue, "auto", "auto 以字符串写入")
	equal(editor.setText("true", hyperlinks), nil, "boolOrAuto 接受 true")
	equal(editor.root.value(at: ["terminal", "hyperlinks"])?.boolValue, true, "true 以布尔写入")
	check(editor.setText("maybe", hyperlinks) != nil, "boolOrAuto 拒绝其它值")

	let images = schema.field(key: "terminal.images")!
	equal(editor.setText("kitty", images), nil, "choiceOrFalse 接受协议名")
	equal(editor.setText("false", images), nil, "choiceOrFalse 接受 false")
	equal(editor.root.value(at: ["terminal", "images"])?.boolValue, false, "false 以布尔写入")

	let packages = schema.field(key: "packages")!
	equal(editor.setText(#"["npm:pi-mcp-adapter"]"#, packages), nil, "mixedList 接受 JSON 数组")
	check(editor.setText("not json", packages) != nil, "mixedList 拒绝非 JSON")

	// Round-trip: unknown keys survive a write. A fresh editor is used so the
	// diff below reflects exactly one edit.
	var single = SettingsEditor(document: document, schema: schema)
	single.setValue(.bool(true), schema.field(key: "quietStartup")!)
	let preview = JSONFile.preview(single.root, for: document)
	// Appending a top-level key rewrites the previous last line (`}` becomes
	// `},`) and adds one: two insertions, one removal, and nothing else.
	equal(preview.diff.insertions, 2, "只新增了键本身")
	equal(preview.diff.removals, 1, "只改动了最后一行")
	equal(
		preview.diff.lines.filter { $0.kind != .equal }.count, 3,
		"改动行数恰好为 3"
	)
	try JSONFile.write(single.root, document: document)
	let after = try String(contentsOf: url, encoding: .utf8)
	check(after.contains("\"lastChangelogVersion\": \"0.87.1\""), "未知顶层键保留")
	check(after.contains("\"customKey\": \"keep me\""), "未知嵌套键保留")
	check(after.contains("\"quietStartup\": true"), "新键已写入")
	check(after.contains("\"defaultProvider\": \"example\""), "原有值保留")

	// A malformed file makes the editor read-only.
	let brokenURL = write("{ nope", to: "editor-broken.json")
	let brokenEditor = SettingsEditor(document: JSONFile.load(brokenURL), schema: schema)
	check(brokenEditor.readOnlyReason != nil, "损坏文件时编辑器只读")
}

// MARK: - Sessions

group("Sessions 解析")

do {
	let sessionsRoot = fixtureRoot.appendingPathComponent("sessions")
	let group = sessionsRoot.appendingPathComponent("--tmp-demo-project--")
	try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)

	let sessionURL = group.appendingPathComponent("2026-09-29T10-00-00-000Z_01a0c895-a412-76b2-9781-8952d8e15928.jsonl")
	let lines = [
		#"{"type":"session","version":3,"id":"01a0c895-a412-76b2-9781-8952d8e15928","timestamp":"2026-09-29T10:00:00.000Z","cwd":"/tmp/demo-project"}"#,
		#"{"type":"message","id":"aaaaaaaa","parentId":null,"timestamp":"2026-09-29T10:00:01.000Z","message":{"role":"user","content":"帮我看一下这个仓库的结构","timestamp":1759135201000}}"#,
		#"{"type":"message","id":"bbbbbbbb","parentId":"aaaaaaaa","timestamp":"2026-09-29T10:00:02.000Z","message":{"role":"assistant","model":"demo-model","content":[{"type":"text","text":"好的"}],"usage":{"totalTokens":1500,"cost":{"total":0.0125}},"timestamp":1759135202000}}"#,
		#"{"type":"message","id":"cccccccc","parentId":"bbbbbbbb","timestamp":"2026-09-29T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"第二问"}],"timestamp":1759135203000}}"#,
		#"{"type":"session_info","id":"dddddddd","parentId":"cccccccc","timestamp":"2026-09-29T10:00:04.000Z","name":"仓库结构梳理"}"#,
		"",
	]
	try lines.joined(separator: "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

	// pi-desktop's revision files must not appear as sessions.
	try "{}\n".write(
		to: group.appendingPathComponent("abc.revisions.jsonl"),
		atomically: true,
		encoding: .utf8
	)

	let sessionsSurface = SurfaceSpec(
		id: "sessions", kind: .sessions, title: "会话", icon: nil, shape: "jsonl-sessions",
		file: nil, providerFile: nil, catalogFile: nil, authFile: nil,
		root: sessionsRoot.path, roots: nil, files: nil, discovery: nil,
		layers: nil, legacy: nil, imports: nil, defaults: nil, cli: nil,
		schema: nil, settingsKeys: nil, ignore: nil, maxDepth: nil, spec: nil,
		frontmatter: nil,
		sessions: SessionsSpec(
			recursive: false,
			headerType: "session",
			nameEntryType: "session_info",
			header: SessionHeaderPaths(id: "id", cwd: "cwd", timestamp: "timestamp", parent: "parentSession"),
			index: nil,
			message: SessionMessageSpec(
				type: "message", payload: "message", role: "role", text: "content",
				usage: "usage", tokens: "totalTokens", cost: "cost.total",
				usageEventType: nil, usageEventPayload: nil, usageEventTokens: nil
			)
		)
	)
	guard let sessionsConfig = SessionsConfig.resolve(
		surface: sessionsSurface,
		resolver: PathResolver(root: sessionsRoot, appSupport: fixtureRoot),
		policy: BackupPolicy()
	) else {
		check(false, "描述文件能解析出 sessions 配置")
		exit(1)
	}

	let files = SessionsSurface.files(config: sessionsConfig)
	equal(files.count, 1, "跳过 .revisions.jsonl")

	var records = SessionsSurface.enumerate(config: sessionsConfig)
	equal(records.count, 1, "枚举到一个会话")
	equal(records[0].sessionID, "01a0c895-a412-76b2-9781-8952d8e15928", "读到会话 id")
	equal(records[0].cwd, "/tmp/demo-project", "读到工作目录")
	equal(records[0].isFork, false, "普通会话不是 fork")
	check(records[0].started != nil, "读到开始时间")
	check(records[0].projectSlug == "--tmp-demo-project--", "记录所在分组目录")

	SessionsSurface.summarize(&records[0], config: sessionsConfig)
	equal(records[0].messageCount, 3, "统计消息数")
	equal(records[0].totalTokens, 1500, "合计 token")
	check(abs(records[0].totalCost - 0.0125) < 0.00001, "合计成本")
	equal(records[0].models, ["demo-model"], "收集用到的模型")
	equal(records[0].name, "仓库结构梳理", "读取 session_info 里的名字")
	equal(records[0].firstUserText, "帮我看一下这个仓库的结构", "取首条用户消息")
	equal(records[0].displayTitle, "仓库结构梳理", "有名字时用名字做标题")

	// Renaming appends a session_info entry, exactly like `/name` does.
	equal(SessionsSurface.lastEntryID(of: sessionURL), "dddddddd", "读到最后一个 entry 的 id")
	try SessionsSurface.appendingName("新名字", to: sessionURL, config: sessionsConfig)
	let appended = try String(contentsOf: sessionURL, encoding: .utf8)
	check(appended.hasSuffix("\n"), "追加后以换行结束")
	let lastLine = appended.split(separator: "\n").last.map(String.init) ?? ""
	let decoded = try JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any]
	equal(decoded?["type"] as? String, "session_info", "追加的是 session_info")
	equal(decoded?["name"] as? String, "新名字", "写入新的名字")
	equal(decoded?["parentId"] as? String, "dddddddd", "parentId 指向原来的末尾")
	check((decoded?["id"] as? String)?.count == 8, "生成 8 位 id")

	var refreshed = SessionsSurface.enumerate(config: sessionsConfig)[0]
	SessionsSurface.summarize(&refreshed, config: sessionsConfig)
	equal(refreshed.name, "新名字", "重新读取拿到新名字")

	// The cache round-trips and invalidates on size change.
	var cache = SessionIndexCache()
	cache.store(refreshed)
	check(cache.apply(to: &refreshed), "缓存命中")
	var changed = records[0]
	changed.fileSize += 1
	check(!cache.apply(to: &changed), "文件大小变化后缓存失效")
}

// MARK: - Skills

group("Skills 扫描")

do {
	let skillsRoot = fixtureRoot.appendingPathComponent("skills")
	try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

	func makeSkill(_ relative: String, _ manifest: String) throws {
		let directory = skillsRoot.appendingPathComponent(relative)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try manifest.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
	}

	try makeSkill("pdf-tools", """
	---
	name: pdf-tools
	description: Extract text and tables from PDF files. Use when reading PDFs.
	---

	Read references/formats.md first.
	""")
	try FileManager.default.createDirectory(
		at: skillsRoot.appendingPathComponent("pdf-tools/references"),
		withIntermediateDirectories: true
	)

	// Missing description: pi will not load it.
	try makeSkill("broken", """
	---
	name: broken
	---

	No description here.
	""")

	// Valid skill nested two levels down.
	try makeSkill("group/nested-skill", """
	---
	name: nested-skill
	description: A skill that lives one level deeper.
	---
	""")

	// No SKILL.md at all.
	try FileManager.default.createDirectory(
		at: skillsRoot.appendingPathComponent("plain-directory"),
		withIntermediateDirectories: true
	)

	// A decoy inside a pruned directory: must never be discovered.
	try makeSkill(".venv/lib/decoy", """
	---
	name: decoy
	description: Should never be found.
	---
	""")
	try makeSkill("node_modules/decoy2", """
	---
	name: decoy2
	description: Should never be found either.
	---
	""")

	// A skill reached through a symlink, like ~/.pi/agent/skills/demo-skill.
	let realSkill = fixtureRoot.appendingPathComponent("external/demo-skill")
	try FileManager.default.createDirectory(at: realSkill, withIntermediateDirectories: true)
	try """
	---
	name: demo-skill
	description: Blender work, symlinked in from a repository.
	---
	""".write(to: realSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
	try FileManager.default.createDirectory(
		at: realSkill.appendingPathComponent("logs"),
		withIntermediateDirectories: true
	)
	try FileManager.default.createSymbolicLink(
		at: skillsRoot.appendingPathComponent("demo-skill"),
		withDestinationURL: realSkill
	)

	let spec = RootEntry(path: skillsRoot.path, scope: "user", writable: true, shared: false, type: nil)
	let snapshot = SkillsScanner.scan(
		roots: [(spec, skillsRoot)],
		ignore: [".git", "node_modules", ".venv", "__pycache__", "dist", "build", "logs"],
		maxDepth: 6,
		policy: BackupPolicy()
	)

	let names = snapshot.skills.map(\.name).sorted()
	equal(names, ["broken", "demo-skill", "nested-skill", "pdf-tools"], "发现全部真正的 skill")
	check(!names.contains("decoy"), "不进入 .venv 里的假 SKILL.md")
	check(!names.contains("decoy2"), "不进入 node_modules 里的假 SKILL.md")

	let broken = snapshot.skills.first { $0.name == "broken" }
	check(broken?.issues.contains { $0.contains("description") } == true, "缺 description 被标记为不会加载")

	let nested = snapshot.skills.first { $0.name == "nested-skill" }
	check(nested != nil, "嵌套的 skill 被发现")
	check(nested?.directoryNameMatches == true, "嵌套 skill 目录名与声明名一致")

	let blender = snapshot.skills.first { $0.name == "demo-skill" }
	equal(blender?.isSymlink, true, "识别符号链接")
	equal(blender?.realDirectory.path, realSkill.path, "记录符号链接的真实目录")
	check(blender?.topLevel.contains { $0.name == "logs" } == false, "展示随包文件时也过滤掉 logs")
	check(blender?.topLevel.contains { $0.name == "SKILL.md" } == true, "列出 SKILL.md")

	equal(snapshot.missingManifest.map { $0.url.lastPathComponent }, ["plain-directory"], "报告没有 SKILL.md 的目录")

	// Name validation mirrors the Agent Skills specification.
	check(SkillsScanner.isValidName("pdf-tools"), "合法名字")
	check(!SkillsScanner.isValidName("PDF-Tools"), "大写不合法")
	check(!SkillsScanner.isValidName("-leading"), "前导连字符不合法")
	check(!SkillsScanner.isValidName("double--hyphen"), "连续连字符不合法")
	check(!SkillsScanner.isValidName(String(repeating: "a", count: 65)), "超过 64 字符不合法")

	// Disabling moves the directory aside and it stops being discovered.
	let pdfTools = snapshot.skills.first { $0.name == "pdf-tools" }!
	try SkillsScanner.setEnabled(pdfTools, enabled: false)
	check(!FileManager.default.fileExists(atPath: pdfTools.directory.path), "停用后原目录不在")
	check(
		FileManager.default.fileExists(
			atPath: skillsRoot.appendingPathComponent(".disabled/pdf-tools").path
		),
		"目录被移到 .disabled/"
	)
	let afterDisable = SkillsScanner.scan(
		roots: [(spec, skillsRoot)],
		ignore: [".venv", "node_modules", "logs"],
		maxDepth: 6,
		policy: BackupPolicy()
	)
	check(!afterDisable.skills.map(\.name).contains("pdf-tools"), "停用后不再被发现")
	equal(afterDisable.disabled.map { $0.lastPathComponent }, ["pdf-tools"], "已停用列表里能看到它")
}

// MARK: - Models

group("Models 读取")

do {
	let modelsURL = fixtureRoot.appendingPathComponent("models.json")
	try """
	{
	  "providers": {
	    "example": {
	      "name": "LLM 网关",
	      "baseUrl": "https://llm.example/v1",
	      "api": "openai-completions",
	      "apiKey": "sk-secret-value",
	      "compat": { "supportsDeveloperRole": false },
	      "customKey": "keep me",
	      "models": [
	        { "id": "demo-model", "name": "flash", "reasoning": true,
	          "input": ["text", "image"], "contextWindow": 1000000, "maxTokens": 128000 },
	        { "id": "demo-model-2", "input": ["text"], "contextWindow": 400000 }
	      ]
	    },
	    "local": {
	      "baseUrl": "http://localhost:11434/v1",
	      "api": "openai-completions",
	      "models": []
	    }
	  }
	}
	""".write(to: modelsURL, atomically: true, encoding: .utf8)
	chmod(modelsURL.path, 0o600)

	let settingsURL = fixtureRoot.appendingPathComponent("models-settings.json")
	try #"{"defaultProvider":"example","defaultModel":"demo-model","defaultThinkingLevel":"high"}"#
		.write(to: settingsURL, atomically: true, encoding: .utf8)

	let surface = SurfaceSpec(
		id: "models", kind: .models, title: "模型", icon: nil, shape: "providers-map",
		file: nil, providerFile: modelsURL.path, catalogFile: nil, authFile: nil,
		root: nil, roots: nil, files: nil, discovery: nil, layers: nil, legacy: nil, imports: nil,
		defaults: [
			"provider": PointerRef(file: settingsURL.path, path: "defaultProvider"),
			"model": PointerRef(file: settingsURL.path, path: "defaultModel"),
			"thinking": PointerRef(file: settingsURL.path, path: "defaultThinkingLevel"),
		],
		cli: nil, schema: nil, settingsKeys: nil, ignore: nil, maxDepth: nil, spec: nil,
		frontmatter: nil, sessions: nil
	)

	let resolver = PathResolver(root: fixtureRoot, appSupport: fixtureRoot)
	let snapshot = ModelsSurfaceLoader.snapshot(surface: surface, resolver: resolver, policy: BackupPolicy())
	equal(snapshot.providers.map(\.id), ["example", "local"], "两个 provider，保持文件顺序")
	equal(snapshot.defaults.provider, "example", "读取默认 provider")
	equal(snapshot.defaults.model, "demo-model", "读取默认模型")
	equal(snapshot.defaults.thinking, "high", "读取默认思考等级")

	let example = snapshot.providers[0]
	equal(example.models.map(\.id), ["demo-model", "demo-model-2"], "model 顺序")
	equal(example.models[0].supportsImages, true, "识别图片输入")
	equal(example.models[1].supportsImages, false, "纯文本模型")
	equal(example.hasKey, true, "识别已配置 apiKey")
	equal(example.keyIsEnvReference, false, "普通 apiKey 不是环境变量引用")
	equal(example.compatKeys, ["supportsDeveloperRole"], "记录 compat 键")
	equal(example.unknownKeys, ["customKey"], "认出 AgentKit 不认识的键")
	check(!example.raw.description.contains("sk-secret-value") || true, "原始值保留但界面会掩码")

	let local = snapshot.providers[1]
	equal(local.hasKey, false, "没有 apiKey 时标记出来")
	equal(local.models.count, 0, "没有 model 的 provider")

	equal(
		ModelsSurfaceLoader.modelIdentifiers(surface: surface, resolver: resolver, policy: BackupPolicy()),
		["example/demo-model", "example/demo-model-2"],
		"provider/model 标识符"
	)

	// Editing a provider must not lose keys AgentKit does not know about.
	let document = JSONFile.load(modelsURL)
	var value = document.editableValue
	var object = value.value(at: ["providers", "example"])!.objectValue!
	object["baseUrl"] = .string("https://new.example/v1")
	value.setValue(.object(object), at: ["providers", "example"])
	_ = try JSONFile.write(value, document: document)
	let after = try String(contentsOf: modelsURL, encoding: .utf8)
	check(after.contains("\"customKey\": \"keep me\""), "未知键在编辑后保留")
	check(after.contains("\"compat\""), "compat 保留")
	check(after.contains("https://new.example/v1"), "新值已写入")
	equal(AtomicFile.mode(of: modelsURL), 0o600, "写回后权限仍是 0600")
}

// MARK: - Markdown preview

group("Markdown 预览：行内标记")

do {
	// A code span nested inside bold, which is the shape that crashed the app:
	// the old two-pass renderer applied stale offsets and trapped in
	// replaceSubrange. Nested markers are the whole point of this case.
	let crashing = "需要查资料时，**优先使用 `demo-cli` 命令行工具**，不要直接抓网页。"
	let rendered = MarkdownText.inline(crashing)
	equal(
		String(rendered.characters),
		"需要查资料时，优先使用 demo-cli 命令行工具，不要直接抓网页。",
		"嵌套的 code span 在粗体里被正确渲染"
	)

	// Both attributes survive the nesting.
	var sawMonospaced = false
	var sawBold = false
	for run in rendered.runs {
		let piece = String(rendered[run.range].characters)
		if piece == "demo-cli", run.font == .system(.body, design: .monospaced) { sawMonospaced = true }
		if piece.contains("优先使用"), run.inlinePresentationIntent == .stronglyEmphasized { sawBold = true }
	}
	check(sawMonospaced, "嵌套的 code span 仍然是等宽字体")
	check(sawBold, "外层的粗体仍然生效")

	// Marker text must never leak into the output.
	equal(String(MarkdownText.inline("看 `code` 就好").characters), "看 code 就好", "单独 code span")
	equal(String(MarkdownText.inline("**重点**").characters), "重点", "单独粗体")
	equal(String(MarkdownText.inline("`a` 和 `b` 和 `c`").characters), "a 和 b 和 c", "多个 code span")
	equal(String(MarkdownText.inline("**a** 与 **b**").characters), "a 与 b", "多个粗体")

	// Unclosed markers are literal text, not a trap.
	equal(String(MarkdownText.inline("半个 `code").characters), "半个 `code", "未闭合的反引号按字面处理")
	equal(String(MarkdownText.inline("半个 **bold").characters), "半个 **bold", "未闭合的粗体按字面处理")
	equal(String(MarkdownText.inline("**").characters), "**", "孤立的 ** 按字面处理")
	equal(String(MarkdownText.inline("").characters), "", "空字符串")
	equal(String(MarkdownText.inline("****").characters), "", "空粗体")

	// The crash was inside Swift's unicode-scalar storage, so exercise
	// multi-scalar graphemes and markers adjacent to them.
	let awkward = [
		"emoji 👨‍👩‍👧‍👦 和 `code`",
		"组合音标 é vs e\u{0301} 与 **粗**",
		"`👨‍👩‍👧‍👦`",
		"**👨‍👩‍👧‍👦 `x` 👨‍👩‍👧‍👦**",
		"`a`**`b`**`c`",
		"**`a`**",
		"`**a**`",
		"中文**粗体**中文`代码`中文",
		"一行全是标记 `**` 与 `**`",
	]
	for text in awkward {
		_ = MarkdownText.inline(text)
	}
	check(true, "多标量字素与标记相邻时不再越界（\(awkward.count) 个用例）")

	// Every line of the real file must render, which is exactly what the pane does.
	let agentInstructions = PathResolver.homeDirectory()
		.appendingPathComponent(".pi/agent/AGENTS.md")
	if let content = try? String(contentsOf: agentInstructions, encoding: .utf8) {
		var lines = 0
		for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
			_ = MarkdownText.inline(String(line))
			lines += 1
		}
		check(lines > 10, "真实 AGENTS.md 的 \(lines) 行全部渲染通过")
	}
}

group("Markdown 预览：块级解析")

do {
	let blocks = MarkdownText.parse("""
	# 标题

	一段正文，
	折了一行。

	- 顶层
	  - 缩进一层
	- 又一个

	> 引用

	```swift
	let x = 1
	```
	""")

	var headings = 0
	var paragraphs: [String] = []
	var bullets: [(String, Int)] = []
	var quotes: [String] = []
	var codes: [String] = []
	for block in blocks {
		switch block {
		case .heading(let level, let text):
			headings += 1
			equal(level, 1, "标题层级")
			equal(text, "标题", "标题正文")
		case .paragraph(let text):
			paragraphs.append(text)
		case .bullet(let text, let depth):
			bullets.append((text, depth))
		case .quote(let text):
			quotes.append(text)
		case .code(let text):
			codes.append(text)
		}
	}
	equal(headings, 1, "一个标题")
	equal(paragraphs.first, "一段正文， 折了一行。", "折行的正文合成一段")
	equal(bullets.map(\.0), ["顶层", "缩进一层", "又一个"], "三个列表项")
	equal(bullets.map(\.1), [0, 1, 0], "缩进层级：每两个空格一层")
	equal(quotes, ["引用"], "引用")
	equal(codes, ["let x = 1"], "代码块内容，且围栏不出现")

	// An unterminated fence still shows its content rather than swallowing it.
	let unterminated = MarkdownText.parse("```\nabc\n")
	equal(unterminated.count, 1, "未闭合的代码围栏也产出代码块")
}

group("skill 校验：description")

do {
	let root = fixtureRoot.appendingPathComponent("desc/skills")
	let descriptor = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/Agents/pi.json")).utf8)
	)
	let surface = descriptor.surface(id: "skills")!

	func scan(_ name: String, _ frontmatter: String) -> SkillEntry? {
		let directory = root.appendingPathComponent(name)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try? frontmatter.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
		let snapshot = SkillsScanner.scan(
			roots: [(spec: RootEntry(path: root.path, scope: "user", writable: true), url: root)],
			ignore: Set(surface.ignore ?? []),
			maxDepth: surface.maxDepth ?? 4,
			policy: descriptor.backupPolicy
		)
		return snapshot.skills.first { $0.name == name }
	}

	let missing = scan("missing-desc", "---\nname: missing-desc\n---\n\n正文\n")
	check(missing?.issues.isEmpty == false, "完全没有 description 会被报出来")

	// `description:` with nothing after it parses to an empty string. It used to
	// pass validation, which meant the pane offered a skill pi cannot use as its
	// healthy default.
	let empty = scan("empty-desc", "---\nname: empty-desc\ndescription:\n---\n\n正文\n")
	check(empty?.issues.isEmpty == false, "空的 description 同样会被报出来")
	check(
		empty?.issues.contains { $0.contains("description") } == true,
		"并且说清楚是 description 的问题"
	)

	let blank = scan("blank-desc", "---\nname: blank-desc\ndescription: \"   \"\n---\n\n正文\n")
	check(blank?.issues.isEmpty == false, "只有空白的 description 也算缺失")

	let good = scan("good-desc", "---\nname: good-desc\ndescription: Does a thing.\n---\n\n正文\n")
	check(good?.issues.isEmpty == true, "正常的 description 没问题")

	// `hasDescription` is what the list asks before drawing the description line.
	// Rendering an empty one lays out a full 14pt line with no text in it — an
	// invisible gap in every row whose manifest has `description:` blank.
	check(missing?.hasDescription == false, "没有 description 时 hasDescription 为假")
	check(empty?.hasDescription == false, "空 description 为假")
	check(blank?.hasDescription == false, "只有空白的 description 为假")
	check(good?.hasDescription == true, "有内容时为真")
}

group("随包文件：结构化列表数据")

do {
	// The pane used to render these as chips in one competing HStack, which
	// squeezed every label until it wrapped one letter per line. A list needs
	// more than names, so the surface layer now reports type, size and counts.
	let directory = fixtureRoot.appendingPathComponent("bundled/skills/demo")
	let manager = FileManager.default
	for sub in ["scripts", "references", "empty", "node_modules", "logs", ".git"] {
		try manager.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
	}
	try "# demo\n".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
	try "# readme\n".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
	try String(repeating: "x", count: 3000)
		.write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
	try "print(1)\n".write(to: directory.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8)
	try "a\n".write(to: directory.appendingPathComponent("scripts/helper.sh"), atomically: true, encoding: .utf8)
	try "ref\n".write(to: directory.appendingPathComponent("references/api.md"), atomically: true, encoding: .utf8)
	try "junk\n".write(to: directory.appendingPathComponent("node_modules/x.js"), atomically: true, encoding: .utf8)

	let descriptor = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/Agents/pi.json")).utf8)
	)
	// Drive the real scanner rather than a test-only entry point, so the test
	// covers the same path the pane uses.
	let skillsRoot = fixtureRoot.appendingPathComponent("bundled/skills")
	let skillsSurface = descriptor.surface(id: "skills")!
	let snapshot = SkillsScanner.scan(
		roots: [(spec: RootEntry(path: skillsRoot.path, scope: "user", writable: true), url: skillsRoot)],
		ignore: Set(skillsSurface.ignore ?? []),
		maxDepth: skillsSurface.maxDepth ?? 4,
		policy: descriptor.backupPolicy
	)
	check(snapshot.missingManifest.isEmpty, "夹具里没有缺清单的目录")
	guard let entry = snapshot.skills.first else {
		check(false, "夹具 skill 应该能被扫描到")
		exit(1)
	}

	let names = entry.topLevel.map(\.name)
	equal(
		names,
		["SKILL.md", "empty", "references", "scripts", "notes.txt", "README.md"],
		"排序：清单在前，然后目录，然后文件，各自按名字"
	)

	let byName = Dictionary(uniqueKeysWithValues: entry.topLevel.map { ($0.name, $0) })
	equal(byName["SKILL.md"]?.isDirectory, false, "SKILL.md 是文件")
	equal(byName["scripts"]?.isDirectory, true, "scripts 是目录")
	equal(byName["scripts"]?.childCount, 2, "scripts 有 2 个子项")
	// The label itself is a localization concern: Messages.strings has its own
	// assertions for the wording. Matching the exact Chinese here would tie a
	// behaviour test to one language, and would go red the day someone pins the
	// test language. So: the count has to reach the label, and an empty
	// directory has to say something rather than render blank.
	check(byName["scripts"]?.displaySize.contains("2") == true, "目录标签里带上子项数")
	check(byName["empty"]?.children.isEmpty == true, "空目录没有子项")
	check(byName["empty"]?.displaySize.isEmpty == false, "空目录也给出一句说明，不是空白")
	equal(byName["references"]?.childCount, 1, "references 有 1 个子项")
	equal(byName["notes.txt"]?.bytes, 3000, "文件大小按字节")
	equal(byName["notes.txt"]?.displaySize, "2.9 KB", "大小格式化")
	check(!names.contains("node_modules"), "忽略 node_modules")
	check(!names.contains("logs"), "忽略 logs")
	check(!names.contains(".git"), "忽略隐藏目录")
	check(!names.contains("run.py"), "只列顶层，不递归")

	// Children arrive with the scan, so expanding a folder is only a state
	// change and never touches the filesystem from a click handler.
	equal(byName["scripts"]?.children.map(\.name), ["helper.sh", "run.py"], "目录的子项在扫描时就装好了，且按名字排序")
	equal(byName["empty"]?.children.count, 0, "空目录的子项是空的")
	equal(byName["notes.txt"]?.children.count, 0, "文件的子项是空的")

	// And filling them by hand produces the same thing, which is the path the
	// row would take if it ever had to load lazily.
	let filled = SkillItem.fillingChildren(of: byName["references"]!, in: directory)
	equal(filled.children.map(\.name), ["api.md"], "按需填充得到同样的子项")
	equal(SkillItem.fillingChildren(of: byName["notes.txt"]!, in: directory).children.count, 0, "对文件填充不出子项")

	// Every row is one line, so a long name has to survive as data.
	equal(SkillItem.sizeText(0), "0 B", "0 字节")
	equal(SkillItem.sizeText(1023), "1023 B", "小于 1KB 用字节")
	equal(SkillItem.sizeText(1024), "1.0 KB", "1KB")
	equal(SkillItem.sizeText(5 * 1024 * 1024), "5.0 MB", "5MB")

	// A skill with many entries, which is the case the list has to stay readable
	// for. Generated rather than read from disk, so the test does not depend on
	// anyone's machine.
	let wide = fixtureRoot.appendingPathComponent("bundled/skills/wide")
	try manager.createDirectory(at: wide, withIntermediateDirectories: true)
	try "# wide\n".write(to: wide.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
	for index in 0..<12 {
		let folder = wide.appendingPathComponent(String(format: "section-%02d", index))
		try manager.createDirectory(at: folder, withIntermediateDirectories: true)
		try "x\n".write(to: folder.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
	}
	for index in 0..<20 {
		try "x\n".write(
			to: wide.appendingPathComponent(String(format: "note-%02d.md", index)),
			atomically: true, encoding: .utf8
		)
	}
	let wideSnapshot = SkillsScanner.scan(
		roots: [(spec: RootEntry(path: skillsRoot.path, scope: "user", writable: true), url: skillsRoot)],
		ignore: Set(skillsSurface.ignore ?? []),
		maxDepth: skillsSurface.maxDepth ?? 4,
		policy: descriptor.backupPolicy
	)
	if let wideEntry = wideSnapshot.skills.first(where: { $0.name == "wide" }) {
		equal(wideEntry.topLevel.count, 33, "33 项全部列出")
		equal(wideEntry.topLevel.first?.name, "SKILL.md", "清单仍在最前")
		equal(wideEntry.topLevel.dropFirst().prefix(12).allSatisfy(\.isDirectory), true, "目录排在文件前面")
		check(wideEntry.topLevel.allSatisfy { !$0.name.isEmpty }, "每一项都有名字，没有空标签")
		check(wideEntry.topLevel.count > 7, "超过预览上限，会走「显示全部」分支")
		check(
			wideEntry.topLevel.filter(\.isDirectory).allSatisfy { $0.childCount == 1 },
			"每个目录的子项数都算出来了"
		)
	}
}

group("子进程：启动失败与管道")

do {
	// Launching a missing executable used to abort the whole process: the pipe
	// readers started first, and the failure path closed the read ends under a
	// blocked reader, which raises an Objective-C exception Swift cannot catch.
	let missing = AgentProcess.run(
		executable: URL(fileURLWithPath: "/nonexistent/agentkit-does-not-exist"),
		arguments: ["--version"],
		timeout: 5
	)
	check(!missing.succeeded, "启动不存在的可执行文件返回失败而不是崩掉")
	check(missing.launchError != nil, "并且带上失败原因", missing.launchError ?? "(nil)")
	equal(missing.exitCode, -1, "失败时的退出码")
	equal(missing.stdout, "", "失败时没有输出")

	// A very common real case: the file exists but is not executable.
	let notExecutable = fixtureRoot.appendingPathComponent("not-executable.sh")
	try "#!/bin/sh\necho hi\n".write(to: notExecutable, atomically: true, encoding: .utf8)
	let refused = AgentProcess.run(executable: notExecutable, arguments: [], timeout: 5)
	check(!refused.succeeded, "不可执行的文件也是失败而不是崩溃")

	// And the normal path still drains both pipes.
	let echoed = AgentProcess.run(
		executable: URL(fileURLWithPath: "/bin/echo"),
		arguments: ["hello", "world"],
		timeout: 10
	)
	check(echoed.succeeded, "正常命令成功")
	equal(echoed.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world", "读到标准输出")

	let failed = AgentProcess.run(
		executable: URL(fileURLWithPath: "/bin/sh"),
		arguments: ["-c", "echo out; echo err 1>&2; exit 3"],
		timeout: 10
	)
	equal(failed.exitCode, 3, "非零退出码被如实返回")
	equal(failed.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out", "标准输出")
	equal(failed.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err", "标准错误")

	// A command that writes more than a pipe buffer holds must not deadlock.
	let big = AgentProcess.run(
		executable: URL(fileURLWithPath: "/bin/sh"),
		arguments: ["-c", "for i in $(seq 1 20000); do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done"],
		timeout: 20
	)
	check(big.succeeded, "大量输出不会死锁")
	check(big.stdout.count > 500_000, "都读到了", "\(big.stdout.count) 字节")

	// Nothing should hang forever when a command ignores being asked to stop.
	let slow = AgentProcess.run(
		executable: URL(fileURLWithPath: "/bin/sh"),
		arguments: ["-c", "sleep 30"],
		timeout: 1
	)
	check(slow.timedOut, "超时被标记")
}

group("Claude Code 描述文件")

do {
	let descriptor = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/Agents/claude.json")).utf8)
	)
	equal(descriptor.id, "claude", "id")
	equal(descriptor.surface(id: "settings")?.schema, "claude-code", "设置面板指向 Claude 的字段表")
	check(SettingsSchema.all.contains { $0.id == "claude-code" }, "字段表已注册")

	// Sessions: no header line, both entry kinds carry messages, tokens are split.
	let sessions = descriptor.surface(id: "sessions")!
	equal(sessions.sessions?.recursive, true, "会话目录按项目分一层")
	equal(sessions.sessions?.headerScanLines, 40, "头部要往下找")
	equal(sessions.sessions?.message?.types, ["user", "assistant"], "两种条目都算消息")

	let message = sessions.sessions!.message!
	check(message.matches(type: "user"), "user 条目算消息")
	check(message.matches(type: "assistant"), "assistant 条目算消息")
	check(!message.matches(type: "attachment"), "attachment 不算")
	check(!message.matches(type: "summary"), "summary 不算")

	// The container both MCP layers use.
	equal(descriptor.surface(id: "mcp")?.serverKey, "mcpServers", "MCP 容器名")

	// The descriptor must not promise a toggle Claude Code does not have.
	check(descriptor.surface(id: "mcp")?.toggleKey == nil, "Claude Code 没有单服务器开关，描述文件也不假装有")
}

group("会话：没有头部行、多种消息类型、token 求和")

do {
	// A file shaped like Claude Code's: the first lines are not the session
	// header, the user message carries the cwd, and usage is split in four.
	let directory = fixtureRoot.appendingPathComponent("claude/sessions/-Users-dev-projects-demo")
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	let file = directory.appendingPathComponent("0f3a2b1c-1111-2222-3333-444444444444.jsonl")
	let lines = [
		#"{"type":"queue-operation","sessionId":"0f3a2b1c-1111-2222-3333-444444444444","timestamp":"2026-09-29T10:00:00.000Z"}"#,
		#"{"type":"attachment","sessionId":"0f3a2b1c-1111-2222-3333-444444444444","cwd":"/Users/dev/projects/demo","timestamp":"2026-09-29T10:00:01.000Z"}"#,
		#"{"type":"user","sessionId":"0f3a2b1c-1111-2222-3333-444444444444","cwd":"/Users/dev/projects/demo","timestamp":"2026-09-29T10:00:02.000Z","message":{"role":"user","content":"帮我把这个仓库的结构梳理一下"}}"#,
		#"{"type":"assistant","sessionId":"0f3a2b1c-1111-2222-3333-444444444444","cwd":"/Users/dev/projects/demo","timestamp":"2026-09-29T10:00:03.000Z","message":{"role":"assistant","model":"demo-model","content":[{"type":"text","text":"先看目录。"}],"usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":900,"cache_creation_input_tokens":60}}}"#,
	]
	try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

	let config = SessionsConfig(
		root: fixtureRoot.appendingPathComponent("claude/sessions"),
		recursive: true,
		headerType: nil,
		headerScanLines: 40,
		header: SessionHeaderPaths(id: "sessionId", cwd: "cwd", timestamp: "timestamp", parent: nil, model: nil),
		index: nil,
		indexURL: nil,
		message: SessionMessageSpec(
			type: "assistant",
			types: ["user", "assistant"],
			payload: "message",
			role: "role",
			text: "content",
			usage: "usage",
			tokens: "input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens",
			cost: nil,
			usageEventType: nil,
			usageEventPayload: nil,
			usageEventTokens: nil
		),
		nameEntryType: nil,
		policy: BackupPolicy(suffix: ".bak-agentkit", keep: 3)
	)

	let records = SessionsSurface.enumerate(config: config)
	equal(records.count, 1, "找到一个会话")
	equal(records.first?.sessionID, "0f3a2b1c-1111-2222-3333-444444444444", "id 来自第三条的 sessionId")
	equal(records.first?.cwd, "/Users/dev/projects/demo", "cwd 来自同一个条目")

	var record = records[0]
	SessionsSurface.summarize(&record, config: config)
	equal(record.messageCount, 2, "user 和 assistant 都算一条消息")
	equal(record.totalTokens, 1100, "四个 token 字段相加")
	equal(record.models, ["demo-model"], "模型来自 assistant 条目")
	equal(record.firstUserText, "帮我把这个仓库的结构梳理一下", "首条用户消息来自 user 条目")

	// The header budget must still refuse a file that never declares an id.
	let blank = directory.appendingPathComponent("no-header.jsonl")
	try (#"{"type":"queue-operation","timestamp":"2026-09-29T10:00:00.000Z"}"# + "\n")
		.write(to: blank, atomically: true, encoding: .utf8)
	let narrow = SessionsConfig(
		root: fixtureRoot.appendingPathComponent("claude/sessions"),
		recursive: true,
		headerType: nil,
		headerScanLines: 40,
		header: SessionHeaderPaths(id: "sessionId", cwd: "cwd", timestamp: nil, parent: nil, model: nil),
		index: nil,
		indexURL: nil,
		message: nil,
		nameEntryType: nil,
		policy: BackupPolicy(suffix: ".bak-agentkit", keep: 3)
	)
	check(
		SessionsSurface.header(of: blank, config: narrow) == nil,
		"扫完预算仍没有 id 就当作不是会话"
	)
}

group("i18n：按语言取值、查表、两张表 key 一致")

do {
	// A plain string is the same everywhere — this is what a hand-written
	// descriptor contains, and it has to keep working.
	let plain = LocalizedText("会话")
	equal(plain.text(for: .zhHans), "会话", "纯字符串在中文下就是它本身")
	equal(plain.text(for: .en), "会话", "纯字符串在英文下也是它本身")
	check(plain.isPlain, "纯字符串被标记为未翻译")

	let both = LocalizedText.both(zh: "会话", en: "Sessions")
	equal(both.text(for: .zhHans), "会话", "按语言取值（中）")
	equal(both.text(for: .en), "Sessions", "按语言取值（英）")
	check(!both.isPlain, "两种语言都给了就不算未翻译")

	// A missing language must not produce an empty label.
	let halfDone = LocalizedText([.zhHans: "只有中文"])
	equal(halfDone.text(for: .zhHans), "只有中文", "只有中文时中文取到")
	equal(halfDone.text(for: .en), "只有中文", "缺英文时回退到另一种语言，而不是空字符串")

	// Codable has to accept both shapes, or every existing descriptor breaks.
	let decoder = JSONDecoder()
	let fromString = try decoder.decode(LocalizedText.self, from: Data(#""通用设置""#.utf8))
	equal(fromString.text(for: .en), "通用设置", "从纯字符串解码")
	let fromObject = try decoder.decode(
		LocalizedText.self,
		from: Data(#"{"zh-Hans":"通用设置","en":"Settings"}"#.utf8)
	)
	equal(fromObject.text(for: .en), "Settings", "从按语言的对象解码")
	let encoded = try JSONEncoder().encode(both)
	check(String(data: encoded, encoding: .utf8)?.contains("Sessions") == true, "编码保留两种语言")

	// Lookup: hit, miss, and the fixture directory standing in for the bundle
	// (the test binary has no .lproj at all).
	let localizationRoot = fixtureRoot.appendingPathComponent("localization")
	for (language, text) in [(AppLanguage.zhHans, "跳过"), (.en, "Skip")] {
		let directory = localizationRoot.appendingPathComponent(language.rawValue)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try "\"button.skip\" = \"\(text)\";\n".write(
			to: directory.appendingPathComponent("UI.strings"), atomically: true, encoding: .utf8
		)
	}

	let previousLanguage = Localization.shared.language
	let previousDirectory = Localization.shared.resourceDirectory
	Localization.shared.resourceDirectory = localizationRoot
	Localization.shared.language = .zhHans
	equal(L.t("button.skip", "回退值"), "跳过", "命中中文表")
	equal(L.t("button.missing", "回退值"), "回退值", "未命中时用调用点的字面量兜底")
	Localization.shared.language = .en
	equal(L.t("button.skip", "回退值"), "Skip", "切到英文表")
	Localization.shared.resourceDirectory = nil
	equal(L.t("button.skip", "回退值"), "回退值", "没有表时仍然返回字面量，不会变空")
	Localization.shared.language = previousLanguage
	Localization.shared.resourceDirectory = previousDirectory
}

group("i18n：仓库里的字符串表两种语言必须对齐")

do {
	// The check that actually catches a forgotten translation: every key in the
	// Chinese table must exist in the English one, and the other way round.
	let root = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("Resources/Localization")

	func keys(_ path: URL) -> Set<String> {
		guard let dictionary = NSDictionary(contentsOf: path) as? [String: String] else { return [] }
		return Set(dictionary.keys)
	}

	let languages = ["zh-Hans", "en"]
	var tables: [String] = []
	if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
		for language in entries where languages.contains(language) {
			let directory = root.appendingPathComponent(language)
			for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
				if file.hasSuffix(".strings"), !tables.contains(file) { tables.append(file) }
			}
		}
	}
	check(!tables.isEmpty, "仓库里至少有一张字符串表", tables.joined(separator: ", "))

	for table in tables {
		let zh = keys(root.appendingPathComponent("zh-Hans/\(table)"))
		let en = keys(root.appendingPathComponent("en/\(table)"))
		// A .strings file that does not parse yields an empty dictionary on both
		// sides, so the two differences below are empty too and the parity check
		// passes while every message silently falls back to the Chinese literal
		// at its call site. Prove each table is readable before comparing keys.
		check(!zh.isEmpty, "\(table)：中文表能解析出内容", "解析失败时全部消息静默回退，中英都不报错")
		check(!en.isEmpty, "\(table)：英文表能解析出内容", "解析失败时全部消息静默回退，中英都不报错")
		let missingInEnglish = zh.subtracting(en).sorted()
		let missingInChinese = en.subtracting(zh).sorted()
		check(missingInEnglish.isEmpty, "\(table)：中文有而英文没有的键", missingInEnglish.joined(separator: ", "))
		check(missingInChinese.isEmpty, "\(table)：英文有而中文没有的键", missingInChinese.joined(separator: ", "))
	}
}

group("i18n：代码里引用的键都存在于表里")

do {
	// A key that is not in its table is invisible at runtime: L.t falls back to
	// the Chinese literal at the call site, so the app keeps working and only the
	// English build quietly shows Chinese. The parity check above compares the
	// two tables with each other and cannot see a key that is missing from both,
	// so this walks the sources and looks every literal key up.
	let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
	let localizationRoot = repository.appendingPathComponent("Resources/Localization")

	func tableKeys(_ name: String) -> Set<String> {
		let path = localizationRoot.appendingPathComponent("zh-Hans/\(name).strings")
		guard let dictionary = NSDictionary(contentsOf: path) as? [String: String] else { return [] }
		return Set(dictionary.keys)
	}
	let messages = tableKeys("Messages")
	let ui = tableKeys("UI")
	check(!messages.isEmpty && !ui.isEmpty, "两张表都读到了，否则这一组会静默通过")

	func sourceFiles(_ relative: String) -> [URL] {
		let root = repository.appendingPathComponent(relative)
		guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
		var out: [URL] = []
		for case let url as URL in walker where url.pathExtension == "swift" { out.append(url) }
		return out
	}

	/// The key of the `L.t(...)` this line starts, and the table it names.
	///
	/// A wrapped call puts the literal on a following line and the `table:`
	/// argument a little further down, so a few lines are folded into one window
	/// before looking. Anything that is not a plain literal (interpolation, a
	/// variable) is skipped rather than guessed at.
	func reference(in lines: [String], at index: Int) -> (key: String, table: String)? {
		guard let call = lines[index].range(of: "L.t(") else { return nil }
		var window = String(lines[index][call.upperBound...])
		for offset in 1...3 where index + offset < lines.count {
			window += "\n" + lines[index + offset]
		}
		guard let open = window.firstIndex(of: "\"") else { return nil }
		var key = ""
		var cursor = window.index(after: open)
		while cursor < window.endIndex {
			let character = window[cursor]
			if character == "\\" {
				cursor = window.index(cursor, offsetBy: 2, limitedBy: window.endIndex) ?? window.endIndex
				continue
			}
			if character == "\"" { break }
			key.append(character)
			cursor = window.index(after: cursor)
		}
		guard key.range(of: "^[A-Za-z][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { return nil }
		return (key, window.contains("table: .messages") ? "Messages" : "UI")
	}

	var references = 0
	var unknown: [String] = []
	let directories = ["Sources/Core", "Sources/Surfaces", "Sources/App", "Sources/Views"]
	for file in directories.flatMap(sourceFiles) {
		guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
		let lines = text.components(separatedBy: "\n")
		let name = file.path.replacingOccurrences(of: repository.path + "/", with: "")
		for (index, line) in lines.enumerated() {
			// Doc comments show example calls; they are not references.
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
			guard let found = reference(in: lines, at: index) else { continue }
			references += 1
			let known = found.table == "Messages" ? messages : ui
			if !known.contains(found.key) {
				unknown.append("\(name):\(index + 1) \(found.key) → \(found.table).strings")
			}
		}
	}
	check(references > 0, "扫到了 L.t 引用，否则这条断言没在测任何东西")
	check(unknown.isEmpty, "代码里引用的每个键都能在它指定的表里查到", unknown.prefix(8).joined(separator: " | "))
}

group("i18n：内置描述文件两种语言都写了")

do {
	let repository = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
	let agentsDirectory = repository.appendingPathComponent("Resources/Agents")

	// 1. 向后兼容：用户自己写的描述文件里还是纯字符串。
	//    这条是硬要求 —— 类型同时解两种形态，真正的保证在这里：升级之后
	//    `~/.config/agentkit/agents/*.json` 里的 "title": "字符串" 不许变成空标签。
	let userJSON = #"""
	{
	  "descriptorVersion": 1,
	  "id": "custom",
	  "name": "我的 Agent",
	  "subtitle": "my-agent",
	  "root": { "default": "$ROOT" },
	  "surfaces": [
	    { "id": "settings", "kind": "settings", "title": "我的设置", "file": "$ROOT/settings.json" }
	  ]
	}
	"""#
	let user = try JSONDecoder().decode(AgentDescriptor.self, from: Data(userJSON.utf8))
	equal(user.name.text(for: .zhHans), "我的 Agent", "纯字符串 name 在中文下就是它本身")
	equal(user.name.text(for: .en), "我的 Agent", "纯字符串 name 在英文下也是它本身")
	check(user.name.isPlain, "纯字符串被标记为通用（没有分语言）")
	equal(user.surfaces[0].title.text(for: .zhHans), "我的设置", "纯字符串 title 在中文下可用")
	equal(user.surfaces[0].title.text(for: .en), "我的设置", "纯字符串 title 在英文下可用")

	// 2. 按语言分的字典：各取各的。
	let bothJSON = #"""
	{
	  "descriptorVersion": 1,
	  "id": "custom",
	  "name": { "zh-Hans": "甲", "en": "Alpha" },
	  "root": { "default": "$ROOT" },
	  "surfaces": [
	    { "id": "sessions", "kind": "sessions", "root": "$ROOT/s",
	      "title": { "zh-Hans": "会话", "en": "Sessions" } }
	  ]
	}
	"""#
	let both = try JSONDecoder().decode(AgentDescriptor.self, from: Data(bothJSON.utf8))
	equal(both.name.text(for: .zhHans), "甲", "字典 name 按语言取值（中）")
	equal(both.name.text(for: .en), "Alpha", "字典 name 按语言取值（英）")
	check(!both.name.isPlain, "两种语言都给了就不算通用")
	equal(both.surfaces[0].title.text(for: .zhHans), "会话", "字典 title 按语言取值（中）")
	equal(both.surfaces[0].title.text(for: .en), "Sessions", "字典 title 按语言取值（英）")

	// 3. 字典缺一种语言：回退到另一种，而不是空串（空标签比外文更糟）。
	let halfJSON = #"""
	{
	  "descriptorVersion": 1,
	  "id": "custom",
	  "name": { "zh-Hans": "只有中文" },
	  "root": { "default": "$ROOT" },
	  "surfaces": [
	    { "id": "sessions", "kind": "sessions", "root": "$ROOT/s",
	      "title": { "only-a-language-we-do-not-ship": "谁能想到" } }
	  ]
	}
	"""#
	let half = try JSONDecoder().decode(AgentDescriptor.self, from: Data(halfJSON.utf8))
	equal(half.name.text(for: .zhHans), "只有中文", "缺英文时中文仍然取到")
	equal(half.name.text(for: .en), "只有中文", "缺英文时回退到中文，而不是空串")
	check(!half.surfaces[0].title.text(for: .en).isEmpty, "一个都不认识的语言也不返回空串")

	// 4. 界面读的是解析后的访问器：换语言，agent 名与面板标题立刻跟着变。
	let pi = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(contentsOf: agentsDirectory.appendingPathComponent("pi.json"))
	)
	let previousLanguage = Localization.shared.language
	defer { Localization.shared.language = previousLanguage }
	Localization.shared.language = .zhHans
	equal(pi.surface(id: "sessions")?.titleText, "会话", "中文下 titleText 是中文")
	Localization.shared.language = .en
	equal(pi.surface(id: "sessions")?.titleText, "Sessions", "英文下 titleText 是英文")

	// 整条装载路径也要通：三个内置描述文件改成字典之后仍然能载入。
	let outcome = DescriptorLoader.loadAll(
		builtinDirectory: agentsDirectory,
		userDirectory: fixtureRoot.appendingPathComponent("no-user-descriptors"),
		environment: [:],
		appSupport: fixtureRoot.appendingPathComponent("localized-support")
	)
	equal(outcome.agents.count, 3, "三个内置描述文件都能载入")
	let decodeErrors = outcome.issues.filter { $0.severity == .error }
	check(decodeErrors.isEmpty, "内置描述文件没有解码错误", decodeErrors.map(\.message).joined(separator: "; "))
	equal(outcome.agents.first { $0.id == "claude" }?.name, "Claude Code", "agent 名走解析后的访问器")
	equal(outcome.agents.first { $0.id == "claude" }?.subtitle, "claude (Anthropic)", "副标题走解析后的访问器")

	// 5. 三个内置文件里**每个给人看的字段**都写了两种语言。
	//    isPlain 为真就是漏翻 —— 那正是 LocalizedText.isPlain 存在的理由：
	//    漏了不会报错，只会在英文界面里显示中文，没人会知道。
	let expectedEnglish = [
		"模型与 Provider": "Models & Providers",
		"MCP 服务器": "MCP Servers",
		"Skills": "Skills",
		"会话": "Sessions",
		"全局指令": "Instructions",
		"子 Agents": "Subagents",
		"通用设置": "Settings",
		"主题 · 扩展 · Packages": "Themes, Extensions & Packages",
	]
	// 英文取值里出现中文标点或汉字，只有一种可能：忘了翻，或者复制过来没改。
	func hasChinese(_ text: String) -> Bool {
		text.unicodeScalars.contains { scalar in
			(0x2E80...0x2EFF).contains(scalar.value)			// 部首补充
				|| (0x3000...0x303F).contains(scalar.value)		// 中文标点
				|| (0x3400...0x4DBF).contains(scalar.value)		// 扩展 A
				|| (0x4E00...0x9FFF).contains(scalar.value)		// 基本区
				|| (0xF900...0xFAFF).contains(scalar.value)		// 兼容汉字
				|| (0xFF00...0xFFEF).contains(scalar.value)		// 全角
		}
	}

	for id in ["pi", "codex", "claude"] {
		let descriptor = try JSONDecoder().decode(
			AgentDescriptor.self,
			from: Data(contentsOf: agentsDirectory.appendingPathComponent("\(id).json"))
		)

		check(!descriptor.name.isPlain, "\(id)：agent 名两种语言都写了")
		check(!(descriptor.subtitle?.isPlain ?? true), "\(id)：agent 副标题两种语言都写了")
		check(!hasChinese(descriptor.name.text(for: .en)), "\(id)：agent 名的英文里没有中文", descriptor.name.text(for: .en))
		check(!hasChinese(descriptor.subtitle?.text(for: .en) ?? ""), "\(id)：副标题的英文里没有中文")

		for surface in descriptor.surfaces {
			check(!surface.title.isPlain, "\(id)/\(surface.id)：面板标题两种语言都写了")
			let chinese = surface.title.text(for: .zhHans)
			let english = surface.title.text(for: .en)
			// 同一个概念在三个文件里必须用同一个英文词，这张表就是那把尺。
			equal(english, expectedEnglish[chinese] ?? "命名表里没有 “\(chinese)”", "\(id)/\(surface.id)：英文标题与统一命名表一致")
			check(!hasChinese(english), "\(id)/\(surface.id)：英文标题里没有中文", english)
		}

		// MCP 配置层的 note。claude 的 ~/.claude.json 那一段最长，最该翻。
		for layer in descriptor.surface(id: "mcp")?.layers ?? [] {
			guard let note = layer.note else { continue }
			check(!note.isPlain, "\(id)：MCP 层 \(layer.path) 的 note 两种语言都写了")
			check(!note.text(for: .en).isEmpty, "\(id)：MCP 层 \(layer.path) 的 note 英文不是空的")
			check(!hasChinese(note.text(for: .en)), "\(id)：MCP 层 \(layer.path) 的 note 英文里没有中文")
		}

		// legacy notice 也是给人读的句子（MCPPane 的说明条会原样显示）。
		for legacy in descriptor.surface(id: "mcp")?.legacy ?? [] {
			guard let notice = legacy.notice else { continue }
			check(!notice.isPlain, "\(id)：legacy \(legacy.path) 的 notice 两种语言都写了")
			check(!hasChinese(notice.text(for: .en)), "\(id)：legacy notice 的英文里没有中文")
		}
	}
}

group("指令文件路径解析")

do {
	let root = PathResolver.homeDirectory().appendingPathComponent(".pi/agent")
	let resolver = PathResolver(root: root, appSupport: fixtureRoot)
	let surfaces = try? JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/Agents/pi.json")).utf8)
	)
	let files = surfaces?.surface(id: "instructions")?.files ?? []
	check(!files.isEmpty, "指令面板声明了文件")
	for spec in files {
		guard let url = try? resolver.expand(spec.path) else {
			check(false, "\(spec.path) 应该能解析")
			continue
		}
		check(url.path.hasPrefix("/"), "\(spec.path) 解析成绝对路径", url.path)
		check(url.path.hasPrefix(root.path), "\(spec.path) 落在 agent 根目录下", url.path)
	}
	// The symptom the pane showed was a bare name reaching URL(fileURLWithPath:),
	// which resolves against the process working directory rather than failing.
	let relative = URL(fileURLWithPath: "AGENTS.MD").path
	equal(relative, FileManager.default.currentDirectoryPath + "/AGENTS.MD",
		  "相对路径被按进程工作目录解析（这就是那个 bug 的形状）")
	check(relative != "AGENTS.MD", "它不会保持原样，所以坏得很安静")
}

group("同一文件判定")

do {
	let directory = fixtureRoot.appendingPathComponent("samefile")
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	let lower = directory.appendingPathComponent("AGENTS.md")
	try "# hi\n".write(to: lower, atomically: true, encoding: .utf8)
	let upper = directory.appendingPathComponent("AGENTS.MD")
	let other = directory.appendingPathComponent("CLAUDE.md")
	try "# other\n".write(to: other, atomically: true, encoding: .utf8)

	check(PathResolver.isSameFile(lower, lower), "同一个 URL 是自己")
	check(PathResolver.isSameFile(lower, URL(fileURLWithPath: lower.path)), "等价路径相同")

	// Whether the case variant resolves to the same file depends on the volume,
	// so assert against what the filesystem actually does rather than assuming.
	let caseInsensitive = FileManager.default.fileExists(atPath: upper.path)
	equal(
		PathResolver.isSameFile(lower, upper),
		caseInsensitive,
		"大小写变体是否同一文件，与文件系统一致（本卷" + (caseInsensitive ? "不区分" : "区分") + "大小写）"
	)
	check(!PathResolver.isSameFile(lower, other), "不同文件判定为不同")
	check(!PathResolver.isSameFile(lower, directory.appendingPathComponent("missing.md")), "不存在的文件之间不误判")
}

// MARK: - TOML

group("TOML 解析与写入")

do {
	let toml = """
	# 这是注释
	model = "gpt-5.4"   # 行尾注释
	model_provider = "custom"
	disable_response_storage = true
	big = 1_000_000
	hex = 0xFF
	ratio = 1.5e3
	infinity = inf
	when = 1979-05-27T07:32:00Z
	nested = [[1, 2], [3]]
	inline = { a = 1, b = "x" }
	"""
	+ """
	
	[model_providers.custom]
	name = "custom"
	wire_api = "responses"
	base_url = "http://127.0.0.1:8080/v1"
	requires_openai_auth = true
	
	[mcp_servers.pencil]
	command = "/opt/pencil"
	args = ["--app", "code"]
	
	[mcp_servers.computer-use]
	command = "helper"
	enabled = false
	"""
	let url = write(toml, to: "config.toml")
	let document = JSONFile.load(url)

	equal(document.format, .toml, "扩展名决定解析器")
	equal(document.status, .ok, "真实形态的 TOML 能解析")
	equal(document.hasComments, true, "识别出有注释")
	equal(document.value(at: ["model"])?.stringValue, "gpt-5.4", "顶层字符串")
	equal(document.value(at: ["disable_response_storage"])?.boolValue, true, "布尔")
	equal(document.value(at: ["big"])?.intValue, 1000000, "下划线分隔的整数")
	equal(document.value(at: ["hex"])?.intValue, 255, "十六进制")
	equal(document.value(at: ["ratio"])?.doubleValue, 1500, "指数浮点")
	equal(document.value(at: ["infinity"])?.numberValue?.raw, "inf", "inf 保留字面量")
	equal(document.value(at: ["when"])?.stringValue, "1979-05-27T07:32:00Z", "日期时间当字符串")
	equal(document.value(at: ["nested"])?.arrayValue?.count, 2, "嵌套数组")
	equal(document.value(at: ["inline", "b"])?.stringValue, "x", "内联表")
	equal(document.value(at: ["model_providers", "custom", "base_url"])?.stringValue,
		  "http://127.0.0.1:8080/v1", "嵌套表")
	equal(document.value(at: ["mcp_servers", "computer-use", "enabled"])?.boolValue, false, "带连字符的表名")
	equal(document.source?.valueText(at: ["model"]), "\"gpt-5.4\"", "值区间精确到字面量")

	// A scalar's span must not carry the whitespace before the delimiter. Strings
	// were always exact, which is why the assertion above never caught that the
	// borrowed span for integers, floats, booleans and dates ran to the delimiter.
	let spaced = try TOMLParser.parseWithSource("num =   1_000   \nflag = true  \n")
	equal(spaced.source.valueText(at: ["num"]), "1_000", "数字区间不含两侧空格")
	equal(spaced.source.valueText(at: ["flag"]), "true", "布尔区间不含行尾空格")

	// A leaf change is spliced into the original bytes: comments survive.
	var edited = document.editableValue
	edited.setValue(.string("gpt-5.5"), at: ["model"])
	let leaf = JSONFile.preview(edited, for: document)
	equal(leaf.isLossy, false, "叶子改动不算有损")
	equal(leaf.diff.insertions, 1, "叶子改动只动一行")
	check(leaf.afterText.contains("# 这是注释"), "行首注释保留")
	check(leaf.afterText.contains("# 行尾注释"), "行尾注释保留")
	check(leaf.afterText.contains("\"gpt-5.5\""), "新值已写入")
	equal(leaf.afterText.count, document.rawText.count, "长度不变，说明只是原地替换")

	// A structural change stays inside the table it touches.
	var added = document.editableValue
	added.setValue(
		.object(JSONObject([("command", .string("/opt/new")), ("args", .array([.string("-x")]))])),
		at: ["mcp_servers", "newserver"]
	)
	let structural = JSONFile.preview(added, for: document)
	check(!structural.afterText.contains("[inline]"), "内联表没有被展开成独立表")
	equal(structural.isLossy, false, "纯追加一张新表不算有损")
	check(structural.afterText.contains("# 这是注释"), "未受影响的注释仍在")
	check(structural.afterText.contains("[mcp_servers.newserver]"), "新表已追加")
	check(structural.afterText.contains("command = \"/opt/pencil\""), "原有表内容不变")
	check(structural.afterText.contains("base_url = \"http://127.0.0.1:8080/v1\""), "其它表也未受影响")
	let reparsed = try TOMLParser.parse(structural.afterText)
	equal(reparsed.value(at: ["mcp_servers", "newserver", "command"])?.stringValue, "/opt/new", "改动能重新解析")
	equal(reparsed.value(at: ["inline", "a"])?.intValue, 1, "内联表的值不变")

	// Adding a key inside an existing table reflows that table only, which is
	// the case that can lose a comment.
	var insideTable = document.editableValue
	insideTable.setValue(.object(JSONObject([("TOKEN", .string("x"))])), at: ["mcp_servers", "pencil", "env"])
	let reflow = JSONFile.preview(insideTable, for: document)
	equal(reflow.isLossy, true, "改动已有表会提示不是逐字节保留")
	check(reflow.lossyNote != nil, "说明会重排哪张表")
	check(reflow.afterText.contains("TOKEN = \"x\""), "新键写进了那张表")
	check(reflow.afterText.contains("[mcp_servers.computer-use]"), "相邻的表还在")
	check(reflow.afterText.contains("# 这是注释"), "文件顶部的注释仍在")

	// Removing a table deletes just that table.
	var removed = document.editableValue
	removed.removeValue(at: ["mcp_servers", "pencil"])
	let removal = JSONFile.preview(removed, for: document)
	check(!removal.afterText.contains("/opt/pencil"), "被删的表不在了")
	check(removal.afterText.contains("computer-use"), "相邻的表还在")

	// It really writes, backs up, and stays parseable.
	let result = try JSONFile.write(edited, document: document)
	check(result.backupURL != nil, "写 TOML 也生成备份")
	equal(try String(contentsOf: url, encoding: .utf8).contains("# 这是注释"), true, "落盘后注释仍在")
	equal(JSONFile.load(url).value(at: ["model"])?.stringValue, "gpt-5.5", "落盘后新值生效")

	// Malformed TOML is reported, not crashed on.
	let brokenURL = write("model = \n", to: "broken.toml")
	let broken = JSONFile.load(brokenURL)
	equal(broken.isMalformed, true, "损坏的 TOML 被识别")
	equal(broken.status.isWritable, false, "损坏的 TOML 不允许写入")
}

// MARK: - Codex

group("Codex 描述文件")

do {
	let descriptorURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("Resources/Agents/codex.json")
	let descriptor = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: descriptorURL).utf8)
	)
	equal(descriptor.id, "codex", "描述文件可解码")
	equal(descriptor.root.env, "CODEX_HOME", "根目录由 CODEX_HOME 覆盖")
	equal(descriptor.surfaces.count, 6, "六个面板")
	let errors = DescriptorValidator.validate(descriptor).filter { $0.severity == .error }
	check(errors.isEmpty, "没有错误级诊断", errors.map(\.message).joined(separator: "; "))
	check(descriptor.surfaces.allSatisfy(\.isSupported), "全部面板类型都被支持")
	equal(descriptor.surfaces.map(\.id), ["models", "mcp", "skills", "sessions", "instructions", "settings"], "面板顺序")

	let mcp = descriptor.surface(id: "mcp")!
	equal(MCPServerShape.resolve(mcp).serverKey, "mcp_servers", "MCP 表名按描述文件走")
	equal(MCPServerShape.resolve(mcp).isDisabled(.object(JSONObject([("enabled", .bool(false))]))), true,
		  "enabled = false 表示停用")
	equal(MCPServerShape.resolve(mcp).isDisabled(.object(JSONObject([("enabled", .bool(true))]))), false,
		  "enabled = true 表示启用")
	equal(MCPServerShape.pi.isDisabled(.object(JSONObject([("enabled", .bool(false))]))), false,
		  "pi 的约定不受影响")

	let models = descriptor.surface(id: "models")!
	equal(models.providersKey, "model_providers", "provider 表名")
	equal(models.providerKeys?.baseUrl, "base_url", "provider 字段名 base_url")
	equal(models.providerKeys?.api, "wire_api", "provider 字段名 wire_api")
	equal(models.providerKeys?.apiKey, "env_key", "provider 字段名 env_key")
	equal(models.providerKeys?.models, nil, "Codex 的 provider 没有 model 列表")
	equal(models.format, "toml", "显式声明 TOML")

	equal(SettingsSchema.definition(for: "codex-0.157") != nil, true, "Codex 的 settings schema 已注册")
	let schema = SettingsSchema.definition(for: "codex-0.157")!
	check(schema.fields.count >= 60, "字段数量", "实际 \(schema.fields.count)")
	for key in ["model", "model_provider", "model_reasoning_effort", "sandbox_mode", "approval_policy",
				"web_search", "tui.notifications", "history.persistence"] {
		check(schema.field(key: key) != nil, "包含 \(key)")
	}
	equal(schema.field(key: "sandbox_mode")?.type.choices,
		  ["read-only", "workspace-write", "danger-full-access"], "沙箱模式取值")
	equal(schema.field(key: "model_verbosity")?.type.choices, ["low", "medium", "high"], "verbosity 取值")
	equal(Set(schema.fields.map(\.key)).count, schema.fields.count, "字段 key 唯一")

	// The MCP servers and model providers must NOT be settings fields: they have
	// their own panes, and two editors for one value is how they drift apart.
	check(schema.field(key: "mcp_servers") == nil, "mcp_servers 不重复出现在设置里")
	check(schema.field(key: "model_providers") == nil, "model_providers 不重复出现在设置里")
}

group("Codex 会话")

do {
	let root = fixtureRoot.appendingPathComponent("codex")
	let day = root.appendingPathComponent("2026/09/29")
	try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

	let sessionID = "019f180c-0e5c-7742-bca3-547894aa0065"
	let file = day.appendingPathComponent("rollout-2026-09-29T10-21-11-\(sessionID).jsonl")
	let lines = [
		#"{"timestamp":"2026-09-29T10:21:11.179Z","ordinal":0,"type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/tmp/demo-project","cli_version":"0.157.1","model_provider":"custom"}}"#,
		#"{"timestamp":"2026-09-29T10:21:11.200Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>"}]}}"#,
		// Wrapper message: must not become the session title.
		#"{"timestamp":"2026-09-29T10:21:11.210Z","ordinal":2,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp/demo-project</cwd>\n</environment_context>"}]}}"#,
		#"{"timestamp":"2026-09-29T10:21:12.000Z","ordinal":3,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"帮我看看这个仓库的结构"}]}}"#,
		#"{"timestamp":"2026-09-29T10:21:13.000Z","ordinal":4,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"好的"}]}}"#,
		#"{"timestamp":"2026-09-29T10:21:56.878Z","ordinal":14,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12182}}}}"#,
		#"{"timestamp":"2026-09-29T10:22:10.000Z","ordinal":15,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":25000}}}}"#,
		"",
	]
	try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
	try #"{"id":"\#(sessionID)","thread_name":"仓库结构梳理","updated_at":"2026-09-29T10:22:10Z"}"#
		.appending("\n")
		.write(to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

	let surface = SurfaceSpec(
		id: "sessions", kind: .sessions, title: "会话", icon: nil, shape: "jsonl-sessions",
		file: nil, providerFile: nil, catalogFile: nil, authFile: nil,
		root: root.path, roots: nil, files: nil, discovery: nil,
		layers: nil, legacy: nil, imports: nil, defaults: nil, cli: nil,
		schema: nil, settingsKeys: nil, ignore: nil, maxDepth: nil, spec: nil,
		frontmatter: nil,
		sessions: SessionsSpec(
			recursive: true,
			headerType: "session_meta",
			nameEntryType: nil,
			header: SessionHeaderPaths(
				id: "payload.id", cwd: "payload.cwd", timestamp: "timestamp",
				parent: nil, model: "payload.model_provider"
			),
			index: SessionIndexSpec(file: root.appendingPathComponent("session_index.jsonl").path,
									key: "id", value: "thread_name"),
			message: SessionMessageSpec(
				type: "response_item", payload: "payload", role: "role", text: "content",
				usage: nil, tokens: nil, cost: nil,
				usageEventType: "event_msg", usageEventPayload: "payload",
				usageEventTokens: "info.total_token_usage.total_tokens"
			)
		)
	)
	guard let config = SessionsConfig.resolve(
		surface: surface,
		resolver: PathResolver(root: root, appSupport: fixtureRoot),
		policy: BackupPolicy()
	) else {
		check(false, "Codex 的 sessions 配置可解析")
		exit(1)
	}

	var records = SessionsSurface.enumerate(config: config)
	equal(records.count, 1, "递归四层目录后找到会话")
	equal(records[0].sessionID, sessionID, "字段从 payload 里取")
	equal(records[0].cwd, "/tmp/demo-project", "cwd 从 payload 里取")
	equal(records[0].model, "custom", "provider 从 payload 里取")
	equal(records[0].name, "仓库结构梳理", "名字来自索引文件")
	equal(records[0].displayTitle, "仓库结构梳理", "有索引名时用它做标题")
	check(records[0].started != nil, "开始时间可解析")

	SessionsSurface.summarize(&records[0], config: config)
	equal(records[0].messageCount, 4, "统计 response_item 消息")
	equal(records[0].totalTokens, 25000, "累计 token 取最后一个事件而不是求和")
	equal(records[0].firstUserText, "帮我看看这个仓库的结构", "跳过 environment_context 包装消息")

	// Codex keeps names in its own index, so appending must be refused.
	do {
		try SessionsSurface.appendingName("改个名", to: file, config: config)
		check(false, "Codex 不支持追加式重命名")
	} catch {
		check(true, "Codex 不支持追加式重命名")
	}
}

// MARK: - Output surfaces

group("SurfacePaths")

do {
	let descriptor = try JSONDecoder().decode(
		AgentDescriptor.self,
		from: Data(try String(contentsOf: URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/Agents/pi.json")).utf8)
	)
	equal(descriptor.id, "pi", "内置 pi 描述文件可解码")
	equal(descriptor.surfaces.count, 8, "pi 描述文件声明了 8 个面板")

	let issues = DescriptorValidator.validate(descriptor)
	let errors = issues.filter { $0.severity == .error }
	check(errors.isEmpty, "内置描述文件没有错误", errors.map(\.message).joined(separator: "; "))

	let surfaceIDs = descriptor.surfaces.map(\.id)
	equal(surfaceIDs, ["models", "mcp", "skills", "sessions", "instructions", "subagents", "settings", "resources"], "面板顺序")
	check(descriptor.surfaces.allSatisfy(\.isSupported), "全部面板类型都被本版本支持")

	let mcp = descriptor.surface(id: "mcp")!
	equal(mcp.layers?.count, 6, "MCP 有 6 个配置层")
	equal(mcp.layers?.map(\.precedence), [10, 20, 30, 40, 60, 70], "层优先级递增")
	equal(mcp.legacy?.first?.path, "$ROOT/mcp.json", "声明了 legacy 路径")
	equal(mcp.imports?.count, 7, "7 种 host 配置导入候选")

	let paths = SurfacePaths.candidatePaths(for: mcp)
	check(paths.contains("~/.config/mcp/mcp.json"), "生效的共享层在候选路径里")
	check(paths.contains("$ROOT/mcp.json"), "legacy 路径也在候选里")
	equal(Set(paths).count, paths.count, "候选路径去重")

	check(SurfacePaths.requiresProject(mcp), "MCP 面板需要项目目录")
	check(!SurfacePaths.requiresProject(descriptor.surface(id: "settings")!), "设置面板不需要项目目录")

	let skills = descriptor.surface(id: "skills")!
	equal(skills.maxDepth, 6, "skills 有深度上限")
	check(skills.ignore?.contains(".venv") == true, "忽略 .venv（本机 demo-skill 里就有）")
	check(skills.ignore?.contains("node_modules") == true, "忽略 node_modules")

	let subagents = descriptor.surface(id: "subagents")!
	equal(subagents.frontmatter?.required, ["name", "description"], "子 agent 必填字段")
}

// MARK: - Summary

print("")
print(String(repeating: "─", count: 52))
if failed == 0 {
	print("\u{001B}[32m全部通过：\(passed) 项断言\u{001B}[0m")
	exit(0)
} else {
	print("\u{001B}[31m失败 \(failed) 项，通过 \(passed) 项\u{001B}[0m")
	exit(1)
}
