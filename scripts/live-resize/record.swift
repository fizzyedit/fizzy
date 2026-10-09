// Drags an edge of a fizzy window with real mouse events while recording the screen around it at
// 120 fps (ScreenCaptureKit), and decodes, in every captured frame, the overlay fizzy draws with
// FIZZY_LIVE_RESIZE_TRACE (`live_resize_trace` in backend/src/SDLBackend.zig). One line per
// screen update on stdout:
//   <display time, CACurrentMediaTime's clock> <n> drawn=<frame> <W>x<H> pitch=<p> shown=<W>x<H>
// "drawn" is the size the frame was drawn for (its barcode); "shown" the size the window shows it
// at (its edge bars). See docs/MACOS_LIVE_RESIZE.md and run.sh beside this file.
//
// usage: record <pid> <edge r|l|t|b|tr> <amp-pt> <period-s> <cycles> <events-hz> [png-dir] [png-every]
//        record quit <pid>
// The drag goes back and forth by <amp> points along a raised cosine, <cycles> times. Posting the
// events needs Accessibility for the app running this, and recording needs Screen Recording.
import AppKit
import CoreMedia
import ScreenCaptureKit

let args = CommandLine.arguments
if args.count == 3 && args[1] == "quit" {
    // fizzy ignores SIGTERM; ask it the way the Dock does.
    NSRunningApplication(processIdentifier: pid_t(args[2])!)?.terminate()
    exit(0)
}
let pid = pid_t(args[1])!
let edge = args[2]
let amp = CGFloat(Double(args[3])!)
let period = Double(args[4])!
let cycles = Double(args[5])!
let hz = Double(args[6])!
let pngDir: String? = args.count > 7 ? args[7] : nil
let pngEvery = args.count > 8 ? Int(args[8])! : 1
let growRight: CGFloat = (edge == "r" || edge == "tr") ? amp : 0
let growUp: CGFloat = (edge == "t" || edge == "tr") ? amp : 0
let growLeft: CGFloat = edge == "l" ? amp : 0
let growDown: CGFloat = edge == "b" ? amp : 0

/// The app whose window is topmost at `p` (global top-left points): the drag's events go wherever
/// the pointer is, so they must only be posted while that is fizzy.
func ownerOfTopWindow(at p: CGPoint) -> pid_t? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
        else { continue }
        // a resize press lands a point or two outside the window's frame
        if CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -4, dy: -4).contains(p) {
            return w[kCGWindowOwnerPID as String] as? pid_t
        }
    }
    return nil
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("record: \(message)\n".data(using: .utf8)!)
    exit(2)
}

let source = CGEventSource(stateID: .hidSystemState)
func postMouse(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.post(tap: .cghidEventTap)
}
func drag(_ f: CGRect) {
    // global top-left coordinates, points
    let start: CGPoint
    var dir = CGVector(dx: 0, dy: 0)
    switch edge {
    case "r": start = CGPoint(x: f.maxX + 1, y: f.midY); dir = CGVector(dx: 1, dy: 0)
    case "l": start = CGPoint(x: f.minX - 2, y: f.midY); dir = CGVector(dx: -1, dy: 0)
    case "t": start = CGPoint(x: f.midX, y: f.minY - 1); dir = CGVector(dx: 0, dy: -1)
    case "b": start = CGPoint(x: f.midX, y: f.maxY + 1); dir = CGVector(dx: 0, dy: 1)
    case "tr": start = CGPoint(x: f.maxX + 1, y: f.minY - 1); dir = CGVector(dx: 1, dy: -1)
    default: return
    }
    // Bring fizzy forward and press only on its own window: posted events go to whatever is under
    // the pointer, and another app's window over fizzy's edge would take the drag.
    NSRunningApplication(processIdentifier: pid)?.activate()
    usleep(400_000)
    guard ownerOfTopWindow(at: start) == pid else {
        fail("fizzy's window is not the topmost one at \(start); bring it to the front (nothing was posted)")
    }
    postMouse(.mouseMoved, start)
    usleep(150_000)
    postMouse(.leftMouseDown, start)
    let t0 = CACurrentMediaTime()
    FileHandle.standardError.write(String(format: "drag start %.6f at %@\n", t0, NSStringFromPoint(start)).data(using: .utf8)!)
    let total = period * cycles
    var k = 1.0
    while true {
        let target = t0 + k / hz
        let now = CACurrentMediaTime()
        if target > now { usleep(useconds_t((target - now) * 1e6)) }
        let t = CACurrentMediaTime() - t0
        if t >= total { break }
        let s = amp * 0.5 * (1 - cos(2 * .pi * t / period))
        let p = CGPoint(x: start.x + dir.dx * s, y: start.y + dir.dy * s)
        // Stop the moment anything else comes over the pointer.
        if Int(k) % 15 == 0, ownerOfTopWindow(at: p) != pid {
            postMouse(.leftMouseUp, p)
            fail("another window came over fizzy's during the drag; released the button and stopped")
        }
        postMouse(.leftMouseDragged, p)
        k += 1
    }
    postMouse(.leftMouseUp, start)
    FileHandle.standardError.write(String(format: "drag end %.6f\n", CACurrentMediaTime()).data(using: .utf8)!)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func machSeconds(_ t: UInt64) -> Double {
    Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

struct Px { var r: Int; var g: Int; var b: Int }

final class Out: NSObject, SCStreamOutput {
    var n = 0
    var lines: [String] = []
    let pngQueue = DispatchQueue(label: "png")

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb)
        else { return }
        let display = (info[.displayTime] as? UInt64).map(machSeconds) ?? -1
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int) -> Px {
            if x < 0 || y < 0 || x >= w || y >= h { return Px(r: -1, g: -1, b: -1) }
            let p = base + y * bpr + x * 4
            return Px(r: Int(p[2]), g: Int(p[1]), b: Int(p[0]))
        }
        func isRed(_ p: Px) -> Bool { p.r > 180 && p.g < 80 && p.b < 80 }
        func isCyan(_ p: Px) -> Bool { p.r < 80 && p.g > 180 && p.b > 180 }
        func isMagenta(_ p: Px) -> Bool { p.r > 180 && p.g < 80 && p.b > 180 }
        func isYellow(_ p: Px) -> Bool { p.r > 180 && p.g > 180 && p.b < 80 }

        // The cyan bar: leftmost column with a cyan run, scanning the middle rows.
        var line = String(format: "%.6f", display)
        var cyanX = -1, rowY = -1
        outer: for y in stride(from: h / 3, to: 2 * h / 3, by: 7) {
            for x in 0..<w where isCyan(px(x, y)) {
                cyanX = x; rowY = y; break outer
            }
        }
        // The barcode: its first red block, right of the cyan bar, searched by rows.
        var decoded = "?"
        if cyanX >= 0 {
            var cyanTop = rowY
            while cyanTop > 0 && isCyan(px(cyanX + 2, cyanTop - 1)) { cyanTop -= 1 }
            var redTop = -1, redBottom = -1
            var y = cyanTop
            while y < h {
                if isRed(px(cyanX + 28, y)) {
                    var b = y
                    while b + 1 < h && isRed(px(cyanX + 28, b + 1)) { b += 1 }
                    if b - y >= 10 { redTop = y; redBottom = b; break }
                    y = b + 1
                } else { y += 1 }
            }
            if redTop >= 0 {
                let by = (redTop + redBottom) / 2
                var rx0 = cyanX + 28
                while rx0 > 0 && isRed(px(rx0 - 1, by)) { rx0 -= 1 }
                var rx1 = rx0
                while rx1 + 1 < w && isRed(px(rx1 + 1, by)) { rx1 += 1 }
                // the end red block: next red run after the data
                var ex = rx1 + 1
                while ex < w && !isRed(px(ex, by)) { ex += 1 }
                if ex < w {
                    let pitch = Double(ex - rx0) / 49.0
                    var bits: [Int] = []
                    for i in 1...48 {
                        let cx = Int(Double(rx0) + pitch * (Double(i) + 0.5))
                        let p = px(cx, by)
                        bits.append((p.r + p.g + p.b) > 384 ? 1 : 0)
                    }
                    func field(_ k: Int) -> Int { bits[(k * 16)..<(k * 16 + 16)].reduce(0) { $0 * 2 + $1 } }
                    decoded = "\(field(0)) \(field(1))x\(field(2)) pitch=\(String(format: "%.3f", pitch))"
                }
            }
        }
        // Shown size: cyan..magenta along rowY; yellow top..bottom along a column 300px in.
        var shownW = -1, shownH = -1
        if cyanX >= 0 {
            var mx = w - 1
            while mx > cyanX && !isMagenta(px(mx, rowY)) { mx -= 1 }
            if mx > cyanX { shownW = mx - cyanX + 1 }
            let col = cyanX + 300
            var yt = 0
            while yt < h && !isYellow(px(col, yt)) { yt += 1 }
            var yb = h - 1
            while yb > yt && !isYellow(px(col, yb)) { yb -= 1 }
            if yt < h && yb > yt { shownH = yb - yt + 1 }
        }
        line += " \(n) drawn=\(decoded) shown=\(shownW)x\(shownH)"
        lines.append(line)

        if let dir = pngDir, n % pngEvery == 0, let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            let ci = CIImage(ioSurface: surface)
            let ctx = CIContext()
            if let cg = ctx.createCGImage(ci, from: ci.extent) {
                let idx = n
                pngQueue.async {
                    let url = URL(fileURLWithPath: "\(dir)/f\(String(format: "%05d", idx)).png")
                    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cg, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }
            }
        }
        n += 1
    }
}

let out = Out()
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var found: SCWindow? = nil
        for _ in 0..<40 {
            found = content.windows.first { $0.owningApplication?.processID == pid && $0.frame.width > 400 && $0.frame.height > 300 }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard found != nil else { print("no window for pid \(pid)"); exit(1) }
        // Its first frame can come before the app has placed it: look again once it has settled.
        try await Task.sleep(nanoseconds: 500_000_000)
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let win = content.windows.first(where: { $0.windowID == found!.windowID }) else { print("window gone"); exit(1) }
        guard let display = content.displays.first(where: { $0.frame.intersects(win.frame) }) else { print("no display for window \(win.frame) title \(win.title ?? "") displays \(content.displays.map { $0.frame })"); exit(1) }
        let scale = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID })?.backingScaleFactor ?? 2
        let f = win.frame // global, top-left origin, points
        var rect = CGRect(x: f.minX - display.frame.minX - 10 - growLeft, y: f.minY - display.frame.minY - 10 - growUp,
                          width: f.width + 20 + growRight + growLeft, height: f.height + 20 + growUp + growDown)
        rect = rect.intersection(CGRect(origin: .zero, size: display.frame.size))
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await stream.startCapture()
        FileHandle.standardError.write("recording \(rect) scale \(scale) window \(f)\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 500_000_000)
        let th = Thread { drag(f) }
        th.qualityOfService = .userInteractive
        th.start()
        try await Task.sleep(nanoseconds: UInt64((period * cycles + 0.2 + 0.6) * 1e9))
        try await stream.stopCapture()
        out.pngQueue.sync {}
        for l in out.lines { print(l) }
    } catch {
        print("error: \(error)")
    }
    sem.signal()
}
sem.wait()
