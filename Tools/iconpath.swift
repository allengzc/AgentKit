//
//  iconpath.swift
//  AgentKit
//
//  Prints the SVG path data for the macOS app-icon shape.
//
//  The squircle is not a rounded rectangle: macOS 11+ uses a continuous-curvature
//  corner, and the exact curve is the one `RoundedRectangle(style: .continuous)`
//  draws. Rather than hand-fitting Béziers that approximate it, this asks the
//  system for the real path and prints it, so the icon's silhouette matches
//  every other icon in the Dock.
//
//  Usage: iconpath [side] [radius] [offset]
//         defaults: 824 185.4 100   (Apple's grid: an 824 pt tile centred in a
//                                    1024 pt canvas, leaving room for the shadow)
//

import Foundation
import SwiftUI

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
let side = arguments.count > 0 ? arguments[0] : 824
let radius = arguments.count > 1 ? arguments[1] : 185.4
let offset = arguments.count > 2 ? arguments[2] : 100

let rect = CGRect(x: offset, y: offset, width: side, height: side)
let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)

func format(_ point: CGPoint) -> String {
	let x = (point.x * 100).rounded() / 100
	let y = (point.y * 100).rounded() / 100
	return "\(trim(x)) \(trim(y))"
}

func trim(_ value: Double) -> String {
	value == value.rounded() ? String(Int(value)) : String(value)
}

var out = ""
path.forEach { element in
	switch element {
	case .move(let point):
		out += "M\(format(point))"
	case .line(let point):
		out += "L\(format(point))"
	case .quadCurve(let point, let control):
		out += "Q\(format(control)) \(format(point))"
	case .curve(let point, let control1, let control2):
		out += "C\(format(control1)) \(format(control2)) \(format(point))"
	case .closeSubpath:
		out += "Z"
	}
}

print(out)
