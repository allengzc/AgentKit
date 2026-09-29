//
//  Watcher.swift
//  AgentKit
//
//  FSEvents wrapper used to notice when something else (pi, an editor, the
//  user's terminal) rewrote a config file, so the UI can refresh instead of
//  showing stale values.
//

import Foundation
import CoreServices

public final class DirectoryWatcher {
	private var streams: [FSEventStreamRef] = []
	private let queue: DispatchQueue
	private let latency: CFTimeInterval
	private let onChange: ([String]) -> Void
	private var pendingPaths = Set<String>()
	private var flushWorkItem: DispatchWorkItem?
	private let lock = NSLock()
	private var started = false

	/// - Parameters:
	///   - onChange: called on `queue` with the changed paths, coalesced.
	public init(
		queue: DispatchQueue = .main,
		latency: CFTimeInterval = 0.4,
		onChange: @escaping ([String]) -> Void
	) {
		self.queue = queue
		self.latency = latency
		self.onChange = onChange
	}

	deinit {
		stop()
	}

	public func start(paths: [URL]) {
		stop()
		// FSEvents reports changes under a root, so watch the nearest existing
		// ancestor of each path and let the callback filter.
		let roots = Set(paths.compactMap { DirectoryWatcher.nearestExistingAncestor(of: $0)?.path })
		for root in roots {
			var context = FSEventStreamContext(
				version: 0,
				info: Unmanaged.passUnretained(self).toOpaque(),
				retain: nil,
				release: nil,
				copyDescription: nil
			)
			let flags = UInt32(
				kFSEventStreamCreateFlagUseCFTypes
					| kFSEventStreamCreateFlagFileEvents
					| kFSEventStreamCreateFlagNoDefer
			)
			guard let stream = FSEventStreamCreate(
				kCFAllocatorDefault,
				{ _, info, count, eventPaths, _, _ in
					guard let info else { return }
					let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
					guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
					_ = count
					watcher.receive(paths)
				},
				&context,
				[root] as CFArray,
				FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
				latency,
				flags
			) else {
				Log.app.error("FSEventStreamCreate failed for \(root, privacy: .public)")
				continue
			}
			FSEventStreamSetDispatchQueue(stream, queue)
			if FSEventStreamStart(stream) {
				streams.append(stream)
			} else {
				FSEventStreamInvalidate(stream)
				FSEventStreamRelease(stream)
			}
		}
		started = !streams.isEmpty
		Log.app.debug("watching \(roots.count, privacy: .public) root(s)")
	}

	public func stop() {
		for stream in streams {
			FSEventStreamStop(stream)
			FSEventStreamInvalidate(stream)
			FSEventStreamRelease(stream)
		}
		streams.removeAll()
		lock.lock()
		flushWorkItem?.cancel()
		flushWorkItem = nil
		pendingPaths.removeAll()
		lock.unlock()
		started = false
	}

	public var isWatching: Bool { started }

	private func receive(_ paths: [String]) {
		lock.lock()
		pendingPaths.formUnion(paths)
		flushWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.flush() }
		flushWorkItem = work
		lock.unlock()
		queue.asyncAfter(deadline: .now() + 0.1, execute: work)
	}

	private func flush() {
		lock.lock()
		let paths = Array(pendingPaths)
		pendingPaths.removeAll()
		flushWorkItem = nil
		lock.unlock()
		guard !paths.isEmpty else { return }
		onChange(paths)
	}

	static func nearestExistingAncestor(of url: URL) -> URL? {
		var candidate = url
		let fileManager = FileManager.default
		var isDirectory: ObjCBool = false
		while true {
			if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
				return isDirectory.boolValue ? candidate : candidate.deletingLastPathComponent()
			}
			let parent = candidate.deletingLastPathComponent()
			if parent.path == candidate.path || parent.path.isEmpty { return nil }
			candidate = parent
		}
	}
}
