//
//  click.swift
//  AgentKit
//
//  Posts a mouse click at screen coordinates, so a check can exercise a real
//  button instead of only the state behind it.
//
//  Written because several bugs in this app were only reachable by clicking —
//  a preview that crashed on a nested code span, and a disclosure that would not
//  open — and reading the code did not reveal either.
//
//  Usage: click <x> <y>            left click at screen points
//         click --move <x> <y>     move the pointer only
//         click --window <owner> <fx> <fy>
//                                  click at the given fraction of the window's
//                                  bounds, which avoids guessing screen points
//
//  Needs Accessibility permission for the process that runs it; without it the
//  events are dropped silently and this tool cannot tell you why.
//

import CoreGraphics
import Foundation

func windowBounds(owner: String) -> CGRect? {
	guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
		as? [[String: Any]]
	else { return nil }
	var best: CGRect?
	for window in list {
		guard let name = window[kCGWindowOwnerName as String] as? String,
			name.caseInsensitiveCompare(owner) == .orderedSame,
			let bounds = window[kCGWindowBounds as String] as? [String: Any],
			let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
		else { continue }
		// The window worth clicking is the biggest one: the others are the menu
		// bar, shadow strips and panels.
		if best == nil || rect.width * rect.height > (best!.width * best!.height) {
			best = rect
		}
	}
	return best
}

var arguments = Array(CommandLine.arguments.dropFirst())
var moveOnly = false

if let index = arguments.firstIndex(of: "--move") {
	arguments.remove(at: index)
	moveOnly = true
}

if let index = arguments.firstIndex(of: "--window") {
	guard arguments.count > index + 3 else {
		FileHandle.standardError.write(Data("usage: click --window <owner> <fx> <fy>\n".utf8))
		exit(2)
	}
	let owner = arguments[index + 1]
	let fx = Double(arguments[index + 2]) ?? 0
	let fy = Double(arguments[index + 3]) ?? 0
	guard let bounds = windowBounds(owner: owner) else {
		FileHandle.standardError.write(Data("no window owned by \(owner)\n".utf8))
		exit(1)
	}
	let point = CGPoint(x: bounds.minX + bounds.width * fx, y: bounds.minY + bounds.height * fy)
	arguments = ["\(point.x)", "\(point.y)"]
	print("window \(owner) bounds=\(bounds) -> click at \(point)")
}

let numbers = arguments.compactMap(Double.init)
guard numbers.count >= 2 else {
	FileHandle.standardError.write(Data("usage: click [--move] <x> <y>\n".utf8))
	exit(2)
}
let point = CGPoint(x: numbers[0], y: numbers[1])

let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType) {
	CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
		.post(tap: .cghidEventTap)
}

// Move first: a click at a stale pointer position can be delivered as a drag.
post(.mouseMoved)
usleep(150_000)
if moveOnly {
	print("moved to \(point)")
	exit(0)
}
post(.leftMouseDown)
usleep(70_000)
post(.leftMouseUp)
usleep(70_000)
print("clicked \(point)")
