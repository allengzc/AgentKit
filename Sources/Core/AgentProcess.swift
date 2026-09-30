//
//  AgentProcess.swift
//  AgentKit
//
//  Running the agent's CLI, and finding it in the first place.
//
//  A GUI app launched from Finder inherits almost no PATH, and pi lives under
//  nvm, so "just run `pi`" does not work. AgentKit resolves the binary through
//  three fallbacks and caches the answer.
//

import Foundation

public struct ProcessResult {
	public let exitCode: Int32
	public let stdout: String
	public let stderr: String
	public let timedOut: Bool
	public let launchError: String?

	public var succeeded: Bool { launchError == nil && !timedOut && exitCode == 0 }

	public var combinedOutput: String {
		stderr.isEmpty ? stdout : stdout + (stdout.isEmpty ? "" : "\n") + stderr
	}
}

public enum AgentProcess {
	/// Runs a process and drains both pipes concurrently.
	///
	/// Reading only one pipe to EOF while the other fills deadlocks once the
	/// second pipe's buffer is full, so both are drained on their own queues.
	public static func run(
		executable: URL,
		arguments: [String] = [],
		workingDirectory: URL? = nil,
		environment: [String: String]? = nil,
		timeout: TimeInterval = 30,
		standardInput: Data? = nil
	) -> ProcessResult {
		let process = Process()
		process.executableURL = executable
		process.arguments = arguments
		if let workingDirectory { process.currentDirectoryURL = workingDirectory }
		if let environment { process.environment = environment }

		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		let stdinPipe = Pipe()
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe
		process.standardInput = stdinPipe

		var stdoutData = Data()
		var stderrData = Data()
		let group = DispatchGroup()
		let lock = NSLock()
		let stdoutQueue = DispatchQueue(label: "com.allengzc.agentkit.stdout")
		let stderrQueue = DispatchQueue(label: "com.allengzc.agentkit.stderr")

		// Launch before anything reads. Starting the readers first meant the
		// failure path closed the read ends under a blocked reader, and closing a
		// descriptor mid-read raises an Objective-C exception that Swift cannot
		// catch — it aborted the whole app whenever a command could not launch.
		do {
			try process.run()
		} catch {
			stdinPipe.fileHandleForWriting.closeFile()
			stdoutPipe.fileHandleForReading.closeFile()
			stderrPipe.fileHandleForReading.closeFile()
			return ProcessResult(
				exitCode: -1,
				stdout: "",
				stderr: "",
				timedOut: false,
				launchError: error.localizedDescription
			)
		}

		group.enter()
		stdoutQueue.async {
			let data = AgentProcess.drain(stdoutPipe.fileHandleForReading)
			lock.lock(); stdoutData = data; lock.unlock()
			group.leave()
		}
		group.enter()
		stderrQueue.async {
			let data = AgentProcess.drain(stderrPipe.fileHandleForReading)
			lock.lock(); stderrData = data; lock.unlock()
			group.leave()
		}

		if let standardInput {
			stdinPipe.fileHandleForWriting.write(standardInput)
		}
		stdinPipe.fileHandleForWriting.closeFile()

		var timedOut = false
		if timeout > 0 {
			let deadline = DispatchTime.now() + timeout
			if process.isRunning {
				let watchdog = DispatchWorkItem {
					if process.isRunning {
						timedOut = true
						process.terminate()
					}
				}
				DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
			}
		}

		process.waitUntilExit()
		group.wait()

		return ProcessResult(
			exitCode: process.terminationStatus,
			stdout: String(data: stdoutData, encoding: .utf8) ?? "",
			stderr: String(data: stderrData, encoding: .utf8) ?? "",
			timedOut: timedOut,
			launchError: nil
		)
	}

	/// Reads a pipe to EOF.
	///
	/// `readDataToEndOfFile()` raises `NSFileHandleOperationException` when the
	/// descriptor has gone bad, and an Objective-C exception cannot be caught in
	/// Swift, so one dead child process took the app down with it.
	/// `read(upToCount:)` reports the same condition as a thrown error.
	static func drain(_ handle: FileHandle) -> Data {
		var out = Data()
		while true {
			guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
			out.append(chunk)
		}
		return out
	}

}

// MARK: - Login shell environment

/// Resolves the PATH a terminal would have.
///
/// `zsh -lic` is used because the user's node/pi live behind nvm initialised
/// from their shell profile; there is no other reliable way to see that from a
/// GUI process.
public enum LoginShell {
	private static let lock = NSLock()
	private static var cachedPath: String?

	public static func path() -> String {
		lock.lock()
		defer { lock.unlock() }
		if let cachedPath { return cachedPath }

		let fallback = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
		let result = AgentProcess.run(
			executable: URL(fileURLWithPath: "/bin/zsh"),
			arguments: ["-lic", "printf %s \"$PATH\""],
			timeout: 10
		)
		let value = result.succeeded ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
		let resolved = value.isEmpty ? fallback : value
		cachedPath = resolved
		Log.process.debug("login shell PATH resolved (\(resolved.count, privacy: .public) chars)")
		return resolved
	}

	/// A GUI-safe environment: the inherited one plus a PATH that can find node.
	public static func environment(
		rootOverride: (name: String, value: String)? = nil,
		extra: [String: String] = [:]
	) -> [String: String] {
		var environment = ProcessInfo.processInfo.environment
		environment["PATH"] = path()
		environment["HOME"] = PathResolver.homeDirectory().path
		if environment["TERM"] == nil { environment["TERM"] = "xterm-256color" }
		// Keep the CLI from opening a browser or pager while AgentKit drives it.
		if environment["PAGER"] == nil { environment["PAGER"] = "cat" }
		if environment["NO_COLOR"] == nil { environment["NO_COLOR"] = "1" }
		if let rootOverride {
			environment[rootOverride.name] = rootOverride.value
		}
		for (key, value) in extra { environment[key] = value }
		return environment
	}
}

// MARK: - CLI resolution

public enum CLILocator {
	/// Finds the agent's executable: explicit candidates first (they beat PATH
	/// because nvm installs are versioned and PATH may point at an old node),
	/// then the login-shell PATH, then a bare `command -v`.
	public static func locate(
		spec: CLISpec?,
		resolver: PathResolver
	) -> URL? {
		guard let spec else { return nil }

		if let candidates = spec.candidates, !candidates.isEmpty {
			let matches = resolver.expandCandidates(candidates)
			if let best = matches.max(by: { versionLess(versionKey($0.path), versionKey($1.path)) }) {
				Log.process.debug("resolved \(spec.name, privacy: .public) from candidates: \(best.path, privacy: .public)")
				return best
			}
		}

		let shellResult = AgentProcess.run(
			executable: URL(fileURLWithPath: "/bin/zsh"),
			arguments: ["-lic", "command -v \(spec.name)"],
			timeout: 10
		)
		let located = shellResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		if shellResult.succeeded, !located.isEmpty {
			let url = URL(fileURLWithPath: located)
			if FileManager.default.isExecutableFile(atPath: url.path) {
				Log.process.debug("resolved \(spec.name, privacy: .public) from login shell: \(located, privacy: .public)")
				return url
			}
		}

		Log.process.info("could not locate \(spec.name, privacy: .public)")
		return nil
	}

	/// Sorts version-looking path components so `v24` beats `v20` and `v9`.
	///
	/// Only a component that is *entirely* dotted digits (optionally `v`-prefixed)
	/// counts. A looser "starts with a digit" test would treat a UUID directory
	/// name as a version number.
	static func versionKey(_ path: String) -> [Int] {
		path.split(separator: "/")
			.compactMap { versionComponents(of: String($0)) }
			.flatMap { $0 }
	}

	/// `v24.12.0` → `[24, 12, 0]`; anything else → nil.
	static func versionComponents(of component: String) -> [Int]? {
		var text = component
		if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
		guard !text.isEmpty else { return nil }
		let parts = text.split(separator: ".", omittingEmptySubsequences: false)
		var numbers: [Int] = []
		for part in parts {
			guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
			numbers.append(value)
		}
		return numbers.isEmpty ? nil : numbers
	}

	/// Lexicographic comparison that pads the shorter key with zeros, so
	/// `[24, 12]` still beats `[20, 19, 5]`.
	static func versionLess(_ lhs: [Int], _ rhs: [Int]) -> Bool {
		for index in 0..<max(lhs.count, rhs.count) {
			let left = index < lhs.count ? lhs[index] : 0
			let right = index < rhs.count ? rhs[index] : 0
			if left != right { return left < right }
		}
		return false
	}

	public static func version(of executable: URL, arguments: [String]?) -> String? {
		// The login shell's PATH, not the inherited one. These CLIs are node
		// scripts (`#!/usr/bin/env node`), and a GUI app started from Finder
		// inherits `/usr/bin:/bin:…`, so the binary resolves but running it fails
		// with exit 127 `env: node: No such file or directory` — measured with
		// `env PATH=/usr/bin:/bin …/bin/pi --version`, and the sidebar then says
		// 未知 for a CLI that is installed and working in a terminal. The panes
		// already drive their CLIs through `LoginShell.environment()`; the version
		// query was the one place left using the ambient environment.
		let result = AgentProcess.run(
			executable: executable,
			arguments: arguments ?? ["--version"],
			environment: LoginShell.environment(),
			timeout: 15
		)
		guard result.succeeded else { return nil }
		let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text.split(separator: "\n").first.map(String.init)
	}

	/// Splits a version line into the number and, when the CLI prints one, the
	/// product name that came with it.
	///
	/// The three agents answer `--version` in three different shapes —
	/// `0.87.1`, `codex-cli 0.157.1`, `2.1.283 (Claude Code)` — and the sidebar
	/// shows the number on its own. Parsing here rather than in the view keeps
	/// the rule testable; the raw line is what `version(of:arguments:)` already
	/// returns and stays untouched, so the parenthesised product name is still
	/// available for the hover text.
	///
	/// The number is the first `\d+(\.\d+)+` run: a bare major version (`2`) or a
	/// date-like integer is not a version, and requiring the dot keeps a package
	/// name such as `@openai/codex` from being mistaken for one. Whatever
	/// remains after removing that run, once surrounding whitespace and the
	/// separators a CLI wraps it in (`(`, `)`, `-`, `,`) are stripped, is the
	/// product name — nil when nothing is left, which is the common case.
	public static func parseVersion(from raw: String) -> (number: String, product: String?)? {
		guard let expression = try? NSRegularExpression(pattern: "\\d+(\\.\\d+)+") else { return nil }
		let text = raw as NSString
		let full = NSRange(location: 0, length: text.length)
		guard let match = expression.firstMatch(in: raw, options: [], range: full) else { return nil }

		let number = text.substring(with: match.range)
		let remainder = text.replacingCharacters(in: match.range, with: "")
		// One trim pass over the union of the separators strips `(Claude Code)`
		// and `- 1.0.0 -` alike: `trimmingCharacters` consumes every leading and
		// trailing character that is in the set, in any order, so a lone `(`, its
		// matching `)` and the spaces around them all go. Interior separators
		// survive, which is what keeps `codex-cli` in one piece.
		let product = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "()-, \t\r\n"))
		return (number, product.isEmpty ? nil : product)
	}
}
