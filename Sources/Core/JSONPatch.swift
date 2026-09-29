//
//  JSONPatch.swift
//  AgentKit
//
//  Turns "this tree became that tree" into the smallest possible edit to the
//  file on disk.
//
//  Re-serializing a whole config file to flip one boolean reindents and
//  reformats everything else, which buries the real change in the diff and
//  makes the tool feel destructive. When the edit is a set of leaf changes,
//  AgentKit instead splices the new literals into the original bytes, so lines
//  it did not touch are provably unchanged — including objects the user wrote
//  on a single line.
//
//  Structural edits (adding or removing a key, changing an array's length) fall
//  back to a full re-serialization in the file's detected style.
//

import Foundation

public enum JSONPatch {
	public struct Change: Equatable {
		public let path: [String]
		public let new: JSONValue
	}

	public enum Plan: Equatable {
		/// Nothing to do: the tree is identical.
		case unchanged
		/// `text` is the original file with only the changed literals replaced.
		case splice(String)
		/// The edit changed the file's shape; the whole tree is written out.
		case rewrite
	}

	/// Decides how to turn `original` into `updated`.
	public static func plan(
		original: JSONValue,
		updated: JSONValue,
		source: JSONSource?
	) -> Plan {
		guard original != updated else { return .unchanged }
		guard let source else { return .rewrite }

		var changes: [Change] = []
		var structural = false
		collect(from: original, to: updated, path: [], changes: &changes, structural: &structural)
		guard !structural, !changes.isEmpty else { return .rewrite }
		guard let text = splice(changes, in: source) else { return .rewrite }
		return .splice(text)
	}

	/// Renders the text a document should become.
	public static func render(
		_ updated: JSONValue,
		from document: JSONDocument
	) -> String {
		let original = document.editableValue
		switch plan(original: original, updated: updated, source: document.source) {
		case .unchanged:
			return document.rawText
		case .splice(let text):
			return text
		case .rewrite:
			return document.style.writer.serialize(updated)
		}
	}

	// MARK: - Change collection

	private static func collect(
		from old: JSONValue,
		to new: JSONValue,
		path: [String],
		changes: inout [Change],
		structural: inout Bool
	) {
		if old == new { return }
		if structural { return }

		switch (old, new) {
		case (.object(let oldObject), .object(let newObject)):
			// A key added, removed or reordered cannot be expressed as a splice.
			guard oldObject.keys == newObject.keys else {
				structural = true
				return
			}
			for key in newObject.keys {
				guard let oldChild = oldObject[key], let newChild = newObject[key] else {
					structural = true
					return
				}
				collect(from: oldChild, to: newChild, path: path + [key], changes: &changes, structural: &structural)
			}
		case (.array(let oldItems), .array(let newItems)):
			guard oldItems.count == newItems.count else {
				structural = true
				return
			}
			for index in newItems.indices {
				collect(
					from: oldItems[index],
					to: newItems[index],
					path: path + [String(index)],
					changes: &changes,
					structural: &structural
				)
			}
		default:
			switch new {
			case .object, .array:
				// A scalar became a container (or vice versa).
				structural = true
			default:
				changes.append(Change(path: path, new: new))
			}
		}
	}

	// MARK: - Splicing

	/// Replaces each changed literal inside the original bytes, from the end
	/// backwards so earlier offsets stay valid.
	static func splice(_ changes: [Change], in source: JSONSource) -> String? {
		var resolved: [(range: Range<Int>, literal: String)] = []
		for change in changes {
			guard let range = source.range(at: change.path) else { return nil }
			resolved.append((range, JSONWriter.compact.serialize(change.new)))
		}
		resolved.sort { $0.range.lowerBound > $1.range.lowerBound }

		var bytes = Array(source.text.utf8)
		for entry in resolved {
			guard entry.range.lowerBound >= 0, entry.range.upperBound <= bytes.count else { return nil }
			bytes.replaceSubrange(entry.range, with: Array(entry.literal.utf8))
		}
		return String(bytes: bytes, encoding: .utf8)
	}
}
