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
				// Formatters (dates, numbers) follow this, not the system locale —
				// otherwise English mode still shows "9月30日".
				.environment(\.locale, Locale(identifier: model.languages.current.rawValue))
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
		//
		// Unless the launch is automated. Verification and screenshot runs start
		// this app dozens of times, and activating each time pulls focus — and
		// sometimes the pointer — away from whatever the user is doing. The window
		// still appears and is still capturable; it just does not become the
		// active application. `AGENTKIT_NO_ACTIVATE=1` is the switch, and
		// Tools/make-screenshots.sh sets it.
		if DocumentationState.shouldActivateOnLaunch {
			NSApp.activate(ignoringOtherApps: true)
		} else {
			// Skipping our own activation is not enough: macOS activates a GUI
			// process started straight from a shell anyway. An accessory process is
			// not a candidate for activation at all, so the window appears and stays
			// capturable without the menu bar — or the user's focus — being taken.
			NSApp.setActivationPolicy(.accessory)
		}
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
