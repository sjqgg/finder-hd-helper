import AppKit

struct FinderContext: Equatable {
    let id: Int
    let path: String
}

struct FinderSnapshot {
    let context: FinderContext
    let rawPath: String
    let layout: String
}

/// All AppleScript execution is serialized by the controller's bridge queue.
enum FinderBridge {
    static func execute(_ source: String, timeout: Int = 5) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "with timeout of \(timeout) seconds\n" + source + "\nend timeout") else {
            throw ClearError.message("Finder 脚本创建失败")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "FinderBridge", code: error[NSAppleScript.errorNumber] as? Int ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Finder 连接失败"])
        }
        return result
    }
    static func connect() throws { _ = try execute("tell application \"Finder\" to get version", timeout: 120) }
    private static var appliedLayout: String?
    static func current() throws -> FinderSnapshot? {
        let result = try execute("""
        tell application "Finder"
            if not frontmost then return {}
            if (count of Finder windows) is 0 then return {}
            set w to front Finder window
            if current view of w is not icon view then return {}
            try
                set p to POSIX path of (target of w as alias)
                set b to bounds of w
                return {id of w, p, (item 3 of b) - (item 1 of b), sidebar width of w, icon size of icon view options of w}
            on error
                return {}
            end try
        end tell
        """)
        guard result.numberOfItems == 5, let path = result.atIndex(2)?.stringValue else { return nil }
        let context = FinderContext(id: Int(result.atIndex(1)!.int32Value), path: URL(fileURLWithPath: path).standardizedFileURL.path)
        let layout = "\(context.id)|\(path)|\(result.atIndex(3)!.int32Value)|\(result.atIndex(4)!.int32Value)|\(result.atIndex(5)!.int32Value)"
        return FinderSnapshot(context: context, rawPath: path, layout: layout)
    }
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func wrap(_ snapshot: FinderSnapshot) throws -> String {
        let context = snapshot.context
        let reflow = appliedLayout != snapshot.layout
        let result = try execute("""
        tell application "Finder"
            if not frontmost then return false
            if (count of Finder windows) is 0 then return false
            set w to front Finder window
            if id of w is not \(context.id) then return false
            if current view of w is not icon view then return false
            if (POSIX path of (target of w as alias)) is not \(literal(snapshot.rawPath)) then return false
            return true
        end tell
        """)
        guard result.booleanValue else { return "回到 Finder 后自动换行" }
        let status = try FinderSort.ensure()
        if reflow { writeDiagnostic(["layout": snapshot.layout, "result": status]) }
        appliedLayout = snapshot.layout
        return status
    }

    static func writeDiagnostic(_ value: [String: String]) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderClear/last-layout.json")
        var data = value
        data["date"] = ISO8601DateFormatter().string(from: Date())
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]) {
            try? encoded.write(to: support, options: .atomic)
        }
    }
}
