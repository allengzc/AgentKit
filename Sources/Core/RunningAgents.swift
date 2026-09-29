//
//  RunningAgents.swift
//  AgentKit
//
//  Whether an agent CLI is currently running.
//
//  A running pi holds the config it read at startup, so a change AgentKit
//  makes will not take effect until `/reload` or a restart; and a running pi
//  may rewrite files under us. Both are worth telling the user about.
//

import Foundation
import AppKit

public struct RunningProcess: Identifiable, Hashable {
	public let pid: Int32
	public let command: String
	public let arguments: String

	public var id: Int32 { pid }
}

public enum RunningAgents {
	/// Looks for processes whose executable or argument list mentions the
	/// agent's CLI name. Cheap enough to poll every few seconds.
	public static func scan(names: [String]) -> [RunningProcess] {
		guard !names.isEmpty else { return [] }
		let result = AgentProcess.run(
			executable: URL(fileURLWithPath: "/bin/ps"),
			arguments: ["-axo", "pid=,comm=,args="],
			timeout: 5
		)
		guard result.succeeded else { return [] }

		var out: [RunningProcess] = []
		for line in result.stdout.split(separator: "\n") {
			let text = line.trimmingCharacters(in: .whitespaces)
			guard !text.isEmpty else { continue }
			let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
			let command = String(parts[1])
			let arguments = parts.count > 2 ? String(parts[2]) : ""

			// Skip AgentKit itself and anything that merely greps for the name.
			if arguments.contains("ps -axo") { continue }
			if command.hasSuffix("/AgentKit") { continue }

			let haystack = command + " " + arguments
			guard names.contains(where: { matches($0, in: haystack, command: command, arguments: arguments) }) else {
				continue
			}
			out.append(RunningProcess(pid: pid, command: command, arguments: arguments))
		}
		return out
	}

	/// Matches the CLI name as a path component or as a bare command, without
	/// matching `grep pi` or an unrelated `pihole` process.
	static func matches(_ name: String, in haystack: String, command: String, arguments: String) -> Bool {
		if command == name || command.hasSuffix("/" + name) { return true }
		let tokens = arguments.split(separator: " ").map(String.init)
		if tokens.first == name { return true }
		if tokens.contains(where: { $0.hasSuffix("/" + name) }) { return true }
		_ = haystack
		return false
	}

	/// Convenience for a `pi`-style CLI whose binary is a node script.
	public static func scanForCLI(named name: String, packageHint: String?) -> [RunningProcess] {
		var names = [name]
		if let packageHint, let tail = packageHint.split(separator: "/").last {
			names.append(String(tail))
		}
		return scan(names: names)
	}
}
