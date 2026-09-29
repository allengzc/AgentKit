//
//  MarkdownEditorView.swift
//  AgentKit
//
//  A reusable "edit one Markdown file, safely" view.
//
//  Used by the instructions pane (AGENTS.md, SYSTEM.md, …) and by the sub-agent
//  editor for the prompt body. It owns the same guarantees as every other write
//  path: refuse to touch what it cannot read, show the diff first, back up the
//  original, and refuse to clobber a file that changed underneath.
//

import SwiftUI

struct MarkdownEditorView: View {
	let url: URL
	let resolver: PathResolver
	let policy: BackupPolicy
	/// Called after a successful write so the parent can refresh its own view.
	var onWritten: (() -> Void)?
	/// Rendered above the editor, e.g. a frontmatter form.
	var header: AnyView?

	@State private var document: TextDocument?
	@State private var text = ""
	@State private var loadedText = ""
	@State private var pending: PendingTextWrite?
	@State private var status: String?
	@State private var errorText: String?
	@State private var showsPreview = DocumentationState.isOn("preview")
	@State private var token = UUID()

	private struct PendingTextWrite: Identifiable {
		let id = UUID()
		let preview: FilePreview
		let document: TextDocument
	}

	init(
		url: URL,
		resolver: PathResolver,
		policy: BackupPolicy,
		header: AnyView? = nil,
		onWritten: (() -> Void)? = nil
	) {
		self.url = url
		self.resolver = resolver
		self.policy = policy
		self.header = header
		self.onWritten = onWritten
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let header { header }

			if let document, !document.isReadable {
				InfoBanner(
					kind: .error,
					title: document.problemReason ?? L.t("error.fileUnreadable", "文件无法读取"),
					detail: url.path
				)
			} else {
				HStack(spacing: 8) {
					Text(url.path)
						.font(.system(.caption, design: .monospaced))
						.lineLimit(1)
						.truncationMode(.middle)
						.foregroundStyle(.secondary)
					if let document, !document.exists {
						StatusBadge(text: L.t("badge.missing", "不存在"), level: .muted)
					}
					if let document, document.isSymlink {
						StatusBadge(text: L.t("badge.symlink", "符号链接"), level: .warning)
					}
					Spacer()
					if hasChanges {
						StatusBadge(text: L.t("badge.unsavedChanges", "有未保存改动"), level: .warning)
					}
					Picker("", selection: $showsPreview) {
						Text(L.t("editor.mode.edit", "编辑")).tag(false)
						Text(L.t("editor.mode.preview", "预览")).tag(true)
					}
					.labelsHidden()
					.pickerStyle(.segmented)
					.frame(width: 140)
				}

				if showsPreview {
					ScrollView {
						MarkdownPreview(text: text)
							.padding(12)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
				} else {
					TextEditor(text: $text)
						.font(.system(size: 12.5, design: .monospaced))
						.overlay(
							RoundedRectangle(cornerRadius: 8)
								.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
						)
				}

				if let status {
					InfoBanner(kind: .info, title: status)
				}
				if let errorText {
					InfoBanner(kind: .error, title: errorText)
				}

				HStack(spacing: 8) {
					Text(String(format: L.t("editor.stats", "%d 字符 · %d 行"), text.count, lineCount))
						.font(.caption2)
						.foregroundStyle(.tertiary)
					Spacer()
					Button(L.t("button.revealInFinder", "在 Finder 中显示")) { ShellActions.reveal(url) }
						.controlSize(.small)
					Button(L.t("button.openInDefaultApp", "用默认应用打开")) { ShellActions.openExternally(url) }
						.controlSize(.small)
					Button(L.t("button.discardChanges", "放弃改动")) { text = loadedText; status = nil }
						.controlSize(.small)
						.disabled(!hasChanges)
					Button(L.t("button.save", "保存…")) { stage() }
						.buttonStyle(.borderedProminent)
						.controlSize(.small)
						.disabled(!hasChanges || document?.isReadable == false)
				}
			}
		}
		.task(id: token) { load() }
		.onChange(of: url) { _, _ in load() }
		.sheet(item: $pending) { write in
			DiffSheet(
				preview: write.preview,
				backup: write.preview.backupURL,
				onCancel: { pending = nil },
				onConfirm: { confirm(write) }
			)
		}
	}

	private var hasChanges: Bool { text != loadedText }

	private var lineCount: Int {
		text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
	}

	private func load() {
		let loaded = TextFile.load(url, policy: policy)
		document = loaded
		text = loaded.text
		loadedText = loaded.text
		status = nil
		errorText = nil
	}

	private func stage() {
		guard let document else { return }
		let preview = TextFile.preview(text, for: document, policy: policy)
		guard preview.hasChanges else {
			status = L.t("banner.noChanges", "没有需要写入的改动")
			return
		}
		pending = PendingTextWrite(preview: preview, document: document)
	}

	private func confirm(_ write: PendingTextWrite) {
		do {
			let result = try TextFile.write(text, document: write.document, scope: resolver, policy: policy)
			pending = nil
			load()
			status = result.backupURL.map {
				String(format: L.t("banner.writtenWithBackup", "已写入，备份 %@"), $0.lastPathComponent)
			} ?? L.t("banner.written", "已写入")
			errorText = nil
			onWritten?()
		} catch {
			pending = nil
			errorText = (error as? FileWriteError)?.description ?? error.localizedDescription
		}
	}
}

/// A deliberately small Markdown renderer.
///
/// AgentKit ships no third-party dependencies, and these files are prose written
/// for an agent rather than documents for publication, so headings, lists,
/// code fences, quotes, emphasis and links are enough.
struct MarkdownPreview: View {
	let text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(Array(MarkdownText.parse(text).enumerated()), id: \.offset) { _, block in
				block.view
			}
		}
	}

}

extension MarkdownText.Block {
		@ViewBuilder
		var view: some View {
			switch self {
			case .heading(let level, let text):
				Text(text)
					.font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
					.padding(.top, 6)
			case .paragraph(let text):
				Text(MarkdownText.inline(text))
					.font(.body)
					.fixedSize(horizontal: false, vertical: true)
			case .bullet(let text, let depth):
				HStack(alignment: .top, spacing: 6) {
					Text("•").foregroundStyle(.secondary)
					Text(MarkdownText.inline(text)).fixedSize(horizontal: false, vertical: true)
				}
				.padding(.leading, CGFloat(depth) * 14)
			case .quote(let text):
				HStack(alignment: .top, spacing: 8) {
					Rectangle().frame(width: 2).foregroundStyle(.tertiary)
					Text(MarkdownText.inline(text)).foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			case .code(let text):
				Text(text)
					.font(.system(size: 11.5, design: .monospaced))
					.textSelection(.enabled)
					.padding(8)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
			}
		}
}
