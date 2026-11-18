// Event-tap lifecycle and scroll interpretation adapted from LinearMouse (MIT).
// Copyright (c) 2021-2026 LinearMouse. See bundled third-party notices.
import AppKit
import ApplicationServices

/// A main-run-loop scroll tap. The callback only reads cached state and queues
/// work; all potentially blocking Finder accessibility calls use the bridge queue.
final class FinderWheel {
    struct Target {
        let context: FinderContext
        let pid: pid_t
        let window: AXUIElement
        let slider: AXUIElement
        let viewport: CGRect
        let capturedAt: UInt64

        static func capture(context: FinderContext) -> Target? {
            guard FinderSort.trusted,
                  let finder = NSWorkspace.shared.frontmostApplication,
                  finder.bundleIdentifier == "com.apple.finder" else { return nil }
            let app = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.3)
            guard let raw = FinderSort.value(app, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let window = unsafeBitCast(raw, to: AXUIElement.self)
            guard FinderSort.value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  FinderSort.children(window).allSatisfy({ FinderSort.value($0, kAXRoleAttribute) as? String != kAXSheetRole }) else { return nil }
            if let rawFocus = FinderSort.value(app, kAXFocusedUIElementAttribute), CFGetTypeID(rawFocus) == AXUIElementGetTypeID() {
                let focus = unsafeBitCast(rawFocus, to: AXUIElement.self)
                let role = FinderSort.value(focus, kAXRoleAttribute) as? String ?? ""
                if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return nil }
            }
            guard let viewport = FinderSort.descendant(window, matching: { element in
                FinderSort.value(element, kAXRoleAttribute) as? String == kAXScrollAreaRole &&
                FinderSort.children(element).contains { FinderSort.value($0, kAXIdentifierAttribute) as? String == "IconView" }
            }), let size = FinderSort.size(viewport), size.width > 0,
                  let rawPosition = FinderSort.value(viewport, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  let slider = FinderSort.descendant(window, matching: { FinderSort.value($0, kAXRoleAttribute) as? String == kAXSliderRole }) else { return nil }
            var origin = CGPoint.zero
            guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &origin),
                  FinderSort.value(slider, kAXValueAttribute) is NSNumber else { return nil }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(slider, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return nil }
            return Target(context: context, pid: finder.processIdentifier, window: window, slider: slider,
                          viewport: CGRect(origin: origin, size: size), capturedAt: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private let queue: DispatchQueue
    private let statusChanged: (String) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var target: Target?
    private var policy = WheelPolicy()
    private var enabled = false
    private var reversed = false
    private var frontPID: pid_t = 0
    private var busy = false
    private var pending = 0
    private var generation = 0
    private var retryAfter: UInt64 = 0
    private var lastStatus = ""
    var isReady: Bool { enabled && tap != nil }

    init(queue: DispatchQueue, statusChanged: @escaping (String) -> Void) {
        self.queue = queue; self.statusChanged = statusChanged
    }
    private func report(_ text: String) {
        guard lastStatus != text else { return }
        lastStatus = text; statusChanged(text)
    }
    func updateTarget(_ newTarget: Target?) {
        if target?.context != newTarget?.context || target?.pid != newTarget?.pid || (target != nil && newTarget != nil && !CFEqual(target!.window, newTarget!.window)) {
            pending = 0; generation += 1; policy.reset()
        }
        target = newTarget
    }
    func refresh(enabled requested: Bool, reversed: Bool, linearMouseRunning: Bool) {
        self.reversed = reversed
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if target?.pid != frontPID { updateTarget(nil) }
        enabled = requested && FinderSort.trusted && !linearMouseRunning
        guard enabled else {
            stop()
            report(!requested ? "滚轮缩放已关闭" : (!FinderSort.trusted ? "滚轮缩放需要辅助功能权限" : "LinearMouse 运行中，内置缩放暂未接管"))
            return
        }
        if let tap, !CFMachPortIsValid(tap) { stop() }
        if tap == nil {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= retryAfter else { return }
            retryAfter = now + 3_000_000_000
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<FinderWheel>.fromOpaque(refcon).takeUnretainedValue().receive(type, event)
            }
            guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                report("滚轮监听未启动，请重新开启辅助功能权限"); return
            }
            tap = created
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        report("内置 Shift＋滚轮缩放已启用")
    }
    func stop() {
        updateTarget(nil); pending = 0
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let now = DispatchTime.now().uptimeNanoseconds
        let eligible = enabled && target.map {
            $0.pid == frontPID && now >= $0.capturedAt && now - $0.capturedAt < 1_500_000_000 && $0.viewport.contains(event.location)
        } == true
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let y = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let x = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let decision = policy.decide(flags: event.flags, vertical: y, horizontal: x,
            momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0,
            eligible: eligible, reversed: reversed, now: now)
        switch decision {
        case .pass: return Unmanaged.passUnretained(event)
        case .consume: return nil
        case .zoom(let direction):
            pending = max(-3, min(3, pending + direction)); flush()
            return nil
        }
    }
    private func flush() {
        guard enabled, !busy, pending != 0, let target else { return }
        let steps = pending, token = generation
        pending = 0; busy = true
        queue.async {
            var message: String?
            // Re-resolve the live window, icon view and editable controls just before writing.
            let allowed = DispatchQueue.main.sync { self.enabled && token == self.generation }
            if allowed, let currentContext = try? FinderBridge.current()?.context, currentContext == target.context,
               let live = Target.capture(context: currentContext), live.pid == target.pid, CFEqual(live.window, target.window),
               let current = FinderSort.value(live.slider, kAXValueAttribute) as? NSNumber {
                let low = (FinderSort.value(live.slider, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
                let high = (FinderSort.value(live.slider, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 112
                let next = min(high, max(low, current.doubleValue + Double(steps) * 8))
                if AXUIElementSetAttributeValue(live.slider, kAXValueAttribute as CFString, NSNumber(value: next)) == .success {
                    self.diagnostic(["result": "zoom applied", "before": "\(current.doubleValue)", "after": "\(next)", "steps": "\(steps)"])
                } else { message = "Finder 暂未接受缩放，请回到图标视图重试" }
            }
            DispatchQueue.main.async {
                self.busy = false
                if let message { self.report(message) }
                guard token == self.generation else { self.pending = 0; return }
                self.flush()
            }
        }
    }
    private func diagnostic(_ value: [String: String]) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderClear/last-wheel.json")
        var record = value; record["date"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) { try? data.write(to: url, options: .atomic) }
    }
}
