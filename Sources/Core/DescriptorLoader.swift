//
//  DescriptorLoader.swift
//  AgentKit
//
//  Loads agent descriptors from the app bundle and from the user's config
//  directory. A user descriptor with the same `id` replaces the built-in one
//  entirely, so upgrading AgentKit never silently reverts a hand-tuned
//  descriptor.
//

import Foundation

public enum DescriptorLoader {
	public struct Outcome {
		public var agents: [LoadedAgent] = []
		public var issues: [DescriptorIssue] = []
	}

	/// The directory user descriptors live in.
	public static func userDirectory(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		if let override = environment["AGENTKIT_CONFIG_DIR"], !override.isEmpty {
			return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
				.appendingPathComponent("agents", isDirectory: true)
		}
		return PathResolver.homeDirectory()
			.appendingPathComponent(".config/agentkit/agents", isDirectory: true)
	}

	public static func builtinDirectory() -> URL? {
		Bundle.main.resourceURL?.appendingPathComponent("Agents", isDirectory: true)
	}

	/// Reads every descriptor in `directory`, returning decoded values plus one
	/// issue per file that could not be used.
	static func readDescriptors(in directory: URL) -> (descriptors: [AgentDescriptor], issues: [DescriptorIssue], urls: [String: URL]) {
		var descriptors: [AgentDescriptor] = []
		var issues: [DescriptorIssue] = []
		var urls: [String: URL] = [:]

		let entries = (try? FileManager.default.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		)) ?? []
		let jsonFiles = entries
			.filter { $0.pathExtension.lowercased() == "json" }
			.sorted { $0.lastPathComponent < $1.lastPathComponent }

		for url in jsonFiles {
			do {
				let data = try Data(contentsOf: url)
				let decoder = JSONDecoder()
				let descriptor = try decoder.decode(AgentDescriptor.self, from: data)
				descriptors.append(descriptor)
				urls[descriptor.id] = url
			} catch let error as DecodingError {
				issues.append(DescriptorIssue(
					severity: .error,
					message: "描述文件 \(url.lastPathComponent) 无法解析",
					detail: DescriptorLoader.describe(error)
				))
			} catch {
				issues.append(DescriptorIssue(
					severity: .error,
					message: "描述文件 \(url.lastPathComponent) 读取失败",
					detail: error.localizedDescription
				))
			}
		}

		return (descriptors, issues, urls)
	}

	/// Loads built-in descriptors, overlays user descriptors by `id`, and
	/// resolves each agent's root directory.
	///
	/// `locateCLI` is off by default because resolving the binary spawns a login
	/// shell; the UI asks for it on the side once the window is up.
	public static func loadAll(
		builtinDirectory: URL? = DescriptorLoader.builtinDirectory(),
		userDirectory: URL = DescriptorLoader.userDirectory(),
		environment: [String: String] = ProcessInfo.processInfo.environment,
		appSupport: URL = PathResolver.defaultAppSupport,
		locateCLI: Bool = false
	) -> Outcome {
		var outcome = Outcome()

		var merged: [String: AgentDescriptor] = [:]
		var origins: [String: LoadedAgent.Origin] = [:]
		var urls: [String: URL] = [:]

		if let builtinDirectory {
			let builtin = readDescriptors(in: builtinDirectory)
			outcome.issues.append(contentsOf: builtin.issues)
			for descriptor in builtin.descriptors {
				merged[descriptor.id] = descriptor
				origins[descriptor.id] = .builtin
				urls[descriptor.id] = builtin.urls[descriptor.id]
			}
		}

		if FileManager.default.fileExists(atPath: userDirectory.path) {
			let user = readDescriptors(in: userDirectory)
			outcome.issues.append(contentsOf: user.issues)
			for descriptor in user.descriptors {
				if merged[descriptor.id] != nil {
					Log.descriptor.info("user descriptor \(descriptor.id, privacy: .public) replaces the built-in one")
				}
				merged[descriptor.id] = descriptor
				origins[descriptor.id] = .user
				urls[descriptor.id] = user.urls[descriptor.id]
			}
		}

		for (id, descriptor) in merged.sorted(by: { $0.key < $1.key }) {
			var issues = DescriptorValidator.validate(descriptor)

			// Resolve the root: environment override first, then the default.
			var rootURL: URL
			let overrideValue: String?
			if let envName = descriptor.root.env, let value = environment[envName], !value.isEmpty {
				overrideValue = value
			} else {
				overrideValue = nil
			}
			let rootTemplate = overrideValue ?? descriptor.root.default
			do {
				rootURL = try PathResolver(
					root: URL(fileURLWithPath: "/"),
					appSupport: appSupport
				).expand(rootTemplate)
			} catch {
				rootURL = URL(fileURLWithPath: (rootTemplate as NSString).expandingTildeInPath)
				issues.append(DescriptorIssue(
					severity: .warning,
					agentID: id,
					message: "无法解析根目录模板 \(rootTemplate)",
					detail: error.localizedDescription
				))
			}

			if overrideValue != nil {
				issues.append(DescriptorIssue(
					severity: .info,
					agentID: id,
					message: "根目录由环境变量 \(descriptor.root.env ?? "") 覆盖",
					detail: rootURL.path
				))
			}

			let exists = FileManager.default.fileExists(atPath: rootURL.path)
			if !exists {
				issues.append(DescriptorIssue(
					severity: .warning,
					agentID: id,
					message: "根目录不存在",
					detail: rootURL.path
				))
			}

			// Detected-install paths, e.g. `~/.pi` and `~/.pi-desktop`.
			if let detectPaths = descriptor.detect?.paths {
				let resolver = PathResolver(root: rootURL, appSupport: appSupport)
				let found = detectPaths.compactMap { try? resolver.expand($0) }
					.filter { FileManager.default.fileExists(atPath: $0.path) }
				if found.isEmpty && !exists {
					issues.append(DescriptorIssue(
						severity: .warning,
						agentID: id,
						message: "在本机没有检测到 \(descriptor.name)",
						detail: "已检查：" + detectPaths.joined(separator: "、")
					))
				}
			}

			var agent = LoadedAgent(
				descriptor: descriptor,
				rootURL: rootURL,
				rootExists: exists,
				cliURL: nil,
				cliVersion: nil,
				issues: issues,
				descriptorURL: urls[id],
				origin: origins[id] ?? .builtin
			)

			if locateCLI, let spec = descriptor.detect?.cli {
				let resolver = PathResolver(root: rootURL, appSupport: appSupport)
				if let url = CLILocator.locate(spec: spec, resolver: resolver) {
					agent.cliURL = url
					agent.cliVersion = CLILocator.version(of: url, arguments: spec.versionArgs)
				} else {
					agent.issues.append(DescriptorIssue(
						severity: .warning,
						agentID: id,
						message: "找不到 \(spec.name) 可执行文件",
						detail: "已尝试：(PATH) " + (spec.candidates ?? []).joined(separator: "、")
					))
				}
			}

			outcome.agents.append(agent)
		}

		Log.descriptor.info("loaded \(outcome.agents.count, privacy: .public) descriptor(s), \(outcome.issues.count, privacy: .public) issue(s)")
		return outcome
	}

	/// Turns a `DecodingError` into something a human can act on.
	public static func describe(_ error: DecodingError) -> String {
		switch error {
		case .keyNotFound(let key, let context):
			let path = context.codingPath.map(\.stringValue).joined(separator: ".")
			return "缺少字段 \(path.isEmpty ? key.stringValue : path + "." + key.stringValue)"
		case .typeMismatch(let type, let context):
			let path = context.codingPath.map(\.stringValue).joined(separator: ".")
			return "字段 \(path.isEmpty ? "(根)" : path) 的类型不是 \(type)"
		case .valueNotFound(let type, let context):
			let path = context.codingPath.map(\.stringValue).joined(separator: ".")
			return "字段 \(path.isEmpty ? "(根)" : path) 缺少 \(type) 值"
		case .dataCorrupted(let context):
			let path = context.codingPath.map(\.stringValue).joined(separator: ".")
			return "字段 \(path.isEmpty ? "(根)" : path) 损坏：\(context.debugDescription)"
		@unknown default:
			return error.localizedDescription
		}
	}

	/// A resolver for one agent, with `$CWD` bound to the selected project.
	public static func resolver(
		for agent: LoadedAgent,
		project: URL? = nil,
		appSupport: URL = PathResolver.defaultAppSupport
	) -> PathResolver {
		var guardPaths: [URL] = [agent.rootURL, PathResolver.homeDirectory()]
		if let templates = agent.descriptor.write?.scopeGuard {
			let base = PathResolver(root: agent.rootURL, appSupport: appSupport, cwd: project)
			for template in templates {
				if let url = try? base.expand(template) { guardPaths.append(url) }
			}
		}
		guardPaths.append(URL(fileURLWithPath: "/tmp"))
		guardPaths.append(appSupport)

		return PathResolver(
			root: agent.rootURL,
			appSupport: appSupport,
			cwd: project,
			scopeGuard: guardPaths
		)
	}
}
