//
//  DiffSheet.swift
//  AgentKit
//
//  Every write goes through this sheet first. Config files belong to other
//  tools; the user should see the exact lines that change before they do.
//

import SwiftUI

struct DiffSheet: View {
	let preview: FilePreview
	var title: String = "确认写入"
	var backup: URL?
	var errorText: String?
	var isWriting: Bool = false
	let onCancel: () -> Void
	let onConfirm: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider()
			if let errorText {
				InfoBanner(kind: .error, title: errorText)
					.padding(14)
			}
			diffBody
			Divider()
			footer
		}
		.frame(minWidth: 720, idealWidth: 820, minHeight: 420, idealHeight: 520)
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text(title)
					.font(.headline)
				Spacer()
				if preview.existed {
					StatusBadge(text: "已存在", level: .info)
				} else {
					StatusBadge(text: "新建文件", level: .ok)
				}
			}
			PathChip(path: preview.url.path)
			HStack(spacing: 10) {
				Text("+\(preview.diff.insertions)")
					.foregroundStyle(.green)
					.font(.system(.caption, design: .monospaced))
				Text("−\(preview.diff.removals)")
					.foregroundStyle(.red)
					.font(.system(.caption, design: .monospaced))
				Text("共 \(preview.diff.lines.count) 行差异")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			if let backup {
				Label("写入前会备份为 \(backup.lastPathComponent)", systemImage: "clock.arrow.circlepath")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			if preview.isLossy, let note = preview.lossyNote {
				InfoBanner(kind: .warning, title: "这次写入不是逐字节保留的", detail: note)
			}
		}
		.padding(14)
	}

	private var diffBody: some View {
		ScrollView([.vertical, .horizontal]) {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(Array(preview.diff.condensed().enumerated()), id: \.offset) { _, line in
					if let line {
						diffRow(line)
					} else {
						Text("⋯")
							.font(.system(.caption, design: .monospaced))
							.foregroundStyle(.tertiary)
							.padding(.vertical, 3)
							.padding(.horizontal, 10)
					}
				}
			}
			.padding(.vertical, 6)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.background(Color(nsColor: .textBackgroundColor))
	}

	private func diffRow(_ line: TextDiff.Line) -> some View {
		let sign: String
		let color: Color
		let background: Color
		switch line.kind {
		case .equal:
			sign = " "
			color = .secondary
			background = .clear
		case .insert:
			sign = "+"
			color = .green
			background = Color.green.opacity(0.10)
		case .remove:
			sign = "−"
			color = .red
			background = Color.red.opacity(0.10)
		}

		return HStack(alignment: .top, spacing: 0) {
			Text(line.oldNumber.map(String.init) ?? "")
				.frame(width: 38, alignment: .trailing)
				.foregroundStyle(.tertiary)
			Text(line.newNumber.map(String.init) ?? "")
				.frame(width: 38, alignment: .trailing)
				.foregroundStyle(.tertiary)
			Text(sign)
				.frame(width: 16)
				.foregroundStyle(color)
			Text(line.text.isEmpty ? " " : line.text)
				.foregroundStyle(line.kind == .equal ? Color.primary : color)
				.textSelection(.enabled)
			Spacer(minLength: 0)
		}
		.font(.system(size: 11.5, design: .monospaced))
		.padding(.horizontal, 10)
		.padding(.vertical, 0.5)
		.background(background)
	}

	private var footer: some View {
		HStack {
			Text(preview.url.deletingLastPathComponent().path)
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.lineLimit(1)
				.truncationMode(.middle)
			Spacer()
			Button("取消", action: onCancel)
				.keyboardShortcut(.cancelAction)
			Button(action: onConfirm) {
				if isWriting {
					ProgressView().controlSize(.small)
				} else {
					Text("写入")
				}
			}
			.buttonStyle(.borderedProminent)
			.keyboardShortcut(.defaultAction)
			.disabled(isWriting || preview.diff.isEmpty)
		}
		.padding(14)
	}
}
