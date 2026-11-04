// gui-io — the Mac's screen as a file, and its mouse and keyboard through a file, for any process on
// the Mac, plain SSH included. GuiIO.app runs as a LaunchAgent in the console user's session and holds
// Screen Recording and Accessibility itself, as its own responsible app, so the processes that use it
// need neither grant (over SSH they have none: their responsible app is sshd-keygen-wrapper).
//
// ~/.local/state/gui-io/ (mode 700, every file 600: screens show chats and banks):
//   screen.jpg                   a named pipe: reading it returns display 1's screen as it is now
//                                (display 1 is the main display, the one with the menu bar)
//   screen.json                  the image last read from screen.jpg: seq, time, size, origin, scale, cursor
//   screen-2.jpg, screen-2.json  display 2, and so on
//   in                           FIFO: one command per line, an optional leading id
//   out                          one ack line per command: "<id> ok display=D ..." or "<id> err <why>"
//   zoom.png                     the last zoom
//
// One thread per display waits with its screen.jpg pipe open for writing. When something opens it for
// reading (cat, an agent's Read tool), a new pipe takes the name for the next reader, and a thread for
// this one wakes the display, starts capture if it is idle, encodes the latest frame as JPEG (or
// reuses the last JPEG, if the screen has not changed since), writes screen.json and then the JPEG
// into the pipe, and closes it: the reader gets the screen as of its read and then end of file. A pipe
// has no size and cannot seek, so scp and image viewers cannot read it: `cat` it into a file. Two
// readers that open it in the same instant share one pipe and split the image.
//
// Nothing is captured until a command or a read asks: the first one starts a ScreenCaptureKit stream
// per display, scaled on the GPU to LONG_EDGE pixels on its long edge, and GUI_IO_STOP_AFTER (60)
// seconds without one stop them again, so an idle GuiIO uses no CPU and writes nothing. A stream
// delivers a frame only when the screen changes; the latest one is kept in memory.
//
// Commands (coordinates are screen.jpg's pixels of the current display, converted to global points):
//   move X Y                        (a drag while a button is held by down)
//   click X Y [left|right|middle] [COUNT]
//   down X Y [BUTTON] / up X Y [BUTTON]
//   drag X1 Y1 X2 Y2 [BUTTON]
//   scroll DX DY [X Y]              in lines; DY > 0 scrolls down, DX > 0 right
//   type TEXT                       the rest of the line, as Unicode whatever the input source
//   key COMBO...                    cmd+shift+4, return, esc, f5, cmd+a delete
//   zoom X Y W H                    full-resolution crop to zoom.png
//   settle                          wait until no frame changes over 0.3% of the screen for 250 ms (at most
//                                   3 s); acks screen.jpg's path
//   shot [N]                        wake the display and start capture; acks display N's (or the current
//                                   display's) screen.jpg path
//   display N                       make display N the one coordinates refer to; acks its path
//   status                          grants, capture, displays, version (the one command that neither wakes
//                                   the display nor starts capture)
// An action is acked once its events are posted; settle (which gui sends after every action) waits for
// the result to finish drawing, so the next read of screen.jpg shows it.
//
// Build, sign, install and start: build.sh. Client: gui. Doc: README.md.
import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import Darwin
import ImageIO
import IOKit.pwr_mgt
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - settings

let label = Bundle.main.bundleIdentifier ?? "gui-io"  // also the LaunchAgent's label (build.sh)
let env = ProcessInfo.processInfo.environment
func envNum(_ k: String, _ d: Double) -> Double { env[k].flatMap(Double.init) ?? d }
let longEdge = envNum("GUI_IO_LONG_EDGE", 1568)
let stopAfter = envNum("GUI_IO_STOP_AFTER", 60)  // seconds without a command after which capture stops
let jpegQuality = envNum("GUI_IO_JPEG_QUALITY", 0.8)
let typeChunk = Int(envNum("GUI_IO_TYPE_CHUNK", 20))  // UTF-16 units per key event; 20 is macOS's limit
let settleQuiet = 0.25, settleMax = 3.0
let wakeMax = 8.0  // how long a command waits for a sleeping display to come back
let blackHold = 3.0  // all-black frames are kept only once the screen has been black this long
let settleChange = envNum("GUI_IO_SETTLE_CHANGE", 0.003)  // a frame changing less of the screen does not hold settle
let stateDir = env["GUI_IO_DIR"] ?? (NSHomeDirectory() + "/.local/state/gui-io")
let inPath = stateDir + "/in", outPath = stateDir + "/out", zoomPath = stateDir + "/zoom.png"
let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")
  + "-" + (Bundle.main.infoDictionary?["GuiIOCommit"] as? String ?? "none")

func screenPath(_ index: Int, _ ext: String) -> String { "\(stateDir)/screen\(index == 1 ? "" : "-\(index)").\(ext)" }
func mono() -> Double { ProcessInfo.processInfo.systemUptime }
func wall() -> Double { Date().timeIntervalSince1970 }

let logFmt: DateFormatter = {
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
}()
func say(_ s: String) {
  FileHandle.standardError.write(Data("\(logFmt.string(from: Date())) \(s)\n".utf8))
}

// MARK: - displays and their frames

final class Display {
  let index: Int  // 1-based; 1 is the main display
  let id: CGDirectDisplayID
  let sc: SCDisplay
  let bounds: CGRect  // global points, origin at the main display's top left
  let pixelScale: Double  // backing pixels per point
  let imageW: Int, imageH: Int
  var scale: Double { Double(bounds.width) / Double(imageW) }  // points per screen.jpg pixel
  let jpgPath: String, jsonPath: String
  var stream: SCStream?
  var output: FrameOutput?
  // under `cond`
  var seq = 0  // frames encoded for a read of screen.jpg
  var lastFrame = -1.0  // mono time of the last frame from ScreenCaptureKit, encoded or not
  var lastChange = -1.0  // mono time of the last frame that changed more than settleChange of the screen
  var frames = 0, changes = 0
  var dead = false  // no stream (it stopped, or capture is idle); a rebuild replaces it
  var writeMs = 0.0  // moving average of a frame's JPEG encode and screen.json
  // on frameQ only
  var pending: CVPixelBuffer?  // the latest frame, not yet encoded
  var pendingWall = 0.0
  var jpeg: Data?  // the last frame encoded: a read finds it when the screen has not changed since
  var blackSince: Double?  // when an unbroken run of all-black frames began
  var thumb: [UInt8] = []

  init(index: Int, sc: SCDisplay) {
    self.index = index
    self.sc = sc
    id = sc.displayID
    bounds = CGDisplayBounds(id)
    var pw = Double(bounds.width), ph = Double(bounds.height)
    if let mode = CGDisplayCopyDisplayMode(id) { pw = Double(mode.pixelWidth); ph = Double(mode.pixelHeight) }
    pixelScale = pw / Double(bounds.width)
    let f = min(1.0, longEdge / max(pw, ph))
    imageW = Int((pw * f).rounded())
    imageH = Int((ph * f).rounded())
    jpgPath = screenPath(index, "jpg")
    jsonPath = screenPath(index, "json")
  }

  func toGlobal(_ x: Double, _ y: Double) throws -> CGPoint {
    guard x >= 0, y >= 0, x < Double(imageW), y < Double(imageH) else {
      throw CmdError("\(fmt(x)),\(fmt(y)) is outside display \(index)'s \(imageW)x\(imageH)")
    }
    return CGPoint(x: Double(bounds.minX) + x * scale, y: Double(bounds.minY) + y * scale)
  }
}

let cond = NSCondition()  // guards `displays`, `selected`, the Display fields marked so, lastCommand, capturing
var displays: [Display] = []
var selected = 1
var lastCommand = -1e9
var capturing = false  // streams wanted: a command came within stopAfter
var captureError: String?
var seqCarry: [Int: Int] = [:]  // display index -> its last seq, so seq keeps counting across rebuilds
let frameQ = DispatchQueue(label: "gui-io.frames", qos: .userInteractive)

final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate {
  let d: Display  // strong: a frame in flight may outlive a rebuild; rebuild() breaks the cycle
  init(_ d: Display) { self.d = d }

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sb.isValid,
      let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let pb = CMSampleBufferGetImageBuffer(sb)
    else { return }
    let now = mono()
    let (changed, black) = changedFraction(d, pb)
    // a display going to sleep or waking sends black frames for a second or two: keep the last real
    // screen unless the screen stays black
    if black {
      if d.blackSince == nil { d.blackSince = now }
      if now - d.blackSince! < blackHold { return }
    } else {
      d.blackSince = nil
    }
    cond.lock()
    if d.dead { cond.unlock(); return }  // stopped: a late frame is not kept
    d.lastFrame = now
    d.frames += 1
    if changed >= settleChange { d.lastChange = now; d.changes += 1 }
    cond.broadcast()
    cond.unlock()
    d.pending = pb  // encoded only when screen.jpg is read
    d.pendingWall = wall()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    say("display \(d.index): stream stopped: \(error.localizedDescription)")
    cond.lock()
    let mine = displays.contains { $0 === d }
    d.dead = true
    cond.broadcast()
    cond.unlock()
    if mine { DispatchQueue.main.async { scheduleRebuild("stream stopped", after: 0.5) } }
  }
}

/// The fraction of the screen that changed since the previous frame, from every 8th pixel's luma, so
/// that settle can tell a window, menu or page appearing from a spinner, a blinking caret or the
/// cursor moving; and whether the frame is all black (on frameQ).
func changedFraction(_ d: Display, _ pb: CVPixelBuffer) -> (Double, Bool) {
  CVPixelBufferLockBaseAddress(pb, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddress(pb) else { return (1, false) }
  let step = 8, bpr = CVPixelBufferGetBytesPerRow(pb)
  let tw = CVPixelBufferGetWidth(pb) / step, th = CVPixelBufferGetHeight(pb) / step
  guard tw > 0, th > 0 else { return (1, false) }
  var t = [UInt8](repeating: 0, count: tw * th)
  let p = base.assumingMemoryBound(to: UInt8.self)
  let comparable = d.thumb.count == t.count
  var changed = 0, dark = 0
  for y in 0..<th {
    let row = p + (y * step + step / 2) * bpr
    for x in 0..<tw {
      let px = row + (x * step + step / 2) * 4  // BGRA
      let l = UInt8((Int(px[0]) + 2 * Int(px[1]) + Int(px[2])) >> 2)
      let i = y * tw + x
      if comparable, abs(Int(l) - Int(d.thumb[i])) > 12 { changed += 1 }
      t[i] = l
      if l < 8 { dark += 1 }
    }
  }
  let black = dark * 100 >= t.count * 99  // the cursor is drawn on a black frame too
  if !black { d.thumb = t }
  return (comparable ? Double(changed) / Double(t.count) : 1, black)
}

/// The latest frame as JPEG: encoded now if the screen changed since the last read, the last one
/// otherwise (on frameQ).
func latestJPEG(_ d: Display) -> Data? {
  if let pb = d.pending {
    d.pending = nil
    if let j = encodeFrame(d, pb, d.pendingWall) { d.jpeg = j }
  }
  return d.jpeg
}

func fmt(_ v: Double) -> String {
  v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.3f", v)
}

/// Encodes a frame as JPEG in memory and writes screen.json for it (on frameQ).
func encodeFrame(_ d: Display, _ pb: CVPixelBuffer, _ time: Double) -> Data? {
  let started = mono()
  var cg: CGImage?
  guard VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg) == noErr, let img = cg else {
    say("display \(d.index): no CGImage from the frame"); return nil
  }
  let data = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
  else { return nil }
  CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { say("display \(d.index): JPEG encoding failed"); return nil }
  cond.lock()
  let seq = d.seq + 1
  let count = displays.count
  cond.unlock()
  var cursor = "null"
  if let loc = CGEvent(source: nil)?.location {
    let cx = (Double(loc.x) - Double(d.bounds.minX)) / d.scale, cy = (Double(loc.y) - Double(d.bounds.minY)) / d.scale
    if cx >= 0, cy >= 0, cx < Double(d.imageW), cy < Double(d.imageH) { cursor = "[\(Int(cx)),\(Int(cy))]" }
  }
  let json = "{\"seq\":\(seq),\"time\":\(String(format: "%.3f", time)),\"width\":\(img.width),\"height\":\(img.height),"
    + "\"display\":\(d.index),\"displays\":\(count),\"display_id\":\(d.id),\"image\":\"\(d.jpgPath)\","
    + "\"origin\":[\(fmt(Double(d.bounds.minX))),\(fmt(Double(d.bounds.minY)))],\"scale\":\(d.scale),"
    + "\"pixel_scale\":\(d.pixelScale),\"cursor\":\(cursor)}\n"
  let jtmp = d.jsonPath + ".tmp"
  if FileManager.default.createFile(atPath: jtmp, contents: Data(json.utf8)) { rename(jtmp, d.jsonPath) }
  cond.lock()
  d.seq = seq
  d.writeMs = d.writeMs == 0 ? (mono() - started) * 1000 : d.writeMs * 0.9 + (mono() - started) * 100
  cond.broadcast()
  cond.unlock()
  return data as Data
}

// MARK: - building the streams

var generation = 0
var rebuildPending = false

func isCapturing() -> Bool { cond.lock(); defer { cond.unlock() }; return capturing }

func scheduleRebuild(_ why: String, after: Double = 1) {  // main thread
  if rebuildPending || !isCapturing() { return }
  rebuildPending = true
  say("rebuilding the streams: \(why)")
  DispatchQueue.main.asyncAfter(deadline: .now() + after) { rebuildPending = false; rebuild() }
}

func rebuild() {  // main thread
  guard isCapturing() else { return }
  generation += 1
  let gen = generation
  cond.lock()
  let old = displays
  for d in old { d.dead = true; seqCarry[d.index] = d.seq }
  displays = []
  cond.unlock()
  for d in old { stopStream(d) }
  SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    DispatchQueue.main.async {
      guard gen == generation, isCapturing() else { return }
      guard let content, !content.displays.isEmpty else {
        let why = error?.localizedDescription ?? "no displays"
        if captureError != why { say("no screen capture: \(why)") }
        cond.lock(); captureError = why; cond.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if gen == generation { rebuild() } }
        return
      }
      let main = CGMainDisplayID()
      let sorted = content.displays.sorted { a, b in
        if a.displayID == main { return true }
        if b.displayID == main { return false }
        let ba = CGDisplayBounds(a.displayID), bb = CGDisplayBounds(b.displayID)
        return (ba.minX, ba.minY) < (bb.minX, bb.minY)
      }
      var fresh: [Display] = []
      for (i, scd) in sorted.enumerated() {
        let d = Display(index: i + 1, sc: scd)
        cond.lock(); d.seq = seqCarry[d.index] ?? 0; cond.unlock()
        let cfg = SCStreamConfiguration()
        cfg.width = d.imageW
        cfg.height = d.imageH
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 6
        let out = FrameOutput(d)
        let stream = SCStream(filter: SCContentFilter(display: scd, excludingWindows: []), configuration: cfg, delegate: out)
        do {
          try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: frameQ)
        } catch {
          say("display \(d.index): addStreamOutput: \(error.localizedDescription)")
          continue
        }
        d.stream = stream
        d.output = out
        stream.startCapture { err in
          if let err {
            say("display \(d.index): startCapture: \(err.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if gen == generation { scheduleRebuild("start failed") } }
          }
        }
        say("display \(d.index): id \(d.id), \(Int(d.bounds.width))x\(Int(d.bounds.height)) points at "
          + "\(Int(d.bounds.minX)),\(Int(d.bounds.minY)), pixel scale \(d.pixelScale), image \(d.imageW)x\(d.imageH)")
        fresh.append(d)
      }
      cond.lock()
      displays = fresh
      captureError = fresh.isEmpty ? "no stream started" : nil
      if selected > fresh.count { selected = 1 }
      cond.broadcast()
      cond.unlock()
      // a display that is gone leaves its screen.json behind: remove it (syncPipes removes its pipe)
      for o in old where o.index > fresh.count { unlink(o.jsonPath) }
    }
  }
}

func stopStream(_ d: Display) {  // main thread
  d.stream?.stopCapture { _ in
    frameQ.async { d.pending = nil; d.thumb = []; d.jpeg = nil }
    DispatchQueue.main.async { d.stream = nil; d.output = nil }
  }
}

/// Under `cond`, from a command: capture runs from now until stopAfter seconds after the last command.
func wantCapture() {
  lastCommand = mono()
  guard !capturing else { return }
  capturing = true
  for d in displays { d.dead = true }  // the streams of the last run are gone: wait for new ones
  DispatchQueue.main.async { rebuild(); scheduleStop() }
}

func scheduleStop() {  // main thread
  cond.lock(); let due = lastCommand + stopAfter; cond.unlock()
  DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, due - mono())) {
    cond.lock()
    let idle = capturing && mono() - lastCommand >= stopAfter
    let still = capturing
    var old: [Display] = []
    if idle {
      capturing = false
      old = displays
      for d in old { d.dead = true; seqCarry[d.index] = d.seq }  // kept, dead, for status
      captureError = nil
    }
    cond.broadcast()
    cond.unlock()
    if idle {
      generation += 1  // a rebuild still retrying gives up
      for d in old { stopStream(d) }
      say("capture stopped: no command for \(fmt(stopAfter)) s")
    } else if still {
      scheduleStop()
    }
  }
}

// MARK: - input

struct CmdError: Error {
  let msg: String
  init(_ m: String) { msg = m }
}

let src: CGEventSource? = {
  let s = CGEventSource(stateID: .hidSystemState)
  s?.localEventsSuppressionInterval = 0  // the owner's own mouse and keyboard stay live
  return s
}()

enum Button: String {
  case left, right, middle
  var cg: CGMouseButton { self == .left ? .left : self == .right ? .right : .center }
  var down: CGEventType { self == .left ? .leftMouseDown : self == .right ? .rightMouseDown : .otherMouseDown }
  var up: CGEventType { self == .left ? .leftMouseUp : self == .right ? .rightMouseUp : .otherMouseUp }
  var dragged: CGEventType { self == .left ? .leftMouseDragged : self == .right ? .rightMouseDragged : .otherMouseDragged }
}
var held: Button?  // pressed by `down` and not yet released

func mouse(_ type: CGEventType, _ p: CGPoint, _ b: Button = .left, clicks: Int64 = 1) {
  guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: b.cg) else { return }
  e.setIntegerValueField(.mouseEventClickState, value: clicks)
  e.flags = []
  e.post(tap: .cghidEventTap)
}

func ms(_ v: Double) { usleep(useconds_t(v * 1000)) }

func moveTo(_ p: CGPoint) {
  if let b = held { mouse(b.dragged, p, b) } else { mouse(.mouseMoved, p) }
}

func dragPath(_ a: CGPoint, _ b: CGPoint, _ btn: Button) {
  let dist = hypot(Double(b.x - a.x), Double(b.y - a.y))
  let steps = max(8, min(60, Int(dist / 15)))
  for i in 1...steps {
    let t = Double(i) / Double(steps)
    mouse(btn.dragged, CGPoint(x: Double(a.x) + (Double(b.x) - Double(a.x)) * t, y: Double(a.y) + (Double(b.y) - Double(a.y)) * t), btn)
    ms(8)
  }
}

func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
  guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
  e.flags = flags
  e.post(tap: .cghidEventTap)
}

func typeText(_ s: String) {
  var chunk: [UniChar] = []
  func send() {
    guard !chunk.isEmpty else { return }
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
      e.flags = []
      chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
      e.post(tap: .cghidEventTap)
    }
    chunk.removeAll()
    ms(3)
  }
  for ch in s {  // whole grapheme clusters, so an emoji is never split between two events
    let u = Array(String(ch).utf16)
    if !chunk.isEmpty, chunk.count + u.count > typeChunk { send() }
    chunk += u
  }
  send()
}

let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
  "cmd": (55, .maskCommand), "command": (55, .maskCommand), "shift": (56, .maskShift),
  "ctrl": (59, .maskControl), "control": (59, .maskControl), "alt": (58, .maskAlternate),
  "opt": (58, .maskAlternate), "option": (58, .maskAlternate), "fn": (63, .maskSecondaryFn),
]
// ANSI virtual key codes; macOS maps them to the Latin letter for shortcuts with any input source
let keyNames: [String: CGKeyCode] = {
  var k: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53,
    "escape": 53, "capslock": 57, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116,
    "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126, "help": 114,
    "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44, "backslash": 42,
    "semicolon": 41, "quote": 39, "grave": 50, "leftbracket": 33, "rightbracket": 30,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
    "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
    "f18": 79, "f19": 80, "f20": 90,
  ]
  k["⌫"] = 51
  return k
}()
// US-layout shifted symbols
let shifted: [Character: String] = [
  "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
  "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
  "~": "`",
]
// keys whose real events carry the fn (and, for arrows, numeric-pad) flag
let fnKeys: Set<CGKeyCode> = [115, 116, 117, 119, 121, 123, 124, 125, 126, 122, 120, 99, 118, 96, 97, 98,
                              100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 114]

func parseCombo(_ combo: String) throws -> (mods: [(CGKeyCode, CGEventFlags)], key: CGKeyCode?) {
  var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
  if combo.hasSuffix("++") { parts.removeLast(2); parts.append("+") }  // cmd++
  else if combo == "+" { parts = ["+"] }
  var mods: [(CGKeyCode, CGEventFlags)] = []
  var keyCode: CGKeyCode?
  for (i, raw) in parts.enumerated() {
    if raw.isEmpty { throw CmdError("bad key combo \(combo)") }
    if let m = modifiers[raw.lowercased()], raw.count > 1 { mods.append(m); continue }
    guard i == parts.count - 1 else { throw CmdError("\(raw) is not a modifier in \(combo)") }
    var name = raw
    if raw.count == 1, let c = raw.first {
      if let base = shifted[c] { name = base; mods.append(modifiers["shift"]!) }
      else if c.isUppercase, c.isASCII { name = raw.lowercased(); mods.append(modifiers["shift"]!) }
    } else {
      name = raw.lowercased()
      if name == "plus" { name = "="; mods.append(modifiers["shift"]!) }
    }
    guard let k = keyNames[name] else { throw CmdError("unknown key \(raw)") }
    keyCode = k
  }
  return (mods, keyCode)
}

func pressCombo(_ combo: String) throws {
  let (mods, k) = try parseCombo(combo)
  var flags: CGEventFlags = []
  for (code, f) in mods { flags.insert(f); key(code, true, flags); ms(2) }
  if let k {
    var kf = flags
    if fnKeys.contains(k) { kf.insert(.maskSecondaryFn) }
    if (123...126).contains(k) { kf.insert(.maskNumericPad) }
    key(k, true, kf); ms(8); key(k, false, kf); ms(2)
  }
  for (code, f) in mods.reversed() { flags.remove(f); key(code, false, flags); ms(2) }
}

// MARK: - commands

var activity: IOPMAssertionID = 0
let activityLock = NSLock()  // target() runs on the command thread and on every pipe's thread

/// Display n (the current one when nil), live: while a rebuild is under way (after a display change
/// or a stream that stopped) it waits up to `wait` for the new one. Under `cond`.
func live(_ n: Int?, wait: Double) throws -> Display {
  let until = mono() + wait
  while true {
    let i = n ?? selected
    if displays.contains(where: { !$0.dead }) || (!displays.isEmpty && mono() >= until) {
      guard i >= 1, i <= displays.count else { throw CmdError("no display \(i) (there are \(displays.count))") }
      if !displays[i - 1].dead || mono() >= until { return displays[i - 1] }
    } else if mono() >= until {
      throw CmdError("no screen capture: \(captureError ?? "no displays")")
    }
    cond.wait(until: Date(timeIntervalSinceNow: min(0.05, max(0.001, until - mono()))))
  }
}

/// Declare user activity, so a sleeping display wakes, start capture if it is idle, and return the
/// display to act on. A sleeping display has no stream (it is built once the display is back), and its
/// first frames after waking are black (not kept): wait, up to wakeMax, for the display's first real
/// frame, so that what is acted on and returned is the screen as it is.
func target(_ n: Int? = nil) throws -> Display {
  activityLock.lock()
  IOPMAssertionDeclareUserActivity("gui-io" as CFString, kIOPMUserActiveLocal, &activity)
  activityLock.unlock()
  let t0 = mono()
  cond.lock()
  defer { cond.unlock() }
  let i0 = (n ?? selected) - 1
  let wasAsleep = displays.indices.contains(i0) && CGDisplayIsAsleep(displays[i0].id) != 0  // for the log
  wantCapture()
  var d = try live(n, wait: wakeMax)
  let slept = CGDisplayIsAsleep(d.id) != 0
  guard slept || d.dead || d.lastFrame < 0 else { return d }
  var awake: Double?
  var shown = false
  while mono() < t0 + wakeMax {
    d = try live(n, wait: max(0, t0 + wakeMax - mono()))
    if awake == nil, CGDisplayIsAsleep(d.id) == 0 { awake = mono() }
    if let a = awake, !d.dead, d.lastFrame >= (slept ? a : 0) { shown = true; break }
    cond.wait(until: Date(timeIntervalSinceNow: 0.02))
  }
  say(String(format: "display %d %@ after %.0f ms", d.index, slept || wasAsleep ? "woke, its screen" : "captured, its first frame",
             (mono() - t0) * 1000) + (shown ? "" : " (not yet: acting anyway)"))
  return d
}

func settle(_ d: Display) {
  let t0 = mono()
  cond.lock()
  while true {
    let now = mono()
    let quietSince = max(d.lastChange, t0)
    if now - quietSince >= settleQuiet || now - t0 >= settleMax { break }
    cond.wait(until: Date(timeIntervalSinceNow: min(quietSince + settleQuiet, t0 + settleMax) - now + 0.002))
  }
  cond.unlock()
}

func canPost() -> Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

let commandNames: Set<String> = ["move", "click", "down", "up", "drag", "scroll", "type", "key", "zoom", "settle",
                                 "shot", "display", "status"]

func handle(_ line: String) -> String {
  syncPipes()  // a screen.jpg removed by hand comes back with the next command
  var rest = Substring(line)
  func word() -> String? {
    rest = rest.drop(while: { $0 == " " || $0 == "\t" })
    guard !rest.isEmpty else { return nil }
    let w = rest.prefix(while: { $0 != " " && $0 != "\t" })
    rest = rest.dropFirst(w.count)
    return String(w)
  }
  guard var first = word() else { return "" }
  var id = "-"
  if !commandNames.contains(first) {
    id = first
    guard let c = word() else { return "\(id) err no command" }
    first = c
  }
  let cmd = first
  // `type` takes the rest of the line after one separating space, spaces included
  let text = rest.first == " " ? String(rest.dropFirst()) : String(rest)
  var args: [String] = []
  if cmd != "type" { while let w = word() { args.append(w) } }
  func num(_ i: Int) throws -> Double {
    guard i < args.count, let v = Double(args[i]) else { throw CmdError("\(cmd): argument \(i + 1) must be a number") }
    return v
  }
  func button(_ i: Int) throws -> Button {
    guard i < args.count else { return .left }
    guard let b = Button(rawValue: args[i].lowercased()) else { throw CmdError("\(cmd): no button \(args[i])") }
    return b
  }
  defer { if cmd != "status" { cond.lock(); if capturing { lastCommand = mono() }; cond.unlock() } }
  do {
    switch cmd {
    case "status":
      cond.lock()
      let ds = displays.map { "\($0.index):\($0.imageW)x\($0.imageH)@\(fmt(Double($0.bounds.minX))),\(fmt(Double($0.bounds.minY)))"
        + (CGDisplayIsAsleep($0.id) != 0 ? ":asleep" : "") }
      let err = captureError
      let sel = selected
      let seq = displays.indices.contains(sel - 1) ? displays[sel - 1].seq : (seqCarry[sel] ?? 0)
      let counts = displays.map { "\($0.index):\($0.frames)/\($0.changes)/\(String(format: "%.1fms", $0.writeMs))" }.joined(separator: ",")
      let on = capturing, live = displays.contains { !$0.dead && $0.lastFrame >= 0 }
      cond.unlock()
      let screen = CGPreflightScreenCaptureAccess() || live ? "granted" : "denied"
      let capture = !on ? "idle" : err != nil ? "failing" : live ? "on" : "starting"
      return "\(id) ok seq=\(seq) display=\(sel) screen=\(screen) accessibility=\(canPost() ? "granted" : "denied")"
        + " capture=\(capture) displays=\(ds.joined(separator: ",")) frames=\(counts) version=\(version)"
        + (on && err != nil ? " error=\(err!)" : "")
    case "display":
      let n = Int(try num(0))
      let d = try target(n)
      cond.lock(); selected = n; cond.unlock()
      return "\(id) ok display=\(n) path=\(d.jpgPath)"
    case "shot":
      let d = try target(args.isEmpty ? nil : Int(num(0)))
      return "\(id) ok display=\(d.index) path=\(d.jpgPath)"
    case "settle":
      let d = try target()
      settle(d)
      return "\(id) ok display=\(d.index) path=\(d.jpgPath)"
    case "zoom":
      let d = try target()
      let x = try num(0), y = try num(1), w = try num(2), h = try num(3)
      guard w > 0, h > 0 else { throw CmdError("zoom: width and height must be positive") }
      let r = CGRect(x: x * d.scale, y: y * d.scale, width: w * d.scale, height: h * d.scale)
        .intersection(CGRect(origin: .zero, size: d.bounds.size))
      guard !r.isNull, r.width >= 1, r.height >= 1 else { throw CmdError("zoom: the rectangle is outside display \(d.index)") }
      let cfg = SCStreamConfiguration()
      cfg.sourceRect = r
      cfg.width = Int((Double(r.width) * d.pixelScale).rounded())
      cfg.height = Int((Double(r.height) * d.pixelScale).rounded())
      cfg.colorSpaceName = CGColorSpace.sRGB
      cfg.showsCursor = true
      let sem = DispatchSemaphore(value: 0)
      var image: CGImage?
      var failure: Error?
      SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d.sc, excludingWindows: []), configuration: cfg) {
        image = $0; failure = $1; sem.signal()
      }
      guard sem.wait(timeout: .now() + 5) == .success else { throw CmdError("zoom: capture timed out") }
      guard let image else { throw CmdError("zoom: \(failure?.localizedDescription ?? "no image")") }
      let tmp = zoomPath + ".tmp"
      guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { throw CmdError("zoom: cannot write \(tmp)") }
      CGImageDestinationAddImage(dest, image, nil)
      guard CGImageDestinationFinalize(dest), rename(tmp, zoomPath) == 0 else { throw CmdError("zoom: cannot write \(zoomPath)") }
      return "\(id) ok display=\(d.index) path=\(zoomPath) size=\(image.width)x\(image.height)"
    case "move", "click", "down", "up", "drag", "scroll", "type", "key":
      guard canPost() else { throw CmdError("Accessibility is not granted to GuiIO, so input would be dropped") }
      let d = try target()
      switch cmd {
      case "move":
        moveTo(try d.toGlobal(try num(0), try num(1)))
      case "click":
        let p = try d.toGlobal(try num(0), try num(1))
        var b = Button.left, count = 1
        for a in args.dropFirst(2) {
          if let n = Int(a), n >= 1, n <= 5 { count = n }
          else if let bb = Button(rawValue: a.lowercased()) { b = bb }
          else { throw CmdError("click: \(a) is neither a button nor a count") }
        }
        moveTo(p); ms(10)
        for i in 1...count {
          mouse(b.down, p, b, clicks: Int64(i)); ms(10)
          mouse(b.up, p, b, clicks: Int64(i))
          if i < count { ms(10) }
        }
        held = nil
      case "down":
        let p = try d.toGlobal(try num(0), try num(1)), b = try button(2)
        moveTo(p); ms(20)
        mouse(b.down, p, b)
        held = b
      case "up":
        let p = try d.toGlobal(try num(0), try num(1)), b = try args.count > 2 ? button(2) : (held ?? .left)
        if p != CGEvent(source: nil)?.location { moveTo(p); ms(20) }
        mouse(b.up, p, b)
        held = nil
      case "drag":
        let a = try d.toGlobal(try num(0), try num(1)), z = try d.toGlobal(try num(2), try num(3)), b = try button(4)
        held = nil
        mouse(.mouseMoved, a); ms(30)
        mouse(b.down, a, b); ms(60)
        dragPath(a, z, b); ms(60)
        mouse(b.up, z, b)
      case "scroll":
        let dx = try num(0), dy = try num(1)
        if args.count >= 4 { moveTo(try d.toGlobal(try num(2), try num(3))); ms(20) }
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2,
                              wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0) else {
          throw CmdError("scroll: no event")
        }
        e.flags = []
        e.post(tap: .cghidEventTap)
      case "type":
        typeText(text)
      default:  // key
        guard !args.isEmpty else { throw CmdError("key: which key?") }
        for a in args { _ = try parseCombo(a) }  // all or nothing
        for a in args { try pressCombo(a) }
      }
      return "\(id) ok display=\(d.index)"
    default:
      throw CmdError("unknown command \(cmd)")
    }
  } catch let e as CmdError {
    return "\(id) err \(e.msg)"
  } catch {
    return "\(id) err \(error.localizedDescription)"
  }
}

func ack(_ s: String) {
  guard !s.isEmpty else { return }
  let fd = open(outPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
  guard fd >= 0 else { say("cannot open \(outPath): \(String(cString: strerror(errno)))"); return }
  var st = stat()
  if fstat(fd, &st) == 0, st.st_size > 1 << 20 { ftruncate(fd, 0) }  // clients reread from 0 when it shrinks
  let data = Array((s + "\n").utf8)
  _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  close(fd)
}

func readCommands() {
  let fd = open(inPath, O_RDWR)  // read-write: never EOF when the last writer closes
  guard fd >= 0 else { say("cannot open \(inPath): \(String(cString: strerror(errno)))"); exit(1) }
  var buf = [UInt8](repeating: 0, count: 65536)
  var acc: [UInt8] = []
  while true {
    let n = read(fd, &buf, buf.count)
    if n < 0 { if errno == EINTR { continue }; say("read \(inPath): \(String(cString: strerror(errno)))"); sleep(1); continue }
    if n == 0 { ms(100); continue }
    acc.append(contentsOf: buf[0..<n])
    while let nl = acc.firstIndex(of: 10) {
      var lineBytes = Array(acc[0..<nl])
      acc.removeSubrange(0...nl)
      if lineBytes.last == 13 { lineBytes.removeLast() }
      let line = String(decoding: lineBytes, as: UTF8.self)
      let t = mono()
      autoreleasepool {
        var a = handle(line)
        if a.contains(" ok ") { a += String(format: " ms=%.0f", (mono() - t) * 1000) }
        ack(a)
      }
    }
  }
}

// MARK: - the screen pipes

let pipeLock = NSLock()  // guards pipeGen and pipeGenNext, and is held through syncPipes
var pipeGen: [Int: Int] = [:]  // display index -> the generation of the thread that serves its screen.jpg
var pipeGenNext = 0
let readerTimeout = 10.0  // a reader that stops reading for this long is dropped, and its thread ends

func activeDisplayCount() -> Int {
  var n: UInt32 = 0
  CGGetActiveDisplayList(0, nil, &n)
  return max(1, Int(n))
}

func isFIFO(_ path: String) -> Bool {
  var st = stat()
  return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO
}

/// Gives each active display a screen.jpg pipe and a thread that serves it, and takes them from a
/// display that is gone. At start, on a display change and before every command.
func syncPipes() {
  let count = activeDisplayCount()
  pipeLock.lock()
  defer { pipeLock.unlock() }
  for i in 1...count {
    let path = screenPath(i, "jpg")
    if pipeGen[i] != nil, isFIFO(path) { continue }
    if !isFIFO(path) {
      unlink(path)  // a regular screen.jpg from an older GuiIO, or nothing
      guard mkfifo(path, 0o600) == 0 else { say("mkfifo \(path): \(String(cString: strerror(errno)))"); continue }
    }
    // (a pipe removed by hand strands its thread in open(), which can never return now; it is left there)
    pipeGenNext += 1
    let gen = pipeGenNext
    pipeGen[i] = gen
    Thread { servePipe(i, gen) }.start()
  }
  for (i, _) in pipeGen where i > count {
    pipeGen[i] = nil
    let path = screenPath(i, "jpg")
    let fd = open(path, O_RDONLY | O_NONBLOCK)  // lets its thread's open() return, to find itself retired
    unlink(path)
    unlink(screenPath(i, "json"))
    if fd >= 0 { close(fd) }
  }
}

/// Serves display i's screen.jpg: waits for a reader, puts a new pipe at the path at once, and serves
/// the reader on a thread of its own, which writes the screen into the old pipe and closes it. Nothing
/// opens the old pipe again, so the reader gets one image and then end of file however slowly it reads
/// (reopening one pipe for the next reader, as GuiIO did at first, carried on into the same reader
/// before it had seen the end of file: one that read in small steps got image after image, endlessly),
/// and a reader that stalls holds up nobody. The old pipe keeps a hidden name until its readers are
/// gone (wakeReaders).
func servePipe(_ i: Int, _ gen: Int) {
  let path = screenPath(i, "jpg")
  func mine() -> Bool { pipeLock.lock(); defer { pipeLock.unlock() }; return pipeGen[i] == gen }
  while mine() {
    let fd = open(path, O_WRONLY)  // blocks until something opens the pipe for reading
    if fd < 0 {
      let e = errno
      if e == EINTR { continue }
      guard mine() else { break }
      if e == ENOENT { _ = mkfifo(path, 0o600); continue }
      say("open \(path): \(String(cString: strerror(e)))")
      sleep(1)
      continue
    }
    guard let renewed = renewPipe(i, gen, path) else { close(fd); break }
    Thread {
      serveScreen(i, fd)
      close(fd)
      if let kept = renewed.kept { wakeReaders(kept); unlink(kept) }
    }.start()
  }
}

var keptSerial = 0  // under pipeLock
struct Renewed { let kept: String? }

/// Puts a new, unopened pipe at path in place of the one a reader has just opened, which keeps a
/// hidden name (kept) for wakeReaders; nil when display i's pipe is no longer this thread's to serve
/// (the display is gone or the pipe was made again).
func renewPipe(_ i: Int, _ gen: Int, _ path: String) -> Renewed? {
  pipeLock.lock()
  defer { pipeLock.unlock() }
  guard pipeGen[i] == gen else { return nil }
  keptSerial += 1
  let name = (path as NSString).lastPathComponent
  let kept = "\(stateDir)/.\(name).served-\(keptSerial)", tmp = "\(stateDir)/.\(name).new"
  let linked = link(path, kept) == 0
  unlink(tmp)
  if mkfifo(tmp, 0o600) != 0 || rename(tmp, path) != 0 {
    say("a new pipe at \(path): \(String(cString: strerror(errno))); the next reader may share this one")
    unlink(tmp)
    if linked { unlink(kept) }  // the old pipe is still at path, where opening it would wake a new reader
    return Renewed(kept: nil)
  }
  return Renewed(kept: linked ? kept : nil)
}

/// On macOS a reader that shares a pipe with another (both opened it in the same instant) can miss
/// the end of file when the writer closes, and then waits forever: about half the time in a test on
/// an M1 Mac. Opening the pipe for writing and closing it again ends that wait, so this does it every 20 ms
/// for as long as a reader has the pipe open, at most readerTimeout. A lone reader has usually closed
/// it by the first try, which then fails with ENXIO.
func wakeReaders(_ kept: String) {
  let end = mono() + readerTimeout
  while mono() < end {
    usleep(20_000)
    let w = open(kept, O_WRONLY | O_NONBLOCK)
    if w < 0 { break }
    close(w)
  }
}

func serveScreen(_ i: Int, _ fd: Int32) {
  let name = (screenPath(i, "jpg") as NSString).lastPathComponent
  do {
    let d = try target(i)
    guard let jpeg = frameQ.sync(execute: { latestJPEG(d) }) else { throw CmdError("no frame from display \(i) yet") }
    if let why = writeAll(fd, jpeg, timeout: readerTimeout) { say("\(name): \(why)") }
  } catch let e as CmdError {
    say("\(name): \(e.msg); the reader got an empty file")
  } catch {
    say("\(name): \(error.localizedDescription); the reader got an empty file")
  }
  cond.lock(); if capturing { lastCommand = mono() }; cond.unlock()
}

/// Writes all of `data` into a pipe; nil, or why it stopped: the reader closed it, or stopped reading
/// for `timeout` seconds.
func writeAll(_ fd: Int32, _ data: Data, timeout: Double) -> String? {
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
  var moved = mono()
  return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
    guard let base = raw.baseAddress else { return nil }
    var off = 0
    while off < raw.count {
      let n = write(fd, base + off, raw.count - off)
      if n > 0 { off += n; moved = mono(); continue }
      let e = errno
      if n < 0, e == EINTR { continue }
      if n < 0, e == EAGAIN {
        let left = moved + timeout - mono()
        if left <= 0 { return "the reader stopped reading after \(off) of \(raw.count) bytes" }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
        continue
      }
      return "the reader closed the pipe after \(off) of \(raw.count) bytes"
    }
    return nil
  }
}

// MARK: - start

setvbuf(stderr, nil, _IOLBF, 0)
umask(0o077)
signal(SIGPIPE, SIG_IGN)  // a reader that closes screen.jpg early must not kill GuiIO
if env["XPC_SERVICE_NAME"] != label, !CommandLine.arguments.contains("--foreground") {
  // opened from Finder or by "Quit & Reopen": the LaunchAgent's copy is the one that runs
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
  p.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
  try? p.run()
  p.waitUntilExit()
  exit(0)
}
try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
chmod(stateDir, 0o700)
let lockFD = open(stateDir + "/lock", O_RDWR | O_CREAT, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
  say("another gui-io holds \(stateDir)/lock; exiting")
  exit(0)
}
var st = stat()
if lstat(inPath, &st) != 0 || (st.st_mode & S_IFMT) != S_IFIFO {
  unlink(inPath)
  guard mkfifo(inPath, 0o600) == 0 else { say("mkfifo \(inPath): \(String(cString: strerror(errno)))"); exit(1) }
}
say("gui-io \(version) starting, pid \(getpid()), state in \(stateDir)")
// seq goes on from the screen files of the last run, so a reader comparing seqs is not sent back
for i in 1...8 {
  let path = "\(stateDir)/screen\(i == 1 ? "" : "-\(i)").json"
  if let data = FileManager.default.contents(atPath: path),
     let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let n = obj["seq"] as? Int {
    seqCarry[i] = n
  }
}
for i in stride(from: activeDisplayCount() + 1, through: 9, by: 1) {  // displays of an earlier run that are gone
  unlink(screenPath(i, "jpg")); unlink(screenPath(i, "json"))
}
for name in (try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? [] where name.hasPrefix(".screen") {
  unlink("\(stateDir)/\(name)")  // the hidden pipes and temporary files an earlier run left
}
syncPipes()

// Ask once for each grant, so the app is listed in System Settings with its switch; a KeepAlive
// restart does not ask again.
if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
if !AXIsProcessTrusted() {
  let marker = stateDir + "/.accessibility-asked"
  if !FileManager.default.fileExists(atPath: marker) {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    FileManager.default.createFile(atPath: marker, contents: nil)
  }
  _ = CGRequestPostEventAccess()
}
say("screen recording \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted"), accessibility \(canPost() ? "granted" : "not granted")")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
  if flags.contains(.beginConfigurationFlag) { return }
  DispatchQueue.main.async { syncPipes(); scheduleRebuild("display configuration changed") }
}, nil)
Thread { readCommands() }.start()  // capture starts with the first command or read
app.run()
