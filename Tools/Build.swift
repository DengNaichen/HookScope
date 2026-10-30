#!/usr/bin/env swift
import Foundation
import AppKit

let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
@discardableResult func run(_ path: String,_ arguments: [String],capture: Bool = false) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    if capture { process.standardOutput = output }
    try process.run()
    let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain:"Build",code:Int(process.terminationStatus),userInfo:[NSLocalizedDescriptionKey:"\(path) failed"]) }
    return String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
}

func createIcon() throws {
    let resources = root.appendingPathComponent("Resources")
    let iconset = root.appendingPathComponent(".build/HookScope.iconset")
    try fm.createDirectory(at:resources,withIntermediateDirectories:true)
    try fm.createDirectory(at:iconset,withIntermediateDirectories:true)
    for size in [16,32,128,256,512] {
        for scale in [1,2] {
            let pixels = size*scale
            let image = NSImage(size:NSSize(width:pixels,height:pixels))
            image.lockFocus()
            let context = NSGraphicsContext.current!.cgContext
            context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
            let rect = NSRect(x:76,y:76,width:872,height:872)
            let path = NSBezierPath(roundedRect:rect,xRadius:198,yRadius:198)
            NSColor(calibratedRed:0.12,green:0.30,blue:0.53,alpha:1).setFill(); path.fill()
            NSGradient(starting:NSColor(calibratedRed:0.25,green:0.57,blue:0.81,alpha:1),ending:NSColor(calibratedRed:0.08,green:0.23,blue:0.44,alpha:1))!.draw(in:path,angle:-90)
            NSColor.white.withAlphaComponent(0.24).setStroke()
            let ring = NSBezierPath(ovalIn:NSRect(x:248,y:248,width:528,height:528)); ring.lineWidth = 42; ring.stroke()
            let trace = NSBezierPath()
            trace.move(to:NSPoint(x:246,y:476)); trace.line(to:NSPoint(x:386,y:476)); trace.line(to:NSPoint(x:454,y:652)); trace.line(to:NSPoint(x:559,y:365)); trace.line(to:NSPoint(x:629,y:520)); trace.line(to:NSPoint(x:780,y:520))
            trace.lineWidth = 46; trace.lineCapStyle = .round; trace.lineJoinStyle = .round
            NSColor.white.setStroke(); trace.stroke()
            image.unlockFocus()
            let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
            let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
            try bitmap.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent(name))
        }
    }
    try run("/usr/bin/iconutil",["-c","icns",iconset.path,"-o",resources.appendingPathComponent("AppIcon.icns").path])
}

do {
    try createIcon()
    if CommandLine.arguments.contains("--icon-only") { exit(0) }
    try run("/usr/bin/xcrun",["swift","build","-c","release"])
    let bin = try run("/usr/bin/xcrun",["swift","build","-c","release","--show-bin-path"],capture:true)
    let output = root.appendingPathComponent("build")
    let stage = output.appendingPathComponent(".HookScope-\(UUID().uuidString).app")
    let app = output.appendingPathComponent("HookScope.app")
    let contents = stage.appendingPathComponent("Contents")
    for folder in ["MacOS","Helpers","Resources"] { try fm.createDirectory(at:contents.appendingPathComponent(folder),withIntermediateDirectories:true) }
    try fm.copyItem(at:URL(fileURLWithPath:bin).appendingPathComponent("HookScope"),to:contents.appendingPathComponent("MacOS/HookScope"))
    try fm.copyItem(at:URL(fileURLWithPath:bin).appendingPathComponent("hook-recorder"),to:contents.appendingPathComponent("Helpers/hook-recorder"))
    try fm.copyItem(at:root.appendingPathComponent("Resources/AppIcon.icns"),to:contents.appendingPathComponent("Resources/AppIcon.icns"))
    let info: [String:Any] = [
        "CFBundleIdentifier":"local.hookscope.mac", "CFBundleName":"HookScope", "CFBundleDisplayName":"HookScope",
        "CFBundleExecutable":"HookScope", "CFBundlePackageType":"APPL", "CFBundleVersion":"1",
        "CFBundleShortVersionString":"1.0.0", "CFBundleIconFile":"AppIcon", "LSMinimumSystemVersion":"14.0",
        "NSPrincipalClass":"NSApplication", "NSHighResolutionCapable":true,
        "NSHumanReadableCopyright":"HookScope · Local hook observability"
    ]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
    try run("/usr/bin/codesign",["--force","--sign","-","--options","runtime",contents.appendingPathComponent("Helpers/hook-recorder").path])
    try run("/usr/bin/codesign",["--force","--sign","-","--options","runtime",stage.path])
    if fm.fileExists(atPath:app.path) { try fm.removeItem(at:app) }
    try fm.moveItem(at:stage,to:app)
    try run("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
    print("Built: \(app.path)")
    if CommandLine.arguments.contains("--open") { try run("/usr/bin/open",[app.path]) }
} catch {
    fputs(error.localizedDescription+"\n",stderr)
    exit(1)
}
