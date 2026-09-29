//
//  ConfigPatch.swift
//  AgentKit
//
//  Choosing how to turn "this tree became that tree" into the smallest edit the
//  file's format allows.
//
//  JSON and TOML share the leaf case: a changed scalar is spliced into the
//  original bytes, so untouched lines — comments and odd formatting included —
//  come back out identical. They differ in the structural case. JSON can be
//  re-serialized wholesale with nothing lost. TOML cannot: a canonical rewrite
//  drops comments and expands inline tables, so the structural path edits only
//  the tables that actually changed and leaves the rest of the file alone.
//

import Foundation

public enum ConfigFormat: String {
	case json
	case toml

	/// The file extension decides, unless the descriptor says otherwise.
	public static func detect(url: URL, override: String? = nil) -> ConfigFormat {
		if let override, let format = ConfigFormat(rawValue: override.lowercased()) { return format }
		return url.pathExtension.lowercased() == "toml" ? .toml : .json
	}
}

/// The text a document should become, and whether producing it lost anything.
public struct ConfigRender {
	public let text: String
	/// True when formatting or comments in the rewritten region were not
	/// preserved, so the confirmation sheet can say so.
	public let isLossy: Bool
	public let note: String?
}

public enum ConfigPatch {
	public static func render(_ updated: JSONValue, from document: JSONDocument) -> ConfigRender {
		switch document.format {
		case .json:
			return ConfigRender(
				text: JSONPatch.render(updated, from: document),
				isLossy: false,
				note: nil
			)

		case .toml:
			switch JSONPatch.plan(
				original: document.editableValue,
				updated: updated,
				source: document.source
			) {
			case .unchanged:
				return ConfigRender(text: document.rawText, isLossy: false, note: nil)
			case .splice(let text):
				return ConfigRender(text: text, isLossy: false, note: nil)
			case .rewrite:
				if let patched = TOMLPatch.rewriteTables(updated, from: document) {
					// Appending a new table loses nothing; replacing an existing
					// one reflows it, so any comment inside it is gone.
					let lossy = patched.replacedTables && document.hasComments
					return ConfigRender(
						text: patched.text,
						isLossy: lossy,
						note: lossy
							? L.t("write.diff.lossyTables", "改动只落在受影响的表里，其它表保持原样；被改动的那张表会按标准格式重排，其中的注释会丢失。", table: .messages)
							: nil
					)
				}
				return ConfigRender(
					text: TOMLWriter().serialize(updated),
					isLossy: true,
					note: L.t("write.diff.lossyDocument", "这个改动碰到了文件顶层，整份 TOML 会按标准格式重写：注释会丢失，内联表会被展开成独立表。", table: .messages)
				)
			}
		}
	}
}

/// Structural edits that stay inside the table they touch.
public enum TOMLPatch {
	public struct TablePatch {
		public let text: String
		/// True when an existing table was reflowed rather than a new one appended.
		public let replacedTables: Bool
	}

	/// Replaces only the tables whose contents changed.
	///
	/// Returns nil when the change reaches the document's top level, where
	/// patching a table at a time cannot express it.
	public static func rewriteTables(_ updated: JSONValue, from document: JSONDocument) -> TablePatch? {
		guard document.format == .toml, let source = document.source else { return nil }
		let old = document.editableValue
		guard let oldRoot = old.objectValue, let newRoot = updated.objectValue else { return nil }

		// A key added to or removed from the root changes the document's shape in
		// a way table replacement cannot describe.
		guard Set(oldRoot.keys) == Set(newRoot.keys) else { return nil }
		for key in oldRoot.keys {
			let oldValue = oldRoot[key]
			let newValue = newRoot[key]
			let oldIsScalar = oldValue?.objectValue == nil
				&& !(oldValue?.arrayValue.map(TOMLWriter.isArrayOfTables) ?? false)
			if oldIsScalar, oldValue != newValue { return nil }
		}

		let rangedKeys = document.tableRanges
		let rangedPaths = rangedKeys.keys.map { $0.components(separatedBy: "\u{1F}") }
		let mask = "\u{0}masked"

		// Tables the file declares with a header, whose contents changed.
		var edits: [(range: Range<Int>, replacement: String)] = []
		for (key, range) in rangedKeys {
			let path = key.components(separatedBy: "\u{1F}")
			let oldValue = old.value(at: path)
			let newValue = updated.value(at: path)
			if oldValue == newValue { continue }

			if let newValue, let object = newValue.objectValue {
				edits.append((range, trimTrailingNewlines(TOMLWriter().serializeBlock(path: path, value: object))))
			} else {
				edits.append((range, ""))
			}
		}

		// Tables that are new to the file.
		//
		// "New" means absent from the *old tree*, not merely absent from the
		// header list: a value written inline (`inline = { a = 1 }`) has no
		// header of its own, and treating it as new would append a duplicate
		// `[inline]` table and produce a file that no longer parses.
		var candidates: [[String]] = []
		TOMLPatch.collectTablePaths(updated, path: [], into: &candidates)
		candidates.sort { $0.count < $1.count }

		var appended: [[String]] = []
		var appendedKeys = Set<String>()
		for path in candidates {
			if rangedKeys[JSONSource.pathKey(path)] != nil { continue }
			// Already covered by an ancestor appended as a whole.
			let coveredByAncestor = path.count > 1 && (1..<path.count).contains { count in
				appendedKeys.contains(JSONSource.pathKey(Array(path.prefix(count))))
			}
			if coveredByAncestor { continue }
			guard updated.value(at: path)?.objectValue != nil else { continue }
			guard old.value(at: path) == nil else { continue }
			appended.append(path)
			appendedKeys.insert(JSONSource.pathKey(path))
		}

		// Everything outside the tables we are about to replace must be
		// untouched, or this patch would silently drop part of the change.
		var probe = updated
		for path in appended { probe.removeValue(at: path) }
		for path in rangedPaths {
			probe.setValue(.string(mask), at: path)
		}
		var baseline = old
		for path in rangedPaths {
			baseline.setValue(.string(mask), at: path)
		}
		guard probe == baseline else { return nil }

		guard !edits.isEmpty || !appended.isEmpty else { return nil }

		var bytes = Array(source.text.utf8)
		for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
			guard edit.range.lowerBound >= 0, edit.range.upperBound <= bytes.count else { return nil }
			bytes.replaceSubrange(edit.range, with: Array(edit.replacement.utf8))
		}
		var text = String(bytes: bytes, encoding: .utf8) ?? ""
		for path in appended {
			guard let object = updated.value(at: path)?.objectValue else { continue }
			let block = trimTrailingNewlines(TOMLWriter().serializeBlock(path: path, value: object))
			if !text.hasSuffix("\n") { text += "\n" }
			text += "\n" + block + "\n"
		}
		return TablePatch(text: text, replacedTables: !edits.isEmpty)
	}

	/// Every path in `value` that a `[header]` could address.
	static func collectTablePaths(_ value: JSONValue, path: [String], into out: inout [[String]]) {
		guard let object = value.objectValue else { return }
		for (key, child) in object.pairs {
			let childPath = path + [key]
			if child.objectValue != nil {
				out.append(childPath)
				collectTablePaths(child, path: childPath, into: &out)
			}
			// Array-of-tables elements are skipped: appending one needs `[[name]]`
			// rather than `[name]`, which is a different edit.
		}
	}

	static func isTableLike(_ value: JSONValue) -> Bool {
		if value.objectValue != nil { return true }
		if let items = value.arrayValue { return TOMLWriter.isArrayOfTables(items) }
		return false
	}

	static func trimTrailingNewlines(_ text: String) -> String {
		var out = text
		while out.hasSuffix("\n") || out.hasSuffix("\r") { out.removeLast() }
		return out
	}
}
