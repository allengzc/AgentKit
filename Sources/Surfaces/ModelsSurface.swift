//
//  ModelsSurface.swift
//  AgentKit
//
//  `models.json`: compatible endpoints, their models, and the startup defaults
//  stored in `settings.json`.
//
//  `models-store.json` is pi's own catalog cache. It is read for extra detail
//  (cost, capabilities) and never written.
//

import Foundation

public struct ModelEntry: Identifiable {
	public var id: String
	public var name: String?
	public var reasoning: Bool?
	public var inputs: [String]
	public var contextWindow: Int?
	public var maxTokens: Int?
	public var api: String?
	public var baseUrl: String?
	public var raw: JSONValue

	public var supportsImages: Bool { inputs.contains("image") }
}

public struct ProviderEntry: Identifiable {
	public var id: String
	public var name: String?
	public var baseUrl: String?
	public var api: String?
	public var hasKey: Bool
	public var keyIsEnvReference: Bool
	public var compatKeys: [String]
	public var models: [ModelEntry]
	public var raw: JSONValue
	public var unknownKeys: [String]
}

public struct ModelsSnapshot {
	/// The map holding providers. pi uses `providers`, Codex `model_providers`.
	public var providersKey: String = "providers"
	public var keys: ModelProviderKeys = .pi
	public var providers: [ProviderEntry] = []
	public var overrides: [String] = []
	public var defaults: (provider: String?, model: String?, thinking: String?) = (nil, nil, nil)
	public var catalog: [String: ModelEntry] = [:]
	public var malformedReason: String?
}

public enum ModelsSurfaceLoader {
	public static func snapshot(
		surface: SurfaceSpec,
		resolver: PathResolver,
		policy: BackupPolicy
	) -> ModelsSnapshot {
		var snapshot = ModelsSnapshot()
		snapshot.providersKey = surface.providersKey ?? "providers"
		let keys = surface.providerKeys ?? .pi
		snapshot.keys = keys

		if let template = surface.providerFile, let url = try? resolver.expand(template) {
			let document = JSONFile.load(
				url,
				policy: policy,
				format: surface.format.flatMap(ConfigFormat.init(rawValue:))
			)
			snapshot.malformedReason = document.malformedReason
			if let providers = document.value(at: [snapshot.providersKey])?.objectValue {
				for key in providers.keys {
					guard let value = providers[key], let object = value.objectValue else { continue }
					let modelsKey = keys.models ?? "models"
					var models: [ModelEntry] = []
					for model in object[modelsKey]?.arrayValue ?? [] {
						guard let modelObject = model.objectValue,
							let id = modelObject["id"]?.stringValue
						else { continue }
						models.append(
							ModelEntry(
								id: id,
								name: modelObject["name"]?.stringValue,
								reasoning: modelObject["reasoning"]?.boolValue,
								inputs: modelObject["input"]?.stringsValue ?? [],
								contextWindow: modelObject["contextWindow"]?.intValue,
								maxTokens: modelObject["maxTokens"]?.intValue,
								api: modelObject["api"]?.stringValue,
								baseUrl: modelObject["baseUrl"]?.stringValue,
								raw: model
							)
						)
					}
					let apiKey = keys.apiKey.flatMap { object[$0]?.stringValue }
					let known = [keys.name, keys.baseUrl, keys.api, keys.apiKey, modelsKey, "compat", "headers"]
						.compactMap { $0 }
					snapshot.providers.append(
						ProviderEntry(
							id: key,
							name: keys.name.flatMap { object[$0]?.stringValue },
							baseUrl: keys.baseUrl.flatMap { object[$0]?.stringValue },
							api: keys.api.flatMap { object[$0]?.stringValue },
							hasKey: apiKey?.isEmpty == false,
							keyIsEnvReference: apiKey?.hasPrefix("$") == true || apiKey?.hasPrefix("!") == true,
							compatKeys: object["compat"]?.objectValue?.keys ?? [],
							models: models,
							raw: value,
							unknownKeys: object.keys.filter { !known.contains($0) }
						)
					)
				}
			}
			snapshot.overrides = document.value(at: ["modelOverrides"])?.objectValue?.keys ?? []
		}

		for (role, ref) in surface.defaults ?? [:] {
			guard let url = try? resolver.expand(ref.file) else { continue }
			let document = JSONFile.load(url, policy: policy)
			let value = document.value(at: ref.path.split(separator: ".").map(String.init))?.stringValue
			switch role {
			case "provider": snapshot.defaults.provider = value
			case "model": snapshot.defaults.model = value
			case "thinking": snapshot.defaults.thinking = value
			default: break
			}
		}

		if let template = surface.catalogFile, let url = try? resolver.expand(template) {
			let document = JSONFile.load(url, policy: policy)
			if let root = document.value?.objectValue {
				for providerKey in root.keys {
					for model in root[providerKey]?.objectValue?["models"]?.arrayValue ?? [] {
						guard let object = model.objectValue, let id = object["id"]?.stringValue else { continue }
						snapshot.catalog["\(providerKey)/\(id)"] = ModelEntry(
							id: id,
							name: object["name"]?.stringValue,
							reasoning: object["reasoning"]?.boolValue,
							inputs: object["input"]?.stringsValue ?? [],
							contextWindow: object["contextWindow"]?.intValue,
							maxTokens: object["maxTokens"]?.intValue,
							api: object["api"]?.stringValue,
							baseUrl: object["baseUrl"]?.stringValue,
							raw: model
						)
					}
				}
			}
		}

		return snapshot
	}

	/// `provider/modelId` for every configured model, for pickers elsewhere.
	public static func modelIdentifiers(
		surface: SurfaceSpec,
		resolver: PathResolver,
		policy: BackupPolicy
	) -> [String] {
		snapshot(surface: surface, resolver: resolver, policy: policy)
			.providers
			.flatMap { provider in provider.models.map { "\(provider.id)/\($0.id)" } }
			.sorted()
	}

	/// The documented `api` values, plus free text (the field is an open string).
	public static let knownAPIs = [
		"openai-completions",
		"openai-responses",
		"anthropic-messages",
		"mistral-conversations",
		"google-generative-ai",
		"bedrock-converse-stream",
		"pi-messages",
	]

	public static func emptyProvider() -> JSONValue {
		.object(JSONObject([
			("name", .string("")),
			("baseUrl", .string("")),
			("api", .string("openai-completions")),
			("apiKey", .string("")),
			("models", .array([])),
		]))
	}

	public static func emptyModel() -> JSONValue {
		.object(JSONObject([
			("id", .string("")),
			("name", .string("")),
			("reasoning", .bool(false)),
			("input", .array([.string("text")])),
			("contextWindow", .number(JSONNumber(128000))),
			("maxTokens", .number(JSONNumber(16384))),
		]))
	}
}
