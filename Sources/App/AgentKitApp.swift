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
		}
		.defaultSize(width: 1120, height: 700)
		.commands {
			CommandGroup(after: .newItem) {
				Button("重新载入描述文件与配置") {
					model.reloadDescriptors()
				}
				.keyboardShortcut("r", modifiers: [.command])
			}
			CommandGroup(replacing: .help) {
				Button("AgentKit 说明") {
					if let url = URL(string: "https://github.com/allengzc/agentkit") {
						NSWorkspace.shared.open(url)
					}
				}
			}
		}
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
		if let path = DocumentationState.string("snapshot"), path != "1" {
			DispatchQueue.main.asyncAfter(deadline: .now() + DocumentationState.snapshotDelay) {
				DocumentationState.writeSnapshot(to: path)
				NSApp.terminate(nil)
			}
		}
		Log.app.info("AgentKit launched")
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		true
	}
}
