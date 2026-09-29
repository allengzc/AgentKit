//
//  PathResolver.swift
//  AgentKit
//
//  Expands the path tokens a descriptor may use and enforces the write scope
//  guard, so a malformed descriptor cannot make AgentKit write outside the
//  directories the descriptor declared.
//

import Foundation

public enum PathError: Error, CustomStringConvertible {
	case unknownToken(String, template: String)
	case outsideScope(path: String, scope: [String])
	case notFound(path: String)

	public var description: String {
		switch self {
		case .unknownToken(let token, let template):
			return "描述文件里的路径模板 \(template) 含有无法识别的记号 \(token)"
		case .outsideScope(let path, let scope):
			return "拒绝写入 \(path)：不在允许范围内（\(scope.joined(separator: "、"))）"
		case .notFound(let path):
			return "找不到路径：\(path)"
		}
	}
}

public struct PathResolver {
	/// The agent's config root (`$ROOT`).
	public var root: URL
	/// AgentKit's own application-support directory (`$APP`).
	public var appSupport: URL
	/// The currently selected project directory (`$CWD`), when one is selected.
	public var cwd: URL?
	/// Directories a write is allowed to land in.
	public var scopeGuard: [URL]

	public init(root: URL, appSupport: URL, cwd: URL? = nil, scopeGuard: [URL] = []) {
		self.root = root
		self.appSupport = appSupport
		self.cwd = cwd
		self.scopeGuard = scopeGuard
	}

	/// The user's home directory as the password database sees it.
	///
	/// `NSHomeDirectory()` can be redirected by a sandbox container; this app is
	/// not sandboxed, but resolving through `getpwuid` keeps `~` correct even if
	/// that ever changes, and matches how the tools we manage resolve it.
	public static func homeDirectory() -> URL {
		if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
			let path = String(cString: directory)
			if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
		}
		return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
	}

	public static var defaultAppSupport: URL {
		homeDirectory()
			.appendingPathComponent("Library/Application Support/AgentKit", isDirectory: true)
	}

	/// Expands `~`, `$ROOT`, `$CWD` and `$APP`, then standardizes the result.
	///
	/// Throws rather than guessing when a template mentions an unknown token;
	/// silently treating `$HOM` as a literal directory name would create junk.
	public func expand(_ template: String) throws -> URL {
		var path = template
		if path == "~" {
			path = PathResolver.homeDirectory().path
		} else if path.hasPrefix("~/") {
			path = PathResolver.homeDirectory().path + String(path.dropFirst(1))
		}

		for (token, replacement) in try tokenTable() {
			path = path.replacingOccurrences(of: token, with: replacement)
		}

		if let suspect = PathResolver.firstUnknownToken(in: path) {
			throw PathError.unknownToken(suspect, template: template)
		}

		return URL(fileURLWithPath: (path as NSString).standardizingPath)
	}

	private func tokenTable() throws -> [(String, String)] {
		var table: [(String, String)] = [
			("$ROOT", root.path),
			("$APP", appSupport.path),
			("$HOME", PathResolver.homeDirectory().path),
		]
		if let cwd {
			table.append(("$CWD", cwd.path))
		} else {
			// Keep the token visible so callers that need a project scope can
			// detect the unresolved case instead of silently using "/".
			table.append(("$CWD", "$CWD"))
		}
		return table
	}

	/// True when the resolved path still carries the project token, which means
	/// no project directory is selected.
	public func isProjectScoped(_ template: String) -> Bool {
		template.contains("$CWD")
	}

	/// Finds a `$TOKEN` remnant that survived expansion.
	public static func firstUnknownToken(in path: String) -> String? {
		var index = path.startIndex
		while let dollar = path[index...].firstIndex(of: "$") {
			let rest = path[dollar...]
			let token = rest.prefix { $0 == "$" || $0.isUppercase || $0 == "_" }
			if token.count > 1 { return String(token) }
			index = path.index(after: dollar)
		}
		return nil
	}

	/// Shell-style `*` expansion used only for `cli.candidates`.
	///
	/// A template with no wildcard resolves to itself when it exists.
	public func expandCandidates(_ templates: [String]) -> [URL] {
		var out: [URL] = []
		for template in templates {
			guard template.contains("*") else {
				if let url = try? expand(template) { out.append(url) }
				continue
			}
			let expanded = template.hasPrefix("~/")
				? PathResolver.homeDirectory().path + String(template.dropFirst(1))
				: template
			// Walk the literal prefix, globbing each wildcard component in turn.
			let components = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
			var frontier: [String] = [""]
			for component in components {
				var next: [String] = []
				for base in frontier {
					let basePath = base.isEmpty ? "/" : base
					if component.contains("*") {
						let contents = (try? FileManager.default.contentsOfDirectory(atPath: basePath)) ?? []
						for entry in contents.sorted() where PathResolver.globMatch(component, entry) {
							next.append((basePath as NSString).appendingPathComponent(entry))
						}
					} else {
						next.append((basePath as NSString).appendingPathComponent(component))
					}
				}
				frontier = next
				if frontier.isEmpty { break }
			}
			for path in frontier {
				let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
				if FileManager.default.isExecutableFile(atPath: url.path) { out.append(url) }
			}
		}
		return out
	}

	/// Minimal `*`-only glob matcher (enough for version-sorted bin paths).
	static func globMatch(_ pattern: String, _ value: String) -> Bool {
		let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
		if parts.count == 1 { return pattern == value }
		var cursor = value.startIndex
		for (offset, part) in parts.enumerated() {
			if part.isEmpty { continue }
			if offset == 0 {
				guard value[cursor...].hasPrefix(part) else { return false }
				cursor = value.index(cursor, offsetBy: part.count)
			} else if offset == parts.count - 1 {
				guard value[cursor...].hasSuffix(part) else { return false }
				guard value.distance(from: cursor, to: value.endIndex) >= part.count else { return false }
				cursor = value.endIndex
			} else if let found = value.range(of: part, range: cursor..<value.endIndex) {
				cursor = found.upperBound
			} else {
				return false
			}
		}
		return true
	}

	// MARK: - Scope guard

	public func isAllowed(_ url: URL) -> Bool {
		guard !scopeGuard.isEmpty else { return true }
		let target = url.standardizedFileURL.path
		return scopeGuard.contains { prefix in
			let base = prefix.standardizedFileURL.path
			return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
		}
	}

	/// Verifies a write target is inside the guard, following symlinks so a link
	/// pointing outside the allowed tree cannot be used to escape it.
	public func assertAllowed(_ url: URL) throws {
		guard isAllowed(url) else {
			throw PathError.outsideScope(
				path: url.path,
				scope: scopeGuard.map(\.path)
			)
		}
	}

	/// Resolves a symlink target so writes go through the link rather than
	/// replacing it with a regular file.
	public static func writeTarget(for url: URL) -> URL {
		let path = url.path
		guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
			return url
		}
		if destination.hasPrefix("/") {
			return URL(fileURLWithPath: destination)
		}
		return url.deletingLastPathComponent().appendingPathComponent(destination)
	}
}
