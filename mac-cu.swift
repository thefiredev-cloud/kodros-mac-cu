import Cocoa
import ApplicationServices
import ScreenCaptureKit

// mac-cu — computer use for agents on this Mac.
// One shared event source, hover-armed clicks, AX-first actions, JSON output.

let args = CommandLine.arguments
guard args.count > 1 else {
    print(#"{"ok":false,"error":"usage: mac-cu <apps|windows|elements|capture|click|doubleclick|rightclick|move|drag|scroll|type|key|hotkey|pos> …"}"#)
    exit(2)
}

func ok(_ extra: String = "") { print("{\"ok\":true\(extra)}") }
func fail(_ message: String, _ code: Int32 = 1) -> Never {
    print("{\"ok\":false,\"error\":\(jsonString(message))}")
    exit(code)
}

guard AXIsProcessTrusted() else {
    fail("no accessibility permission for the calling process", 3)
}

// Blocked inputs (research: cua-driver safety model). Hard stops, not warnings.
let blockedTypePatterns: [NSRegularExpression] = [
    "rm\\s+-rf\\s+/", "sudo\\s+rm", "curl[^|]*\\|\\s*(ba|z)?sh", "wget[^|]*\\|\\s*(ba|z)?sh",
    "mkfs", "dd\\s+if=", ">\\s*/dev/sd", "shutdown", "reboot",
].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

func guardTypeText(_ text: String) {
    for pattern in blockedTypePatterns where pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
        fail("blocked pattern in type text")
    }
}

func guardHotkey(_ flags: CGEventFlags, _ key: String) {
    let lock = flags.contains(.maskControl) && flags.contains(.maskCommand) && key == "q"
    let logout = flags.contains(.maskShift) && flags.contains(.maskCommand) && key == "q"
    if lock || logout { fail("blocked shortcut: lock screen / log out") }
}

func parseModifiers(_ list: String) -> CGEventFlags {
    var flags = CGEventFlags()
    for part in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
        if let flag = flagFor(part) { flags.insert(flag) }
    }
    return flags
}

let source = CGEventSource(stateID: .combinedSessionState)

// MARK: - Accessibility helpers

struct AXEntry {
    let index: Int
    let role: String
    let label: String
    let frame: CGRect
    let element: AXUIElement
    let actions: [String]
}

func axCopy<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type = T.self) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
    return ref as? T
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef, let sizeVal = sizeRef else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: pos, size: size)
}

func axActions(_ element: AXUIElement) -> [String] {
    var ref: CFArray?
    guard AXUIElementCopyActionNames(element, &ref) == .success, let names = ref as? [String] else { return [] }
    return names
}

func pidForApp(_ name: String) -> pid_t? {
    if let pid = pid_t(name) { return pid }
    let needle = name.lowercased()
    let apps = NSWorkspace.shared.runningApplications
    return apps.first(where: {
        ($0.localizedName ?? "").lowercased() == needle || ($0.bundleIdentifier ?? "").lowercased() == needle
    })?.processIdentifier ?? apps.first(where: {
        ($0.localizedName ?? "").lowercased().contains(needle) || ($0.bundleIdentifier ?? "").lowercased().contains(needle)
    })?.processIdentifier
}

func collectElements(pid: pid_t, cap: Int = 300) -> [AXEntry] {
    let app = AXUIElementCreateApplication(pid)
    var entries: [AXEntry] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard entries.count < cap, depth <= 10 else { return }
        let role = axCopy(element, kAXRoleAttribute) ?? ""
        if let frame = axFrame(element), frame.width > 0, frame.height > 0 {
            let label = axCopy(element, kAXDescriptionAttribute)
                ?? axCopy(element, kAXTitleAttribute)
                ?? axCopy(element, kAXRoleDescriptionAttribute)
                ?? ""
            let value: String = axCopy(element, kAXValueAttribute) ?? ""
            let text = label.isEmpty ? String(value.prefix(60)) : label
            entries.append(AXEntry(index: entries.count + 1, role: role, label: text,
                                   frame: frame, element: element, actions: axActions(element)))
        }
        let children: [AXUIElement] = axCopy(element, kAXChildrenAttribute) ?? []
        for child in children { walk(child, depth + 1) }
    }
    let windows: [AXUIElement] = axCopy(app, kAXWindowsAttribute) ?? []
    for window in windows { walk(window, 0) }
    if windows.isEmpty { walk(app, 0) }
    return entries
}

func elementJSON(_ e: AXEntry) -> String {
    let f = e.frame
    return "#\(e.index) \(e.role) \(jsonString(e.label)) @ (\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))) actions=[\(e.actions.joined(separator: ","))]"
}

// MARK: - Event primitives (shared source, hover-armed)

func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.post(tap: .cghidEventTap)
}

func clickAt(_ point: CGPoint, button: CGMouseButton = .left, count: Int = 1, modifiers: CGEventFlags = []) {
    postMouse(.mouseMoved, at: point)
    usleep(180_000)  // let hover arm gesture recognizers
    for _ in 0..<count {
        let down = CGEvent(mouseEventSource: source, mouseType: button == .left ? .leftMouseDown : .rightMouseDown, mouseCursorPosition: point, mouseButton: button)
        let up = CGEvent(mouseEventSource: source, mouseType: button == .left ? .leftMouseUp : .rightMouseUp, mouseCursorPosition: point, mouseButton: button)
        down?.flags = modifiers
        up?.flags = modifiers
        down?.post(tap: .cghidEventTap)
        usleep(90_000)
        up?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

func typeText(_ text: String) {
    for char in text {
        var utf16 = Array(String(char).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        usleep(14_000)
    }
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53, "delete": 51,
    "space": 49, "left": 123, "right": 124, "down": 125, "up": 126,
    "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "l": 37, "k": 40, "q": 12, "w": 13,
]

func flagFor(_ name: String) -> CGEventFlags? {
    switch name { case "cmd", "command": return .maskCommand
    case "shift": return .maskShift
    case "opt", "option", "alt": return .maskAlternate
    case "ctrl", "control": return .maskControl
    default: return nil }
}

// ScreenCaptureKit capture (async APIs behind a semaphore for the CLI).
func scCapture(windowID: CGWindowID?) -> CGImage? {
    let semaphore = DispatchSemaphore(value: 0)
    var result: CGImage?
    Task {
        defer { semaphore.signal() }
        do {
            let content = try await SCShareableContent.current
            let config = SCStreamConfiguration()
            config.showsCursor = false
            if let wid = windowID {
                guard let window = content.windows.first(where: { $0.windowID == wid }) else {
                    FileHandle.standardError.write("scCapture: window \(wid) not listed by ScreenCaptureKit\n".data(using: .utf8)!)
                    return
                }
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                result = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            } else {
                let point = NSEvent.mouseLocation
                guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main,
                      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) })
                else { return }
                config.width = display.width * 2
                config.height = display.height * 2
                result = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            }
        } catch {
            FileHandle.standardError.write("scCapture: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
    semaphore.wait()
    return result
}

// MARK: - Set-of-mark overlay

func somOverlay(_ base: CGImage, pid: pid_t, windowFrame: CGRect) -> NSBitmapImageRep? {
    let scale = CGFloat(base.width) / max(1, windowFrame.width)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.width, pixelsHigh: base.height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    let accent = NSColor(calibratedRed: 0.122, green: 0.478, blue: 0.353, alpha: 1)
    let font = NSFont.boldSystemFont(ofSize: 12 * scale)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    for e in collectElements(pid: pid) where windowFrame.intersects(e.frame) {
        let local = e.frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        let rect = CGRect(x: local.minX * scale, y: CGFloat(base.height) - local.maxY * scale,
                          width: local.width * scale, height: local.height * scale)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(max(2, 1.5 * scale))
        ctx.stroke(rect)
        let tag = "#\(e.index)" as NSString
        let textSize = tag.size(withAttributes: attrs)
        let tagRect = CGRect(x: rect.minX, y: rect.maxY - textSize.height - 2 * scale,
                             width: textSize.width + 6 * scale, height: textSize.height + 2 * scale)
        ctx.setFillColor(accent.cgColor)
        ctx.fill(tagRect)
        tag.draw(at: CGPoint(x: tagRect.minX + 3 * scale, y: tagRect.minY + scale), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Commands

switch args[1] {
case "apps":
    var seen = Set<String>()
    var out: [String] = []
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, !seen.contains(owner),
              let pid = w[kCGWindowOwnerPID as String] as? Int32 else { continue }
        seen.insert(owner)
        out.append("{\"name\":\(jsonString(owner)),\"pid\":\(pid)}")
    }
    print("{\"ok\":true,\"apps\":[\(out.joined(separator: ","))]}")

case "windows":
    guard args.count > 2, let pid = pidForApp(args[2]) else { fail("windows <app>") }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [String] = []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let title = w[kCGWindowName as String] as? String ?? ""
        let wid = w[kCGWindowNumber as String] as? Int ?? 0
        let bx = Int(b["X"] ?? 0), by = Int(b["Y"] ?? 0), bw = Int(b["Width"] ?? 0), bh = Int(b["Height"] ?? 0)
        out.append("{\"id\":\(wid),\"title\":\(jsonString(title)),\"frame\":[\(bx),\(by),\(bw),\(bh)]}")
    }
    print("{\"ok\":true,\"windows\":[\(out.joined(separator: ","))]}")

case "elements":
    // elements <app> [filter] [--json]
    guard args.count > 2, let pid = pidForApp(args[2]) else { fail("elements <app|pid> [filter] [--json]") }
    let asJSON = args.contains("--json")
    let filter = args.count > 3 && !args[3].hasPrefix("--") ? args[3].lowercased() : ""
    let entries = collectElements(pid: pid)
    var matched: [AXEntry] = []
    for e in entries {
        if !filter.isEmpty, !e.role.lowercased().contains(filter), !e.label.lowercased().contains(filter) { continue }
        matched.append(e)
    }
    if asJSON {
        let rows = matched.map { e in
            let f = e.frame
            return "{\"index\":\(e.index),\"role\":\(jsonString(e.role)),\"label\":\(jsonString(e.label)),\"frame\":[\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))],\"actions\":\(jsonString(e.actions.joined(separator: ",")))}"
        }
        print("{\"ok\":true,\"count\":\(rows.count),\"elements\":[\(rows.joined(separator: ","))]}")
    } else {
        print("{\"ok\":true,\"count\":\(matched.count)")
        matched.forEach { print(elementJSON($0)) }
    }

case "capture":
    // capture [path] [--app X] [--som] — full screen, or one app's window with optional numbered overlays
    var path = "/tmp/mac-cu-capture.png"
    var appName: String?, som = false
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--app": i += 1; appName = i < args.count ? args[i] : nil
        case "--som": som = true
        default: if !args[i].hasPrefix("--") { path = args[i] }
        }
        i += 1
    }
    if som, appName == nil { fail("--som needs --app (overlays are per-window)") }
    var image: CGImage?
    var windowFrame = CGRect.zero
    var pid: pid_t?
    if let app = appName {
        guard let found = pidForApp(app) else { fail("app not found: \(app)") }
        pid = found
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let win = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 })
            ?? list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid })
        guard let win, let wid = win[kCGWindowNumber as String] as? Int else { fail("no on-screen window for \(app)") }
        let b = win[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        windowFrame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        image = scCapture(windowID: CGWindowID(wid))
    } else {
        image = scCapture(windowID: nil)
    }
    guard let cg = image else { fail("capture failed (screen recording permission?)") }
    var rep = NSBitmapImageRep(cgImage: cg)
    if som, let pid, let marked = somOverlay(cg, pid: pid, windowFrame: windowFrame) { rep = marked }
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("png encode failed") }
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail(error.localizedDescription) }
    ok(",\"path\":\(jsonString(path)),\"size\":[\(rep.pixelsWide),\(rep.pixelsHigh)]")

case "click", "doubleclick", "rightclick":
    // click [x y] | click --element N --app A [--method ax|coords]
    if args.count > 2, let x = Double(args[2]), args.count > 3, let y = Double(args[3]) {
        let button: CGMouseButton = args[1] == "rightclick" ? .right : .left
        clickAt(CGPoint(x: x, y: y), button: button, count: args[1] == "doubleclick" ? 2 : 1)
        ok(",\"at\":[\(Int(x)),\(Int(y))]")
        break
    }
    var elementIndex: Int?, appName: String?, method = "ax", modifierList = ""
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--element": i += 1; elementIndex = i < args.count ? Int(args[i]) : nil
        case "--app": i += 1; appName = i < args.count ? args[i] : nil
        case "--method": i += 1; method = i < args.count ? args[i] : "ax"
        case "--modifiers": i += 1; modifierList = i < args.count ? args[i] : ""
        default: break
        }
        i += 1
    }
    let modifiers = parseModifiers(modifierList)
    guard let n = elementIndex, let app = appName, let pid = pidForApp(app) else {
        fail("click needs x y, or --element N --app A")
    }
    let entries = collectElements(pid: pid)
    guard n >= 1, n <= entries.count else { fail("element \(n) out of range (1…\(entries.count))") }
    let entry = entries[n - 1]
    let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
    if method == "ax", entry.actions.contains("AXPress"), args[1] == "click" {
        let err = AXUIElementPerformAction(entry.element, "AXPress" as CFString)
        guard err == .success else { fail("AXPress failed: \(err.rawValue)") }
        ok(",\"method\":\"axpress\",\"on\":\(jsonString(elementJSON(entry)))")
    } else {
        let button: CGMouseButton = args[1] == "rightclick" ? .right : .left
        clickAt(center, button: button, count: args[1] == "doubleclick" ? 2 : 1, modifiers: modifiers)
        ok(",\"method\":\"coords\",\"on\":\(jsonString(elementJSON(entry)))")
    }

case "move":
    guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { fail("move <x> <y>") }
    postMouse(.mouseMoved, at: CGPoint(x: x, y: y))
    ok()

case "drag":
    guard args.count > 5, let x1 = Double(args[2]), let y1 = Double(args[3]),
          let x2 = Double(args[4]), let y2 = Double(args[5]) else { fail("drag <x1> <y1> <x2> <y2>") }
    let from = CGPoint(x: x1, y: y1), to = CGPoint(x: x2, y: y2)
    postMouse(.mouseMoved, at: from)
    usleep(180_000)
    postMouse(.leftMouseDown, at: from)
    usleep(120_000)
    for step in 1...10 {
        let p = CGPoint(x: from.x + (to.x - from.x) * CGFloat(step) / 10,
                        y: from.y + (to.y - from.y) * CGFloat(step) / 10)
        postMouse(.leftMouseDragged, at: p)
        usleep(16_000)
    }
    usleep(60_000)
    postMouse(.leftMouseUp, at: to)
    ok()

case "scroll":
    // scroll <ticks> [x y] — negative scrolls down; optional point targets the view under it
    let amount = args.count > 2 ? Int32(args[2]) ?? -3 : -3
    if args.count > 4, let x = Double(args[3]), let y = Double(args[4]) {
        postMouse(.mouseMoved, at: CGPoint(x: x, y: y))
        usleep(120_000)
    }
    let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
    event?.post(tap: .cghidEventTap)
    ok()

case "wait":
    // wait <seconds> | wait <app> --text "needle" [--timeout 15]
    if args.count > 2, let seconds = Double(args[2]) {
        Thread.sleep(forTimeInterval: max(0, min(seconds, 60)))
        ok()
        break
    }
    guard args.count > 4, args[3] == "--text", let pid = pidForApp(args[2]) else {
        fail("wait <seconds> | wait <app> --text \"needle\" [--timeout 15]")
    }
    let needle = args[4].lowercased()
    var timeout: Double = 15
    if args.count > 6, args[5] == "--timeout", let t = Double(args[6]) { timeout = min(t, 120) }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if collectElements(pid: pid).contains(where: { $0.label.lowercased().contains(needle) }) {
            ok(",\"found\":\(jsonString(args[4]))")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    fail("timeout waiting for \(jsonString(args[4]))", 4)

case "type":
    guard args.count > 2 else { fail("type <text>") }
    let text = args[2...].joined(separator: " ")
    guardTypeText(text)
    typeText(text)
    ok()

case "get":
    // get <app> <element N> [attribute] — read an AX attribute (default: value)
    guard args.count > 3, let pid = pidForApp(args[2]), let n = Int(args[3]) else { fail("get <app> <element> [attribute]") }
    let entries = collectElements(pid: pid)
    guard n >= 1, n <= entries.count else { fail("element \(n) out of range") }
    let attribute = args.count > 4 ? args[4] : kAXValueAttribute
    var ref: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(entries[n - 1].element, attribute as CFString, &ref)
    guard err == .success else { fail("read failed: \(err.rawValue)") }
    let text = (ref as? String) ?? (ref.map { String(describing: $0) } ?? "<nil>")
    print("{\"ok\":true,\"value\":\(jsonString(text))}")

case "set":
    // set <app> <element N> <text> — AX value write, no focus needed
    guard args.count > 4, let pid = pidForApp(args[2]), let n = Int(args[3]) else { fail("set <app> <element> <text>") }
    let entries = collectElements(pid: pid)
    guard n >= 1, n <= entries.count else { fail("element \(n) out of range") }
    let text = args[4...].joined(separator: " ")
    let err = AXUIElementSetAttributeValue(entries[n - 1].element, kAXValueAttribute as CFString, text as CFString)
    guard err == .success else { fail("AX set value failed: \(err.rawValue)") }
    ok()

case "key":
    guard args.count > 2, let code = keyCodes[args[2].lowercased()] else { fail("key <\(keyCodes.keys.sorted().joined(separator: "|"))>") }
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    ok()

case "hotkey":
    guard args.count > 2 else { fail("hotkey <cmd+shift+c>") }
    let parts = args[2].lowercased().split(separator: "+").map(String.init)
    var flags = CGEventFlags()
    var keyName = ""
    for part in parts {
        if let flag = flagFor(part) { flags.insert(flag) } else { keyName = part }
    }
    guard let code = keyCodes[keyName] else { fail("unknown key \(keyName)") }
    guardHotkey(flags, keyName)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(40_000)
    up?.post(tap: .cghidEventTap)
    ok()

case "pos":
    let p = NSEvent.mouseLocation
    let height = NSScreen.screens.first?.frame.height ?? 0
    ok(",\"x\":\(Int(p.x)),\"y\":\(Int(height - p.y)),\"space\":\"top-left\"")

default:
    fail("unknown command \(args[1])", 2)
}
