//
//  Skills-pane performance benchmark.
//
//  Measures both halves of "the list gets slow when there are many skills":
//    A. SkillsScanner.scan  — the filesystem walk + per-skill file read
//    B. a simulated body pass — the derived-property work the pane does on
//       every SwiftUI re-render (header problem count, row content, search)
//
//  Written for the fix in `perf(views): Skills 列表在 skill 多了以后很卡`: the
//  pane has no assertion that can express "this got 15000x cheaper", and a
//  stopwatch on a hand-driven app is not evidence. Every number in that commit
//  message comes from this file; run it again to reproduce them.
//
//  Run: Tools/bench-skills.sh [real]
//
//  `real` also scans the roots pi.json declares on this machine, which is what
//  puts a fixture measurement in perspective: 18 skills and 61 ms here, 500
//  skills and 393 ms there.
//

import Foundation

// MARK: - Fixture

let fixtureRoot = URL(fileURLWithPath: "/tmp/agentkit-bench")

func buildFixture(count: Int, at root: URL) {
	let fm = FileManager.default
	guard !fm.fileExists(atPath: root.path) else { return }
	try? fm.createDirectory(at: root, withIntermediateDirectories: true)

	for index in 0..<count {
		let name = String(format: "skill-%03d", index)
		let dir = root.appendingPathComponent(name)
		try? fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
		try? fm.createDirectory(at: dir.appendingPathComponent("references"), withIntermediateDirectories: true)

		let manifest = """
		---
		name: \(name)
		description: Use when the user asks about topic \(index) and needs a long, realistic description that runs to a couple of sentences so the frontmatter block is the size one would actually see in a real skill library, including a trailing clause.
		license: MIT
		allowed-tools: Read, Write, Bash
		metadata:
		  version: 1.2.3
		  author: fixture
		---

		# \(name)

		Steps for topic \(index). Read `references/one.md` first, then run
		`scripts/run.sh`. Do not guess; the reference material is authoritative.

		## Details

		\(String(repeating: "Filler line that stands in for real instructions in a skill body.\n", count: 20))
		"""
		try? manifest.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
		try? "# readme\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
		for n in 0..<8 {
			try? String(repeating: "x", count: 400)
				.write(to: dir.appendingPathComponent("references/ref-\(n).md"), atomically: true, encoding: .utf8)
		}
		for n in 0..<3 {
			try? "#!/bin/sh\n"
				.write(to: dir.appendingPathComponent("scripts/s\(n).sh"), atomically: true, encoding: .utf8)
		}
	}
}

// MARK: - Timing

func milliseconds(_ body: () -> Void) -> Double {
	let start = DispatchTime.now().uptimeNanoseconds
	body()
	let end = DispatchTime.now().uptimeNanoseconds
	return Double(end - start) / 1_000_000
}

/// Median of `runs`, which is what the eye feels; a single run on a busy
/// machine measures the machine.
func median(_ runs: Int, _ body: () -> Void) -> Double {
	var samples: [Double] = []
	for _ in 0..<runs { samples.append(milliseconds(body)) }
	return samples.sorted()[samples.count / 2]
}

// MARK: - Workloads

let ignore: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".cache", "logs", ".DS_Store"]
let policy = BackupPolicy.default

/// `@main` rather than top-level statements: swiftc only allows top-level code
/// in a file called `main.swift`, and this one is named after what it measures.
@main
enum SkillsBenchmark {
	static func main() {
		setbuf(stdout, nil)
		print("fixture: \(fixtureRoot.path)")
		print("")

		// Real-machine mode: scan the roots pi.json actually declares, so the
		// numbers are not only about a synthetic fixture.
		if CommandLine.arguments.contains("real") {
			let home = URL(fileURLWithPath: NSHomeDirectory())
			let realRoots: [(spec: RootEntry, url: URL)] = [
				(spec: RootEntry(path: "~/.pi/agent/skills", scope: "user", writable: true, shared: false, type: "skills"), url: home.appendingPathComponent(".pi/agent/skills")),
				(spec: RootEntry(path: "~/.agents/skills", scope: "user", writable: false, shared: true, type: "skills"), url: home.appendingPathComponent(".agents/skills"))
			]
			var real = SkillsSnapshot()
			let realTime = median(5) {
				real = SkillsScanner.scan(roots: realRoots, ignore: ignore, maxDepth: 6, policy: policy)
			}
			let bundled = real.skills.reduce(0) { $0 + $1.topLevel.count }
			print(String(format: "── real machine ──  %d skill(s), %d bundled top-level entries, scan %7.2f ms",
				real.skills.count, bundled, realTime))
			for entry in real.skills.sorted(by: { $0.topLevel.count > $1.topLevel.count }).prefix(5) {
				print("   \(entry.name): \(entry.topLevel.count) bundled entries")
			}
			let issuesPass = median(20) {
				var n = 0
				for entry in real.skills where !entry.issues.isEmpty { n += 1 }
				_ = n
			}
			print(String(format: "   header problem count              %7.3f ms", issuesPass))
			print("")
		}

		for count in [50, 200, 500] {
			measure(count: count)
		}
	}

	static func measure(count: Int) {
		let root = fixtureRoot.appendingPathComponent("skills-\(count)")
		buildFixture(count: count, at: root)

		let localRoots: [(spec: RootEntry, url: URL)] = [
			(spec: RootEntry(path: root.path, scope: "user", writable: true, shared: false, type: "skills"), url: root)
		]

		var snapshot = SkillsSnapshot()
		let scanTime = median(5) {
			snapshot = SkillsScanner.scan(roots: localRoots, ignore: ignore, maxDepth: 6, policy: policy)
		}
		let skills = snapshot.skills
		let bytes = skills.reduce(0) { $0 + $1.document.text.utf8.count }

		print("── \(skills.count) skills (\(bytes / 1024) KB of SKILL.md) ──")
		print(String(format: "  scan (walk + read + hash)        %7.2f ms", scanTime))

		// B: one body pass. The pane evaluates the header badges, then every row
		// that the LazyVStack materialises (25 is a generous viewport), then the
		// search filter once.
		let visible = min(25, skills.count)
		let pass = median(20) {
			var problems = 0
			for entry in skills where !entry.issues.isEmpty { problems += 1 }
			for entry in skills.prefix(visible) {
				_ = entry.name
				_ = entry.issues
				_ = entry.hasDescription
				_ = entry.description
				_ = entry.scope
			}
			_ = problems
		}
		print(String(format: "  body pass, empty search         %7.2f ms", pass))

		let needle = "topic 12"
		// The pane's own filter, before and after the precomputed haystack.
		let searchOld = median(20) {
			_ = skills.filter {
				$0.name.lowercased().contains(needle)
					|| $0.description.lowercased().contains(needle)
					|| $0.directory.path.lowercased().contains(needle)
			}
		}
		let searchNew = median(20) {
			_ = skills.filter { $0.searchText.contains(needle) }
		}
		print(String(format: "  search, three fields lowercased %7.2f ms", searchOld))
		print(String(format: "  search, precomputed haystack     %7.2f ms", searchNew))

		// C: resolving "is this row selected?" for every visible row while a
		// query is active. Before the fix the row body went through `selected`,
		// which re-ran the whole filter — O(visible × skills).
		let selectedID = skills.first?.id
		let selectedOld = median(10) {
			for entry in skills.prefix(visible) {
				let filtered = skills.filter { $0.searchText.contains(needle) }
				_ = (filtered.first { $0.id == selectedID } ?? filtered.first)?.id == entry.id
			}
		}
		// After the fix: the filter runs once per body pass and every row
		// compares one already-resolved id.
		let selectedNew = median(10) {
			let entries = skills.filter { $0.searchText.contains(needle) }
			let current = entries.first { $0.id == selectedID } ?? entries.first
			for entry in entries.prefix(visible) {
				_ = current?.id == entry.id
			}
		}
		print(String(format: "  per-row `selected`, before        %7.2f ms", selectedOld))
		print(String(format: "  filter once + id compare          %7.2f ms", selectedNew))
		print("")
	}
}
