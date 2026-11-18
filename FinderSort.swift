import AppKit
import ApplicationServices

/// Finder's legacy AppleScript arrangement property can report 'nama' while
/// the live Sort By menu is still None. Read and operate the actual menu.
enum FinderSort {
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    static func title(_ element: AXUIElement) -> String {
        value(element, kAXTitleAttribute) as? String ?? ""
    }
    static func menuItems(_ element: AXUIElement) -> [AXUIElement] {
        let direct = children(element)
        return direct.flatMap { child -> [AXUIElement] in
            if value(child, kAXRoleAttribute) as? String == kAXMenuRole { return children(child) }
            return [child]
        }
    }
    static func descendant(_ element: AXUIElement, depth: Int = 7,
                           matching: (AXUIElement) -> Bool) -> AXUIElement? {
        if matching(element) { return element }
        guard depth > 0 else { return nil }
        for child in children(element) {
            if let found = descendant(child, depth: depth - 1, matching: matching) { return found }
        }
        return nil
    }
    static func size(_ element: AXUIElement) -> CGSize? {
        guard let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &result) else { return nil }
        return result
    }
    /// Use the live AX cell and viewport sizes, rather than Finder's cached
    /// AppleScript view options, so a single oversized icon cannot be clipped.
    static func fitToWindow(_ application: AXUIElement) throws -> Bool {
        guard let rawWindow = value(application, kAXFocusedWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        guard let viewport = descendant(window, matching: { element in
            value(element, kAXRoleAttribute) as? String == kAXScrollAreaRole &&
            children(element).contains { value($0, kAXIdentifierAttribute) as? String == "IconView" }
        }), let view = children(viewport).first(where: { value($0, kAXIdentifierAttribute) as? String == "IconView" }),
              let item = descendant(view, depth: 4, matching: { value($0, kAXRoleAttribute) as? String == kAXImageRole }),
              let available = size(viewport), let cell = size(item), available.width > 0,
              cell.width > available.width - 24 else { return false }
        guard let slider = descendant(window, matching: { value($0, kAXRoleAttribute) as? String == kAXSliderRole }),
              let current = value(slider, kAXValueAttribute) as? NSNumber else { return false }
        let minimum = (value(slider, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
        let next = max(minimum, current.doubleValue - 8)
        guard next < current.doubleValue else { return false }
        let result = AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: next))
        guard result == .success else { throw ClearError.message("无法调整缩略图以适应窗口") }
        FinderBridge.writeDiagnostic(["result": "正在适配单张图片宽度", "cellWidth": "\(cell.width)",
                                      "viewportWidth": "\(available.width)", "slider": "\(next)"])
        return true
    }
    static func ensure() throws -> String {
        guard trusted else { return "自动换行需要开启助手的辅助功能权限" }
        guard let finder = NSWorkspace.shared.frontmostApplication,
              finder.bundleIdentifier == "com.apple.finder" else { return "回到 Finder 后自动换行" }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let rawBar = value(application, kAXMenuBarAttribute),
              CFGetTypeID(rawBar) == AXUIElementGetTypeID() else {
            throw ClearError.message("无法读取 Finder 菜单")
        }
        let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
        guard let view = children(bar).first(where: { ["显示", "顯示", "View"].contains(title($0)) }),
              let sort = menuItems(view).first(where: { ["排序方式", "排序方式：", "排序方式:", "Sort By"].contains(title($0)) }) else {
            throw ClearError.message("未找到 Finder 排序菜单")
        }
        let choices = menuItems(sort)
        guard let name = choices.first(where: { ["名称", "名稱", "Name"].contains(title($0)) }) else {
            throw ClearError.message("未找到按名称排序选项")
        }
        let selected = choices.first { !(value($0, kAXMenuItemMarkCharAttribute) as? String ?? "").isEmpty }
        let free: Set<String> = ["无", "無", "None", "吸附到网格", "貼齊格線", "对齐网格", "Snap to Grid"]
        if let selected, !free.contains(title(selected)) {
            if try fitToWindow(application) { return "正在适配窗口宽度" }
            return "自动换行已启用（\(title(selected))）"
        }
        guard AXUIElementPerformAction(name, kAXPressAction as CFString) == .success else {
            throw ClearError.message("Finder 未接受自动排序，请关闭弹出菜单后重试")
        }
        return "已设置按名称自动换行"
    }
}
