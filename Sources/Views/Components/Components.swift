//
//  Components.swift
//  AgentKit
//
//  Small shared views: path chips, badges, empty states.
//

import SwiftUI

struct PathChip: View {
	let path: String
	var secondary: String?
	var tint: Color = .secondary

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "doc.text")
				.font(.caption2)
			Text(path)
				.font(.system(.caption, design: .monospaced))
				.lineLimit(1)
				.truncationMode(.middle)
				.help(path)
			if let secondary {
				Text(secondary)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.foregroundStyle(tint)
		.padding(.horizontal, 8)
		.padding(.vertical, 3)
		.background(
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.fill(Color(nsColor: .quaternarySystemFill))
		)
	}
}

struct StatusBadge: View {
	enum Level {
		case ok
		case info
		case warning
		case error
		case muted

		var color: Color {
			switch self {
			case .ok: return .green
			case .info: return .accentColor
			case .warning: return .orange
			case .error: return .red
			case .muted: return .secondary
			}
		}
	}

	let text: String
	var level: Level = .muted
	var icon: String?

	var body: some View {
		HStack(spacing: 4) {
			if let icon {
				Image(systemName: icon).font(.caption2)
			}
			Text(text).font(.caption2.weight(.medium))
		}
		.foregroundStyle(level.color)
		.padding(.horizontal, 7)
		.padding(.vertical, 2)
		.background(
			Capsule().fill(level.color.opacity(0.13))
		)
	}
}

struct EmptyStateView: View {
	let icon: String
	let title: String
	var message: String?
	var action: (label: String, handler: () -> Void)?

	init(
		icon: String,
		title: String,
		message: String? = nil,
		action: (label: String, handler: () -> Void)? = nil
	) {
		self.icon = icon
		self.title = title
		self.message = message
		self.action = action
	}

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: icon)
				.font(.system(size: 34, weight: .light))
				.foregroundStyle(.tertiary)
			Text(title)
				.font(.headline)
			if let message {
				Text(message)
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.frame(maxWidth: 420)
			}
			if let action {
				Button(action.label, action: action.handler)
					.buttonStyle(.borderedProminent)
					.controlSize(.small)
					.padding(.top, 2)
			}
		}
		.padding(30)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

/// A labelled row used by the settings form.
struct FieldRow<Content: View>: View {
	let label: String
	let help: String
	var note: String?
	var isDefault: Bool
	var error: String?
	@ViewBuilder var content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(label)
					.font(.callout.weight(.medium))
				if isDefault {
					Text(L.t("badge.default", "默认"))
						.font(.caption2)
						.foregroundStyle(.tertiary)
						.padding(.horizontal, 5)
						.padding(.vertical, 1)
						.background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
				}
				Spacer(minLength: 12)
				content
					.frame(maxWidth: 320, alignment: .trailing)
			}
			if let note {
				Text(note)
					.font(.caption2)
					.foregroundStyle(.orange)
			}
			Text(help)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			if let error {
				Text(error)
					.font(.caption)
					.foregroundStyle(.red)
			}
		}
		.padding(.vertical, 5)
	}
}

struct InfoBanner: View {
	enum Kind {
		case info
		case warning
		case error

		var color: Color {
			switch self {
			case .info: return .accentColor
			case .warning: return .orange
			case .error: return .red
			}
		}

		var icon: String {
			switch self {
			case .info: return "info.circle.fill"
			case .warning: return "exclamationmark.triangle.fill"
			case .error: return "xmark.octagon.fill"
			}
		}
	}

	let kind: Kind
	let title: String
	var detail: String?
	var action: (label: String, handler: () -> Void)?

	init(
		kind: Kind,
		title: String,
		detail: String? = nil,
		action: (label: String, handler: () -> Void)? = nil
	) {
		self.kind = kind
		self.title = title
		self.detail = detail
		self.action = action
	}

	var body: some View {
		HStack(alignment: .top, spacing: 9) {
			Image(systemName: kind.icon)
				.foregroundStyle(kind.color)
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.callout.weight(.medium))
				if let detail {
					Text(detail)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
						.textSelection(.enabled)
				}
			}
			Spacer(minLength: 8)
			if let action {
				Button(action.label, action: action.handler)
					.controlSize(.small)
			}
		}
		.padding(10)
		.background(
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.fill(kind.color.opacity(0.09))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.stroke(kind.color.opacity(0.25), lineWidth: 1)
		)
	}
}


/// Tells the user when a surface's project-scoped paths are not being loaded.
///
/// Silently hiding them is the worst option: a project `.pi/mcp.json` that never
/// appears looks like a bug in the project, not a missing selection.
struct ProjectScopeBanner: View {
	let surface: SurfaceSpec

	@Environment(AppModel.self) private var model

	var body: some View {
		let count = SurfacePaths.projectPathCount(for: surface)
		if model.projectURL == nil, count > 0 {
			InfoBanner(
				kind: .info,
				title: String(
					format: L.t("banner.projectScope.title", "有 %d 条项目级路径没有加载"),
					count
				),
				detail: L.t(
					"banner.projectScope.detail",
					"这个面板会读取项目目录下的配置。当前是全局作用域，所以这些路径被跳过了。"
				),
				action: (L.t("button.chooseProject", "选择项目…"), { model.projects.chooseWithPanel() })
			)
		} else if let project = model.projectURL, count > 0 {
			HStack(spacing: 6) {
				Image(systemName: "folder")
					.font(.caption2)
				Text(String(format: L.t("banner.projectScope.current", "项目作用域：%@"), project.path))
					.font(.caption2)
					.lineLimit(1)
					.truncationMode(.middle)
				Button(L.t("button.backToGlobal", "回到全局")) { model.projects.select(nil) }
					.buttonStyle(.link)
					.controlSize(.mini)
			}
			.foregroundStyle(.secondary)
		}
	}
}
