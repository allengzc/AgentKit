//
//  DocumentationState.swift
//  AgentKit
//
//  Puts a pane into a state that a screenshot needs.
//
//  The images under `docs/` are generated from a fixture by Tools/make-demo.sh,
//  and some of them show a state that otherwise needs a click: the preview
//  toggle, an expanded folder in the file list, an open diff sheet. Rather than
//  hand-editing the screenshots, the script launches the app with
//
//      AGENTKIT_DOC_STATE=preview:1,expand:references,diff:1
//
//  Everything here is off unless that variable is set, and it only ever drives
//  state a user could reach by clicking.
//

import AppKit
import Foundation

enum DocumentationState {
	/// Parsed once: `key:value` pairs separated by commas, a bare `key` meaning "on".
	private static let values: [String: String] = {
		guard let raw = ProcessInfo.processInfo.environment["AGENTKIT_DOC_STATE"] else { return [:] }
		var parsed: [String: String] = [:]
		for pair in raw.split(separator: ",") {
			let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
			guard let key = parts.first, !key.isEmpty else { continue }
			parsed[key] = parts.count > 1 ? parts[1] : "1"
		}
		return parsed
	}()

	static func isOn(_ key: String) -> Bool { values[key] != nil }
	static func string(_ key: String) -> String? { values[key] }

	/// Whether a launch should bring itself to the front.
	///
	/// Automated runs (screenshots, layout verification) start the app many times
	/// in a row; each activation takes focus from the user. Those runs set
	/// `AGENTKIT_NO_ACTIVATE=1`.
	static var shouldActivateOnLaunch: Bool {
		ProcessInfo.processInfo.environment["AGENTKIT_NO_ACTIVATE"] == nil
	}

	/// True when any state was requested, so callers can skip the work entirely.
	static var isActive: Bool { !values.isEmpty }

	/// `size:1120x700` pins the window frame, so a set of screenshots is uniform
	/// instead of inheriting whatever size the window was last left at.
	static func windowSize() -> NSSize? {
		guard let raw = values["size"] else { return nil }
		let parts = raw.lowercased().split(separator: "x")
		guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
			width > 200, height > 200
		else { return nil }
		return NSSize(width: width, height: height)
	}

	/// `appearance:light` / `appearance:dark`, so every screenshot in a set comes
	/// out in the same mode instead of following whatever the clock decided.
	static func appearance() -> NSAppearance? {
		switch values["appearance"] {
		case "light": return NSAppearance(named: .aqua)
		case "dark": return NSAppearance(named: .darkAqua)
		default: return nil
		}
	}
}
