//
//  AgentKitApp.swift
//  AgentKit
//

import SwiftUI
import AppKit

@main
struct AgentKitApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@State private var model = AppModel()

	var body: some Scene {
		Window("AgentKit", id: "main") {
			RootView()
				.environment(model)
				.frame(minWidth: 1000, minHeight: 620)
				// Re-creating the tree is what makes a language switch take effect:
				// every `L.t` is read while the body is built.
				.id(model.languages.current)
		}
		.defaultSize(width: 1120, height: 700)
		.commands {
			CommandGroup(after: .newItem) {
				Button(L.t("menu.reload", "重新载入描述文件与配置")) {
					model.reloadDescriptors()
				}
				.keyboardShortcut("r", modifiers: [.command])
			}
			CommandMenu(L.t("menu.language", "语言")) {
				Picker(L.t("menu.language", "语言"), selection: languageBinding) {
					ForEach(AppLanguage.allCases, id: \.self) { language in
						Text(language.nativeName).tag(language)
					}
				}
				.pickerStyle(.inline)
			}
			CommandGroup(replacing: .help) {
				Button(L.t("menu.about", "AgentKit 说明")) {
					if let url = URL(string: "https://github.com/allengzc/agentkit") {
						NSWorkspace.shared.open(url)
					}
				}
			}
		}
	}

	private var languageBinding: Binding<AppLanguage> {
		Binding(
			get: { model.languages.current },
			set: { model.languages.select($0) }
		)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		// A plain `swiftc`-built bundle does not get the activation treatment an
		// Xcode build does, so bring the window forward ourselves.
		NSApp.activate(ignoringOtherApps: true)
		if let appearance = DocumentationState.appearance() { NSApp.appearance = appearance }
		if let size = DocumentationState.windowSize(),
			let window = NSApp.windows.first(where: { $0.contentView != nil })
		{
			window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
		}
		Log.app.info("AgentKit launched")
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}
