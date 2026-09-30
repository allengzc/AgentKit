//
//  ExternalChange.swift
//  AgentKit
//
//  Whether a watcher event batch concerns a particular set of paths.
//
//  The watcher is deliberately coarse: it watches the nearest *existing*
//  ancestor of every path a surface declares, so a path that does not exist yet
//  is still noticed when it appears. Everything below that ancestor therefore
//  arrives in the callback — including the agent's own state while it runs.
//
//  A pane that reloads on all of it reloads continuously. Measured on a fixture
//  tree: appending to a session log under the root produced 6 refresh batches in
//  2.5 s, i.e. ~2.4 UI-wide reloads per second, because `~/.pi/agent/sessions`
//  is itself a declared path. Reloading is now a per-pane decision, and this is
//  the rule it uses: does the batch touch the paths *this* pane reads?
//

import Foundation

public enum ExternalChange {
	/// True when any of `changed` is one of `urls` or lives underneath one.
	///
	/// Compared by path component, so `/a/bc` does not count as being under
	/// `/a/b` — a raw string prefix test would say it does.
	public static func touches(_ urls: [URL], changed: [String]) -> Bool {
		let bases = urls.map { standardized($0.path) }
		guard !bases.isEmpty else { return false }
		return changed.contains { path in
			let candidate = standardized(path)
			return bases.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
		}
	}

	/// Resolves the two easy ways a path can be written differently and still
	/// name the same file: a trailing slash, and a symlinked prefix. The second
	/// one is not hypothetical — FSEvents reports the resolved path, so a fixture
	/// under `/tmp` arrives as `/private/tmp`, while the URL the pane compares
	/// against was built from `AGENTKIT_HOME` and still says `/tmp`. Without this
	/// the filter silently matches nothing.
	///
	/// Canonicalisation walks up to the longest *existing* prefix and runs
	/// `realpath(3)` on that, then puts the remaining components back: the paths
	/// being compared are usually the ones that do not exist yet (a declared
	/// `settings.json` before it is created), and `realpath` fails outright on
	/// those. `URL.resolvingSymlinksInPath()` is not used because it does **not**
	/// resolve a leading `/tmp -> private/tmp` here — measured: it returns
	/// `/tmp/…` for both spellings while `realpath` returns `/private/tmp/…`.
	static func standardized(_ path: String) -> String {
		var text = (path as NSString).standardizingPath
		while text.count > 1, text.hasSuffix("/") { text.removeLast() }

		var existing = text
		var tail: [String] = []
		while !FileManager.default.fileExists(atPath: existing) {
			let parent = (existing as NSString).deletingLastPathComponent
			if parent.isEmpty || parent == existing || parent == "/" { break }
			tail.insert((existing as NSString).lastPathComponent, at: 0)
			existing = parent
		}
		guard let resolved = realpath(existing, nil) else { return text }
		defer { free(resolved) }
		var canonical = String(cString: resolved)
		while canonical.count > 1, canonical.hasSuffix("/") { canonical.removeLast() }
		return tail.isEmpty ? canonical : canonical + "/" + tail.joined(separator: "/")
	}
}
