// Scroll direction selection, momentum filtering, and leading-edge throttling
// adapted from LinearMouse (MIT), Copyright (c) 2021-2026 LinearMouse.
// See LinearMouse-LICENSE.txt and THIRD-PARTY-NOTICES.md.
import CoreGraphics
import Foundation

struct WheelPolicy {
    enum Decision: Equatable { case pass, consume, zoom(Int) }
    private var lastAction: [Int: UInt64] = [:]
    mutating func reset() { lastAction.removeAll() }
    mutating func decide(flags: CGEventFlags, vertical: Double, horizontal: Double,
                         momentum: Bool, eligible: Bool, reversed: Bool,
                         now: UInt64) -> Decision {
        let modifiers: CGEventFlags = [.maskShift, .maskCommand, .maskControl, .maskAlternate]
        guard eligible, flags.intersection(modifiers) == .maskShift else { return .pass }
        guard !momentum else { return .consume }
        let axis = vertical != 0 ? 1 : 2
        let delta = axis == 1 ? vertical : horizontal
        guard delta.isFinite, delta != 0 else { return .pass }
        if let last = lastAction[axis], now >= last, now - last < 300_000_000 { return .consume }
        lastAction[axis] = now
        return .zoom((delta > 0 ? 1 : -1) * (reversed ? -1 : 1))
    }
}

func testWheelPolicy() throws {
    func check(_ condition: Bool, _ text: String) throws {
        guard condition else { throw ClearError.message("TEST FAILED: " + text) }
        print("PASS:", text)
    }
    var policy = WheelPolicy()
    func input(_ flags: CGEventFlags = .maskShift, _ y: Double = 1, _ x: Double = 0,
               _ momentum: Bool = false, _ eligible: Bool = true, _ reversed: Bool = false,
               _ time: UInt64 = 1_000_000_000) -> WheelPolicy.Decision {
        policy.decide(flags: flags, vertical: y, horizontal: x, momentum: momentum,
                      eligible: eligible, reversed: reversed, now: time)
    }
    try check(input([], 1) == .pass, "ordinary scrolling passes through")
    try check(input([.maskShift, .maskCommand]) == .pass, "other modifier shortcuts pass through")
    try check(input(.maskShift, 1, 0, false, false) == .pass, "other apps and non-icon targets pass through")
    try check(input() == .zoom(1), "wheel up enlarges")
    try check(input(.maskShift, 1, 0, false, true, false, 1_100_000_000) == .consume, "burst is throttled without horizontal scrolling")
    try check(input(.maskShift, -1, 0, false, true, false, 1_300_000_000) == .zoom(-1), "wheel down shrinks after interval")
    try check(input(.maskShift, 0, 1, false, true, false, 1_300_000_000) == .zoom(1), "Shift-remapped horizontal wheel is supported")
    try check(input(.maskShift, 1, 0, true, true, false, 2_000_000_000) == .consume, "inertial tail cannot change zoom")
    try check(input(.maskShift, 1, 0, false, true, true, 2_000_000_000) == .zoom(-1), "optional reversed direction works")
    try check(input(.maskShift, 0, 0) == .pass, "zero delta is ignored")
    policy.reset()
    try check(input(.maskShift, 0.25) == .zoom(1), "fractional trackpad deltas work after reset")
    print("WHEEL POLICY TESTS COMPLETE")
}
