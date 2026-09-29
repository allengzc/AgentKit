//
//  ShellActions.swift
//  AgentKit
//
//  The handful of things that leave the app: reveal in Finder, hand a file to
//  the user's editor, open a terminal, and copy to the pasteboard.
//

import Foundation
import AppKit

@MainActor
public enum ShellActions {
	public static func reveal(_ url: URL) {
		if FileManager.default.fileExists(atPath: url.path) {
			NSWorkspace.shared.activateFileViewerSelecting([url])
		} else {
			NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
		}
	}

	/// Opens with whatever the user has registered, never hard-coding an editor.
	public static func openExternally(_ url: URL) {
		guard FileManager.default.fileExists(atPath: url.path) else { return }
		NSWorkspace.shared.open(url)
	}

	public static func openTerminal(command: String, workingDirectory: URL?) {
		let scripts = PathResolver.defaultAppSupport.appendingPathComponent("scripts", isDirectory: true)
		try? FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
		let scriptURL = scripts.appendingPathComponent("agentkit-\(UUID().uuidString).command")

		var lines = ["#!/bin/zsh"]
		if let workingDirectory {
			lines.append("cd \(ShellActions.quote(workingDirectory.path))")
		}
		lines.append("exec \(command)")
		lines.append("")
		let script = lines.joined(separator: "\n")

		do {
			try script.write(to: scriptURL, atomically: true, encoding: .utf8)
			try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
		} catch {
			Log.app.error("failed to write terminal script: \(error.localizedDescription, privacy: .public)")
			return
		}

		let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.activates = true
		NSWorkspace.shared.open([scriptURL], withApplicationAt: terminal, configuration: configuration) { _, error in
			if let error {
				Log.app.error("failed to open Terminal: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	public static func copyToPasteboard(_ text: String) {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
	}

	/// Quotes a path for /bin/zsh.
	public static func quote(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	public static func fileSize(_ url: URL) -> String {
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			let size = attributes[.size] as? NSNumber
		else { return "—" }
		// `ByteCountFormatter` has no locale to set, and this runs outside a view
		// so it cannot inherit the environment — the system locale would leak the
		// wrong unit names into the interface. `ByteCountFormatStyle` takes one.
		return Int64(size.int64Value).formatted(
			ByteCountFormatStyle(style: .file).locale(Locale(identifier: Localization.shared.language.rawValue))
		)
	}
}
