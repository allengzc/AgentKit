//
//  Log.swift
//  AgentKit
//
//  `NSLog` redacts interpolated values as <private> in release builds, which
//  makes a GUI app impossible to debug from the terminal. `os.Logger` with
//  explicit `.public` privacy is visible in `log show` and is what AgentKit
//  uses everywhere.
//

import Foundation
import os

public enum Log {
	public static let subsystem = "com.allengzc.agentkit"

	public static let app = Logger(subsystem: subsystem, category: "app")
	public static let descriptor = Logger(subsystem: subsystem, category: "descriptor")
	public static let files = Logger(subsystem: subsystem, category: "files")
	public static let process = Logger(subsystem: subsystem, category: "process")
	public static let surfaces = Logger(subsystem: subsystem, category: "surfaces")
}
