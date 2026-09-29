//
//  MarkdownText.swift
//  AgentKit
//
//  The markdown the instruction and skill editors preview.
//
//  This is deliberately not a markdown implementation: it covers headings,
//  paragraphs, bullets, quotes, fenced code, `code spans` and **bold**, which is
//  what these files actually contain. It lives in Surfaces rather than in the
//  view because it is pure text handling, and because a crash here took the whole
//  app down with it — the previous implementation is preserved as a test case.
//

import Foundation
import SwiftUI

enum MarkdownText {
	enum Block {
		case heading(Int, String)
		case paragraph(String)
		case bullet(String, Int)
		case quote(String)
		case code(String)
	}

	/// Inline markup, in one left-to-right pass.
	///
	/// The previous implementation ran one regex pass per construct, each one
	/// converting a range from the *original* string into the *already mutated*
	/// attributed string. Those offsets go stale the moment an earlier pass
	/// changes the length, and `replaceSubrange` then traps:
	/// `` **see `some-cli` for details** `` — a code span nested inside bold — crashed the app on 预览.
	///
	/// Walking the string once and appending runs has no offsets to go stale, and
	/// nesting falls out of the recursion.
	static func inline(_ text: String) -> AttributedString {
		var out = AttributedString()
		var plain = ""
		var index = text.startIndex

		func flush() {
			guard !plain.isEmpty else { return }
			out.append(AttributedString(plain))
			plain.removeAll()
		}

		while index < text.endIndex {
			// `code`
			if text[index] == "`",
				let close = text[text.index(after: index)...].firstIndex(of: "`")
			{
				flush()
				var run = AttributedString(String(text[text.index(after: index)..<close]))
				run.font = .system(.body, design: .monospaced)
				out.append(run)
				index = text.index(after: close)
				continue
			}

			// **bold**, which may contain code spans and other inline markup
			if text[index...].hasPrefix("**"),
				let close = text.range(
					of: "**",
					range: text.index(index, offsetBy: 2)..<text.endIndex
				)
			{
				flush()
				var run = inline(String(text[text.index(index, offsetBy: 2)..<close.lowerBound]))
				// The recursion only ever sets `font` on code spans, which is a
				// different attribute, so this cannot clobber an inner construct.
				run.inlinePresentationIntent = .stronglyEmphasized
				out.append(run)
				index = close.upperBound
				continue
			}

			// An unclosed ` or ** is literal text.
			plain.append(text[index])
			index = text.index(after: index)
		}
		flush()
		return out
	}

	static func parse(_ text: String) -> [Block] {
		var blocks: [Block] = []
		var paragraph: [String] = []
		var codeLines: [String] = []
		var inCode = false

		func flushParagraph() {
			if !paragraph.isEmpty {
				blocks.append(.paragraph(paragraph.joined(separator: " ")))
				paragraph.removeAll()
			}
		}

		for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = String(rawLine)
			if line.hasPrefix("```") {
				if inCode {
					blocks.append(.code(codeLines.joined(separator: "\n")))
					codeLines.removeAll()
					inCode = false
				} else {
					flushParagraph()
					inCode = true
				}
				continue
			}
			if inCode {
				codeLines.append(line)
				continue
			}
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty {
				flushParagraph()
				continue
			}
			if let match = trimmed.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
				flushParagraph()
				let hashes = trimmed[match].filter { $0 == "#" }.count
				blocks.append(.heading(hashes, String(trimmed[match.upperBound...])))
				continue
			}
			let indent = line.prefix { $0 == " " || $0 == "\t" }.count / 2
			if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
				flushParagraph()
				blocks.append(.bullet(String(trimmed.dropFirst(2)), indent))
				continue
			}
			if trimmed.hasPrefix("> ") {
				flushParagraph()
				blocks.append(.quote(String(trimmed.dropFirst(2))))
				continue
			}
			if let match = trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
				flushParagraph()
				blocks.append(.bullet(String(trimmed[match.upperBound...]), indent))
				continue
			}
			paragraph.append(trimmed)
		}
		if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
		flushParagraph()
		return blocks
	}
}
