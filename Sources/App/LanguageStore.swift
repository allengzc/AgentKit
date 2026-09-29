//
//  LanguageStore.swift
//  AgentKit
//
//  Which language the interface is in, and where that choice is remembered.
//
//  `Localization` holds the language the lookups read; this type owns the
//  observable copy SwiftUI needs so that changing it re-creates the view tree.
//  The two are kept in step here rather than in the views.
//

import Foundation
import Observation

@MainActor
@Observable
public final class LanguageStore {
	private static let defaultsKey = "AgentKitLanguage"

	/// Observable on purpose: `AgentKitApp` puts this in the root view's `.id()`,
	/// so a change rebuilds the interface and every `L.t` call is re-evaluated.
	public private(set) var current: AppLanguage

	public init(defaults: UserDefaults = .standard) {
		let saved = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:))
		let resolved = saved ?? .systemDefault
		current = resolved
		Localization.shared.language = resolved
	}

	public func select(_ language: AppLanguage, defaults: UserDefaults = .standard) {
		guard language != current else { return }
		current = language
		Localization.shared.language = language
		defaults.set(language.rawValue, forKey: Self.defaultsKey)
	}
}
