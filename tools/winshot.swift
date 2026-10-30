// screenshots each on-screen window of a process: swift winshot.swift <pid> <outdir>
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let id = w[kCGWindowNumber as String] as! Int
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(id)", "\(out)/win-\(id)-L\(layer).png"]
    try? p.run(); p.waitUntilExit()
    print("\(out)/win-\(id)-L\(layer).png", w[kCGWindowName as String] ?? "")
}
