import AppKit
import SwiftUI
import ServiceManagement

final class Controller: NSObject, ObservableObject, NSApplicationDelegate {
    @Published var status = "正在连接 Finder…"
    @Published var folder = ""
    @Published var connected = false
    @Published var needsAccessibility = !FinderSort.trusted
    @Published var layoutStatus = ""
    @Published var wheelStatus = ""
    @Published var zoom = UserDefaults.standard.object(forKey: "zoom") as? Bool ?? true
    @Published var reverseZoom = UserDefaults.standard.bool(forKey: "reverseZoom")
    @Published var hd = UserDefaults.standard.object(forKey: "hd") as? Bool ?? true
    @Published var wrap = UserDefaults.standard.object(forKey: "wrap") as? Bool ?? true
    @Published var login = SMAppService.mainApp.status == .enabled
    private var excluded = Set(UserDefaults.standard.stringArray(forKey: "excluded") ?? [])
    private let bridge = DispatchQueue(label: "local.finderclear.bridge", qos: .utility)
    private lazy var wheel = FinderWheel(queue: bridge) { [weak self] status in
        self?.wheelStatus = status; self?.menu()
    }
    private let worker = DispatchQueue(label: "local.finderclear.icons", qos: .utility)
    private let cancelLock = NSLock()
    private var epoch = 0
    private var active: FinderContext?
    private var last: FinderContext?
    private var lastScan = Date.distantPast
    private var processing = false
    private var querying = false
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var store: IconStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FinderClear/IconBackups", isDirectory: true)
            store = try IconStore(directory: support)
        } catch { status = "无法创建恢复记录：\(error.localizedDescription)"; showPanel(); return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Finder 高清助手")
        statusItem.button?.toolTip = "Finder 高清助手：滚轮缩放、高清预览与自动换行"
        menu()
        let first = !UserDefaults.standard.bool(forKey: "hasLaunched")
        if first { showPanel(); UserDefaults.standard.set(true, forKey: "hasLaunched") }
        connect()
        let pollingTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(pollingTimer, forMode: .common)
        timer = pollingTimer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated),
                name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPanel(); return true }
    func applicationWillTerminate(_ notification: Notification) { wheel.stop(); invalidate(); timer?.invalidate() }
    func invalidate() { cancelLock.lock(); epoch += 1; cancelLock.unlock() }
    func token() -> Int { cancelLock.lock(); defer { cancelLock.unlock() }; return epoch }
    func cancelled(_ token: Int) -> Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return token != epoch }
    @objc func activated() { tick() }

    @objc func connect() {
        guard !querying else { return }
        querying = true; status = "请在系统提示中允许控制 Finder"; menu()
        bridge.async {
            let result = Result { try FinderBridge.connect() }
            DispatchQueue.main.async {
                self.querying = false
                switch result {
                case .success: self.connected = true; self.status = "已就绪：在 Finder 中打开图片文件夹，按 ⌘1"; self.tick()
                case .failure(let error): self.connected = false; self.status = "尚未连接 Finder：\(error.localizedDescription)"
                }
                self.menu()
            }
        }
    }
    @objc func openAutomation() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
    func requestAccessibility() {
        FinderSort.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func setHD(_ value: Bool) { hd = value; UserDefaults.standard.set(value, forKey: "hd"); settingsChanged() }
    func setWrap(_ value: Bool) { wrap = value; UserDefaults.standard.set(value, forKey: "wrap"); settingsChanged() }
    func setZoom(_ value: Bool) { zoom = value; UserDefaults.standard.set(value, forKey: "zoom"); settingsChanged() }
    func setReverseZoom(_ value: Bool) { reverseZoom = value; UserDefaults.standard.set(value, forKey: "reverseZoom"); settingsChanged() }
    func settingsChanged() { invalidate(); lastScan = .distantPast; menu(); tick() }
    @objc func toggleHD() { setHD(!hd) }
    @objc func toggleWrap() { setWrap(!wrap) }
    @objc func toggleZoom() { setZoom(!zoom) }
    @objc func returnToFinder() {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" })?
            .activate(options: [])
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            login = SMAppService.mainApp.status == .enabled
            if value && !login { status = "请在登录项设置中允许 Finder 高清助手启动"; SMAppService.openSystemSettingsLoginItems() }
        } catch { login = SMAppService.mainApp.status == .enabled; status = "登录启动设置失败：\(error.localizedDescription)" }
    }
    func tick() {
        guard store != nil else { return }
        needsAccessibility = !FinderSort.trusted
        let linearMouseRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.lujjjh.LinearMouse" }
        wheel.refresh(enabled: zoom, reversed: reverseZoom, linearMouseRunning: linearMouseRunning)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            if active != nil { invalidate(); active = nil }
            return
        }
        guard connected, !querying, hd || wrap || zoom else { return }
        querying = true
        let arrange = wrap
        let captureZoom = wheel.isReady
        bridge.async {
            let result = Result { () throws -> FinderContext? in
                guard let snapshot = try FinderBridge.current() else {
                    DispatchQueue.main.async { self.wheel.updateTarget(nil) }
                    return nil
                }
                if arrange {
                    do {
                        let message = try FinderBridge.wrap(snapshot)
                        DispatchQueue.main.async { self.layoutStatus = message }
                    } catch {
                        let message = "自动换行暂不可用：\(error.localizedDescription)"
                        FinderBridge.writeDiagnostic(["error": message])
                        DispatchQueue.main.async { self.layoutStatus = message }
                    }
                }
                let zoomTarget = captureZoom ? FinderWheel.Target.capture(context: snapshot.context) : nil
                DispatchQueue.main.async { self.wheel.updateTarget(zoomTarget) }
                return snapshot.context
            }
            DispatchQueue.main.async {
                self.querying = false
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
                switch result {
                case .failure(let error):
                    self.wheel.updateTarget(nil)
                    FinderBridge.writeDiagnostic(["error": error.localizedDescription])
                    self.invalidate(); self.active = nil
                    if (error as NSError).code == -1743 { self.connected = false }
                    self.status = "Finder 连接暂不可用：\(error.localizedDescription)"; self.menu()
                case .success(nil):
                    if self.active != nil { self.invalidate(); self.active = nil }
                    self.status = "在 Finder 图片文件夹中按 ⌘1，使用图标视图"; self.menu()
                case .success(let context?):
                    if self.active != context { self.invalidate(); self.active = context; self.lastScan = .distantPast }
                    self.last = context; self.folder = context.path
                    guard !self.processing, Date().timeIntervalSince(self.lastScan) >= 8 else { return }
                    self.lastScan = Date(); self.scan(context)
                }
            }
        }
    }
    func scan(_ context: FinderContext) {
        let isExcluded = excluded.contains(context.path)
        let token = self.token(), makeHD = hd && !isExcluded, arrange = wrap
        processing = true
        worker.async {
            var changed = 0, ready = 0, skipped = 0, errors = 0
            var detail: String?
            do {
                let files = try self.store.images(in: URL(fileURLWithPath: context.path))
                if makeHD {
                    for (index, file) in files.enumerated() {
                        if self.cancelled(token) { break }
                        do {
                            switch try self.store.apply(file, cancelled: { self.cancelled(token) }) {
                            case .applied: changed += 1
                            case .current: ready += 1
                            case .skipped: skipped += 1
                            }
                        } catch { errors += 1; detail = error.localizedDescription }
                        let processed = index + 1
                        DispatchQueue.main.async {
                            guard !self.cancelled(token) else { return }
                            self.status = "正在生成高清图标 \(processed)/\(files.count)"; self.menu()
                        }
                    }
                }
                let final: String
                if files.isEmpty { final = "当前文件夹没有支持的本地图片" }
                else if !makeHD { final = isExcluded ? "此文件夹已暂停高清预览" : (arrange ? "自动换行已启用" : "滚轮缩放已启用") }
                else {
                    final = "高清预览 \(changed + ready) 张" + (skipped > 0 ? " · 保留已有图标 \(skipped) 张" : "")
                        + (errors > 0 ? " · \(errors) 张未完成：\(detail ?? "")" : "")
                }
                DispatchQueue.main.async {
                    self.processing = false
                    guard !self.cancelled(token) else { self.tick(); return }
                    self.status = final; self.menu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.processing = false
                    if !self.cancelled(token) { self.status = "无法读取文件夹：\(error.localizedDescription)"; self.menu() }
                }
            }
        }
    }
    @objc func retryFolder() {
        guard let last else { return }
        excluded.remove(last.path); UserDefaults.standard.set(Array(excluded), forKey: "excluded")
        lastScan = .distantPast; status = "已启用，回到该 Finder 文件夹即可继续"; menu()
    }
    @objc func restoreFolder() {
        guard let context = last else { return }
        invalidate(); excluded.insert(context.path); UserDefaults.standard.set(Array(excluded), forKey: "excluded")
        status = "正在恢复原有预览…"; menu()
        worker.async {
            var count = 0, failures = 0
            do {
                for file in try self.store.ownedFiles(in: URL(fileURLWithPath: context.path)) {
                    do { if try self.store.restore(file) { count += 1 } } catch { failures += 1 }
                }
                let text = "已恢复 \(count) 张，此文件夹已暂停高清预览" + (failures > 0 ? "；\(failures) 张有外部变更，恢复记录已保留" : "")
                DispatchQueue.main.async { self.status = text; self.menu() }
            } catch { DispatchQueue.main.async { self.status = error.localizedDescription; self.menu() } }
        }
    }
    @objc func revealBackups() { NSWorkspace.shared.open(store.directory) }
    @objc func quit() { NSApp.terminate(nil) }
    func item(_ title: String, _ action: Selector?, on: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }
    func menu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        menu.addItem(item("Finder 高清助手", nil))
        menu.addItem(item(String(status.prefix(65)), nil)); menu.addItem(.separator())
        if !layoutStatus.isEmpty { menu.addItem(item(String(layoutStatus.prefix(65)), nil)) }
        if !wheelStatus.isEmpty { menu.addItem(item(wheelStatus, nil)) }
        menu.addItem(item("Shift＋滚轮缩放", #selector(toggleZoom), on: zoom))
        menu.addItem(item("自动生成高清预览", #selector(toggleHD), on: hd))
        menu.addItem(item("按窗口宽度自动换行", #selector(toggleWrap), on: wrap))
        menu.addItem(item("控制面板…", #selector(showPanel)))
        if let last {
            menu.addItem(.separator())
            menu.addItem(item("当前：" + URL(fileURLWithPath: last.path).lastPathComponent, nil))
            menu.addItem(item("恢复此文件夹的原有预览", #selector(restoreFolder)))
            menu.addItem(item("重新启用此文件夹的高清预览", #selector(retryFolder)))
        }
        menu.addItem(.separator()); menu.addItem(item("退出", #selector(quit)))
        statusItem.menu = menu
    }
    @objc func showPanel() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 550),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Finder 高清助手"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ControlPanel(model: self)); w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finder 高清助手").font(.title2.bold())
                    Text("滚轮缩放 · 高清预览 · 自动换行").foregroundStyle(.secondary)
                }
            }
            Text("在 Finder 打开图片文件夹，按 ⌘1。\n按住 Shift 滚动滚轮，调整缩略图大小。")
            Divider()
            Toggle("Shift＋滚轮缩放", isOn: Binding(get: { model.zoom }, set: model.setZoom))
            if model.zoom {
                Toggle("反转缩放方向", isOn: Binding(get: { model.reverseZoom }, set: model.setReverseZoom)).font(.callout)
            }
            Toggle("自动生成高清预览", isOn: Binding(get: { model.hd }, set: model.setHD))
            Toggle("按窗口宽度自动换行", isOn: Binding(get: { model.wrap }, set: model.setWrap))
            Toggle("登录时启动", isOn: Binding(get: { model.login }, set: model.setLogin))
            if model.needsAccessibility && (model.wrap || model.zoom) {
                Button("开启辅助功能，启用缩放和换行", action: model.requestAccessibility)
            }
            Text("从原图生成 Finder 图标，保留图片比例。只保存可撤销的图标属性，照片画面和 EXIF 不变。已有自定义图标会保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !model.layoutStatus.isEmpty { Text(model.layoutStatus).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if !model.wheelStatus.isEmpty { Text(model.wheelStatus).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if !model.folder.isEmpty { Text(model.folder).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if !model.connected {
                    Button("连接 Finder", action: model.connect)
                    Button("权限设置", action: model.openAutomation)
                } else {
                    Button("恢复此文件夹的预览", action: model.restoreFolder).disabled(model.folder.isEmpty)
                    Button("查看恢复记录", action: model.revealBackups)
                }
                Spacer()
                Button("返回 Finder", action: model.returnToFinder)
            }
        }.padding(24).frame(width: 460)
    }
}

func selfTest(source: String, root: String) throws {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let sample = base.appendingPathComponent("sample.jpg")
    try fm.copyItem(at: URL(fileURLWithPath: source), to: sample)
    let store = try IconStore(directory: base.appendingPathComponent("records"))
    let original = try Data(contentsOf: sample), info = try Attributes.read(sample.path, Attributes.finderInfo)
    let fork = try Attributes.read(sample.path, Attributes.resourceFork)
    func check(_ value: Bool, _ text: String) throws { guard value else { throw ClearError.message("TEST FAILED: " + text) }; print("PASS:", text) }
    try check(try store.apply(sample, cancelled: { true }) == .skipped, "cancellation before writes")
    try check(try Attributes.read(sample.path, Attributes.resourceFork) == fork, "cancel leaves attributes unchanged")
    try check(try store.apply(sample) == .applied, "generate high quality custom icon")
    try check(Attributes.custom(try Attributes.read(sample.path, Attributes.finderInfo)), "custom icon flag verified")
    try check(digest(try Data(contentsOf: sample)) == digest(original), "entire photo and EXIF byte-identical")
    try check(try store.apply(sample) == .current, "repeat is idempotent")
    let otherStore = try IconStore(directory: base.appendingPathComponent("other-records"))
    try check(try otherStore.apply(sample) == .skipped, "existing user icons preserved")
    try check(try store.restore(sample), "undo succeeds")
    try check(try Attributes.read(sample.path, Attributes.resourceFork) == fork, "original resource fork restored")
    try check(try Attributes.read(sample.path, Attributes.finderInfo) == info, "original FinderInfo restored")
    try check(digest(try Data(contentsOf: sample)) == digest(original), "photo byte-identical after undo")
    print("SELF TEST COMPLETE")
}

if CommandLine.arguments.contains("--self-test-wheel") {
    do { try testWheelPolicy(); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--self-test" {
    do { try selfTest(source: CommandLine.arguments[2], root: CommandLine.arguments[3]); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
