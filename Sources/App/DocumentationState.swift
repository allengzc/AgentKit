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
import QuartzCore

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

	/// `snapshot:/path/to.png` writes the window to a PNG and quits.
	///
	/// Rendered by the app itself rather than captured with `screencapture`,
	/// which needs Screen Recording permission for anything narrower than the
	/// whole display — and which cannot see a window that is not on the active
	/// Space. Asking AppKit to draw its own view hierarchy needs neither, so the
	/// screenshots can be regenerated on any machine, headless, in CI.
	static func writeSnapshot(to path: String) {
		let window = NSApp.windows
			.filter { $0.contentView != nil && $0.frame.width > 400 }
			.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
		guard let window, let content = window.contentView else {
			FileHandle.standardError.write(Data("no window to snapshot\n".utf8))
			return
		}
		// The theme frame, not the content view: it includes the title bar, which
		// is what makes the picture recognisable as a macOS window.
		let view = content.superview ?? content
		guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }

		// `cacheDisplay(in:to:)` walks `draw(_:)`, which a layer-backed SwiftUI
		// hierarchy does not use — it produced shifted, half-empty frames. The
		// layer tree is the real content, so render that.
		if let layer = view.layer {
			NSGraphicsContext.saveGraphicsState()
			if let context = NSGraphicsContext(bitmapImageRep: rep) {
				NSGraphicsContext.current = context
				layer.render(in: context.cgContext)
			}
			NSGraphicsContext.restoreGraphicsState()
		} else {
			view.cacheDisplay(in: view.bounds, to: rep)
		}

		guard let data = rep.representation(using: .png, properties: [:]) else { return }
		do {
			try data.write(to: URL(fileURLWithPath: path))
		} catch {
			FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
		}
	}

	/// Seconds to wait before the snapshot, so the first scan has finished.
	static var snapshotDelay: TimeInterval {
		Double(values["snapshot_delay"] ?? "") ?? 6
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
