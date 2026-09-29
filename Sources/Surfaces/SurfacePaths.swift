//
//  SurfacePaths.swift
//  AgentKit
//
//  Every path template a surface mentions, so the file watcher and the
//  diagnostics pane can look at all of them without knowing each surface kind.
//

import Foundation

public enum SurfacePaths {
	/// Path templates declared by a surface, in declaration order.
	public static func candidatePaths(for surface: SurfaceSpec) -> [String] {
		var paths: [String] = []

		for value in [surface.file, surface.providerFile, surface.catalogFile, surface.authFile, surface.root] {
			if let value { paths.append(value) }
		}
		for root in surface.roots ?? [] {
			paths.append(root.path)
		}
		for layer in surface.layers ?? [] {
			paths.append(layer.path)
		}
		for legacy in surface.legacy ?? [] {
			paths.append(legacy.path)
		}
		for file in surface.files ?? [] {
			paths.append(file.path)
		}
		for (_, ref) in surface.defaults ?? [:] {
			paths.append(ref.file)
		}

		// Preserve order, drop duplicates.
		var seen = Set<String>()
		return paths.filter { seen.insert($0).inserted }
	}

	/// True when every occurrence of `$CWD` in this surface can be resolved,
	/// i.e. either a project is selected or the surface has no project paths.
	public static func requiresProject(_ surface: SurfaceSpec) -> Bool {
		projectPathCount(for: surface) > 0
	}

	/// How many declared paths point at the current project.
	public static func projectPathCount(for surface: SurfaceSpec) -> Int {
		candidatePaths(for: surface).filter { $0.contains("$CWD") }.count
	}

	/// Expands a surface's templates, skipping the ones that need a project
	/// directory when none is selected.
	public static func resolve(
		_ templates: [String],
		using resolver: PathResolver
	) -> [(template: String, url: URL)] {
		templates.compactMap { template in
			guard let url = try? resolver.expand(template) else { return nil }
			return (template, url)
		}
	}
}
