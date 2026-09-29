//
//  windowid.swift
//  AgentKit
//
//  Prints the CGWindowID of on-screen windows whose owner name matches an
//  argument, so `screencapture -l <id>` can grab just that window instead of
//  the whole desktop.
//
//  Only `CGWindowListCopyWindowInfo` is used: `CGWindowListCreateImage` is
//  unavailable on macOS 26, which is why the capture itself is shelled out to
//  `screencapture`.
//
//  Usage: windowid [-a] [-o] <OwnerName> [TitleSubstring]
//         -a   print every match, one per line; default is the frontmost
//         -o   include windows another app is covering. `screencapture -l`
//              reads the window's own backing store, so a covered window can
//              still be captured — which is what lets a check run without
//              stealing focus from whatever the user is doing.
//

import Foundation
import CoreGraphics

let arguments = Array(CommandLine.arguments.dropFirst())
var printAll = false
var includeCovered = false
var positional: [String] = []
for argument in arguments {
	switch argument {
	case "-a": printAll = true
	case "-o": includeCovered = true
	default: positional.append(argument)
	}
}

guard let owner = positional.first else {
	FileHandle.standardError.write(Data("usage: windowid [-a] <OwnerName> [TitleSubstring]\n".utf8))
	exit(2)
}
let titleFilter = positional.count > 1 ? positional[1] : nil

let options: CGWindowListOption = includeCovered
	? [.optionAll, .excludeDesktopElements]
	: [.optionOnScreenOnly, .excludeDesktopElements]
guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
	FileHandle.standardError.write(Data("could not read the window list\n".utf8))
	exit(1)
}

struct Match {
	let id: Int
	let layer: Int
	let title: String
	let area: Double
}

var matches: [Match] = []
for window in windowList {
	guard let ownerName = window[kCGWindowOwnerName as String] as? String,
		ownerName.caseInsensitiveCompare(owner) == .orderedSame,
		let windowID = window[kCGWindowNumber as String] as? Int
	else { continue }
	let title = (window[kCGWindowName as String] as? String) ?? ""
	if let titleFilter, !title.localizedCaseInsensitiveContains(titleFilter) { continue }
	let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
	let bounds = window[kCGWindowBounds as String] as? [String: Any]
	let rect = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
	matches.append(Match(id: windowID, layer: layer, title: title, area: rect.width * rect.height))
}

// The main window is the largest one: an app also owns menu-bar strips, shadow
// slivers and panels, and the biggest is the one worth looking at.
matches.sort { $0.area > $1.area }

guard !matches.isEmpty else {
	FileHandle.standardError.write(Data("no window owned by \(owner)\n".utf8))
	exit(1)
}

if printAll {
	for match in matches { print(match.id) }
} else {
	print(matches[0].id)
}
