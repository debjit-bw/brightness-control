// BrightnessKeys — route the Mac's native brightness keys to the external
// monitor (over DDC/CI) whenever the mouse cursor is on that monitor.

import AppKit
import CoreGraphics
import IOKit
import ServiceManagement

func log(_ s: String) { FileHandle.standardError.write("[BrightnessKeys] \(s)\n".data(using: .utf8)!) }

// MARK: - DDC over IOAVService (Apple Silicon)

private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private let rtld = dlopen(nil, RTLD_NOW)
private let avCreate = unsafeBitCast(dlsym(rtld, "IOAVServiceCreateWithService"), to: AVCreate.self)
private let avWrite = unsafeBitCast(dlsym(rtld, "IOAVServiceWriteI2C"), to: AVI2C.self)
private let avRead = unsafeBitCast(dlsym(rtld, "IOAVServiceReadI2C"), to: AVI2C.self)

final class DDCDisplay {
    let displayID: CGDirectDisplayID
    let name: String
    private let service: CFTypeRef
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Int?          // latest value waiting to be written (coalesces key repeats)
    var maxValue = 100
    var current = 50                   // cached, in 0...maxValue

    init(displayID: CGDirectDisplayID, name: String, service: CFTypeRef) {
        self.displayID = displayID
        self.name = name
        self.service = service
        self.queue = DispatchQueue(label: "ddc.\(displayID)")
    }

    private static let addr: UInt32 = 0x37, sub: UInt32 = 0x51

    private func send(_ payload: [UInt8]) -> Bool {
        var pkt = [0x80 | UInt8(payload.count)] + payload
        pkt.append(pkt.reduce(0x6E ^ 0x51, ^))
        return avWrite(service, Self.addr, Self.sub, &pkt, UInt32(pkt.count)) == kIOReturnSuccess
    }

    /// Synchronously read VCP 0x10 (luminance). Call off the main thread.
    func readBrightness() -> (cur: Int, max: Int)? {
        for _ in 0..<4 {
            guard send([0x01, 0x10]) else { usleep(20_000); continue }
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 12)
            guard avRead(service, Self.addr, Self.sub, &r, 12) == kIOReturnSuccess else { continue }
            let chk = r[0..<10].reduce(0x50, ^)
            if r[2] == 0x02, r[3] == 0x00, r[4] == 0x10, chk == r[10] {
                return (Int(r[8]) << 8 | Int(r[9]), max(1, Int(r[6]) << 8 | Int(r[7])))
            }
            usleep(30_000)
        }
        return nil
    }

    func refresh(completion: @escaping () -> Void = {}) {
        queue.async {
            if let v = self.readBrightness() {
                DispatchQueue.main.async { self.current = v.cur; self.maxValue = v.max; completion() }
            } else {
                log("could not read brightness from \(self.name)")
            }
        }
    }

    /// Fire-and-forget write; rapid calls collapse to the latest value.
    func set(_ value: Int) {
        current = value
        lock.lock()
        let needsDrain = pending == nil
        pending = value
        lock.unlock()
        guard needsDrain else { return }
        queue.async {
            self.lock.lock()
            let v = self.pending
            self.pending = nil
            self.lock.unlock()
            guard let v else { return }
            _ = self.send([0x03, 0x10, UInt8(v >> 8), UInt8(v & 0xFF)])
            usleep(30_000)
        }
    }
}

// MARK: - Map CGDisplays to DCPAVServiceProxy services

private func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// Walks the IOService plane. Each external framebuffer (AppleCLCD2 / IOMobileFramebufferShim)
/// is followed in the tree by its DCPAVServiceProxy — pair them up (same trick MonitorControl uses).
func discoverDDCDisplays() -> [DDCDisplay] {
    struct FB { var vendor: Int?, product: Int?, serial: Int?, name: String? }
    var pairs: [(FB, io_service_t)] = []
    var lastFB: FB?

    var iter: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                        IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    while case let e = IOIteratorNext(iter), e != 0 {
        var cls = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(e, &cls)
        let c = String(cString: cls)
        if c == "AppleCLCD2" || c == "IOMobileFramebufferShim" {
            if let attrs = prop(e, "DisplayAttributes") as? [String: Any],
               let p = attrs["ProductAttributes"] as? [String: Any] {
                lastFB = FB(vendor: p["LegacyManufacturerID"] as? Int, product: p["ProductID"] as? Int,
                            serial: p["SerialNumber"] as? Int, name: p["ProductName"] as? String)
            }
            IOObjectRelease(e)
        } else if c == "DCPAVServiceProxy", (prop(e, "Location") as? String) == "External", let fb = lastFB {
            pairs.append((fb, e)); lastFB = nil
        } else {
            IOObjectRelease(e)
        }
    }

    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    var externals = ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

    var result: [DDCDisplay] = []
    for (fb, svc) in pairs {
        defer { IOObjectRelease(svc) }
        let match = externals.firstIndex { id in
            fb.vendor.map { CGDisplayVendorNumber(id) == UInt32(truncatingIfNeeded: $0) } == true
                && fb.product.map { CGDisplayModelNumber(id) == UInt32(truncatingIfNeeded: $0) } == true
                && (fb.serial == nil || fb.serial == 0 || CGDisplaySerialNumber(id) == UInt32(truncatingIfNeeded: fb.serial!))
        } ?? (pairs.count == 1 && externals.count == 1 ? 0 : nil)
        guard let i = match, let av = avCreate(kCFAllocatorDefault, svc)?.takeRetainedValue() else { continue }
        let id = externals.remove(at: i)
        result.append(DDCDisplay(displayID: id, name: fb.name ?? "Display \(id)", service: av))
    }
    return result
}

// MARK: - Native brightness OSD (private OSD.framework, best effort)

enum OSD {
    private static let manager: NSObject? = {
        guard Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework")?.load() == true,
              let cls = NSClassFromString("OSDManager") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }()

    private typealias ShowFn = @convention(c) (NSObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    static func show(fraction: Double, on display: CGDirectDisplayID) {
        let sel = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard let m = manager, let method = class_getInstanceMethod(type(of: m), sel) else { return }
        let fn = unsafeBitCast(method_getImplementation(method), to: ShowFn.self)
        let total: UInt32 = 64
        fn(m, sel, 1 /* brightness icon */, display, 0x1F4, 1000, UInt32((fraction * Double(total)).rounded()), total, false)
    }
}

// MARK: - Key interception

private let NX_KEYTYPE_BRIGHTNESS_UP: Int = 2
private let NX_KEYTYPE_BRIGHTNESS_DOWN: Int = 3
private let kVK_BrightnessUp: Int64 = 144     // some keyboards send these as plain key events
private let kVK_BrightnessDown: Int64 = 145

final class App: NSObject, NSApplicationDelegate {
    var displays: [DDCDisplay] = []
    var tap: CFMachPort?
    var statusItem: NSStatusItem!
    var statusLabel: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenu()
        rescan()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let app = Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue()
            NSObject.cancelPreviousPerformRequests(withTarget: app, selector: #selector(App.rescan), object: nil)
            app.perform(#selector(App.rescan), with: nil, afterDelay: 1.5)
        }, Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(rescan),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        startTap()
    }

    @objc func rescan() {
        displays = discoverDDCDisplays()
        log("DDC displays: " + (displays.map { "\($0.name) (id \($0.displayID))" }.joined(separator: ", ").nilIfEmpty ?? "none"))
        for d in displays { d.refresh { self.updateMenu() } }
        updateMenu()
    }

    // MARK: event tap

    func startTap() {
        let mask: CGEventMask = (1 << 14 /* NSSystemDefined */) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, ctx in
            let app = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = app.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return app.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("event tap failed — waiting for Accessibility permission")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            statusLabel.title = "⚠︎ Grant Accessibility access in System Settings"
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
                if AXIsProcessTrusted() { timer.invalidate(); self.startTap(); self.updateMenu() }
            }
            return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("listening for brightness keys")
    }

    /// Returns true to swallow the event.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        var up: Bool, isDown: Bool
        if type.rawValue == 14 {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let key = (ns.data1 & 0xFFFF_0000) >> 16
            guard key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN else { return false }
            up = key == NX_KEYTYPE_BRIGHTNESS_UP
            isDown = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        } else {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard kc == kVK_BrightnessUp || kc == kVK_BrightnessDown else { return false }
            up = kc == kVK_BrightnessUp
            isDown = type == .keyDown
        }
        guard let d = displayUnderCursor() else { return false }   // built-in: let macOS handle it
        if isDown {
            // Option+Shift = fine steps (1/4 notch), like macOS.
            let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
            let step = Double(d.maxValue) / 16.0 / (fine ? 4 : 1)
            let target = Double(d.current) + (up ? step : -step)
            let snapped = fine ? target : (target / step).rounded() * step
            let v = Int(min(Double(d.maxValue), max(0, snapped)).rounded())
            d.set(v)
            OSD.show(fraction: Double(v) / Double(d.maxValue), on: d.displayID)
            updateMenu()
        }
        return true
    }

    func displayUnderCursor() -> DDCDisplay? {
        guard let loc = CGEvent(source: nil)?.location else { return nil }  // global top-left coords
        var id: CGDirectDisplayID = 0; var count: UInt32 = 0
        CGGetDisplaysWithPoint(loc, 1, &id, &count)
        guard count > 0 else { return nil }
        return displays.first { $0.displayID == id || CGDisplayMirrorsDisplay(id) == $0.displayID }
    }

    // MARK: menu bar

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "BrightnessKeys")
        let menu = NSMenu()
        statusLabel = NSMenuItem(title: "Scanning…", action: nil, keyEquivalent: "")
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rescan Displays", action: #selector(rescan), keyEquivalent: "r").target = self
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func updateMenu() {
        guard tap != nil else { return }
        statusLabel.title = displays.isEmpty ? "No DDC-capable external display"
            : displays.map { "\($0.name): \(Int((Double($0.current) / Double($0.maxValue) * 100).rounded()))%" }.joined(separator: "\n")
    }

    @objc func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("launch-at-login failed: \(error)") }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
