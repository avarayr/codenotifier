import AppKit
import Carbon
import Darwin
import Foundation
import SwiftUI

struct Cfg {
    let title: String
    let subtitle: String
    let message: String
    let actions: [String]
    let roles: [Role]
    let timeout: Double
    let icon: String?
    let tone: Tone
    let sound: String?
}

enum Tone: String, CaseIterable {
    case info
    case success
    case warn
    case danger
    case neutral

    var tint: Color {
        switch self {
        case .info:
            Color(red: 0.18, green: 0.38, blue: 1)
        case .success:
            Color(red: 0.2, green: 0.74, blue: 0.45)
        case .warn:
            Color(red: 0.96, green: 0.66, blue: 0.2)
        case .danger:
            Color(red: 0.94, green: 0.34, blue: 0.34)
        case .neutral:
            Color(red: 0.56, green: 0.62, blue: 0.72)
        }
    }
}

enum Role: String {
    case primary
    case defaultAction = "default"
    case secondary
    case cancel
    case destructive
    case success
    case warn
    case info
    case neutral

    var fill: Color? {
        switch self {
        case .primary, .defaultAction, .success, .warn, .info, .neutral, .destructive:
            color
        case .secondary, .cancel:
            nil
        }
    }

    var color: Color {
        switch self {
        case .primary, .defaultAction, .info:
            Tone.info.tint
        case .success:
            Tone.success.tint
        case .warn:
            Tone.warn.tint
        case .destructive:
            Tone.danger.tint
        case .neutral, .cancel, .secondary:
            Tone.neutral.tint
        }
    }

    var text: Color {
        switch self {
        case .cancel, .secondary:
            .white.opacity(0.92)
        case .primary, .defaultAction, .success, .warn, .info, .neutral, .destructive:
            .white
        }
    }

    var edge: Color {
        switch self {
        case .cancel, .secondary:
            .white.opacity(0.1)
        case .primary, .defaultAction, .success, .warn, .info, .neutral, .destructive:
            .white.opacity(0.06)
        }
    }
}

struct Entry: Codable {
    let id: String
    let pid: Int32
    let stamp: TimeInterval
    let screen: String
    let height: Double
}

struct Store: Codable {
    var items: [Entry]
}

func val(_ key: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func flag(_ key: String) -> Bool {
    CommandLine.arguments.contains(key)
}

func tone(_ raw: String?) -> Tone {
    guard let raw else { return .info }
    return Tone(rawValue: raw.lowercased()) ?? .info
}

func sound(_ key: String) -> String? {
    if !flag(key) { return nil }
    let raw = val(key)
    if raw?.hasPrefix("--") == true { return "Glass" }
    return raw ?? "Glass"
}

func roles(_ raw: String?, _ count: Int) -> [Role] {
    let vals = raw?
        .split(separator: ",")
        .map { Role(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        .compactMap { $0 } ?? []
    return (0..<count).map { i in
        if i < vals.count { return vals[i] }
        return i == 0 ? .primary : .secondary
    }
}

func help() {
    let text = """
    codenotifier

    --title TEXT
    --subtitle TEXT
    --message TEXT
    --actions "Open,Later"
    --roles "primary,cancel"
    --timeout SECONDS
    --icon PATH
    --tone info|success|warn|danger|neutral
    --sound [NAME]
    """
    print(text)
}



let cfg = {
    if flag("--help") {
        help()
        exit(0)
    }

    let title = val("--title") ?? "OpenCode"
    let subtitle = val("--subtitle") ?? "Custom toast"
    let message = val("--message") ?? "This is a custom SwiftUI toast."
    let actions = (val("--actions") ?? "Open,Later")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let timeout = Double(val("--timeout") ?? "8") ?? 8
    let icon = val("--icon") ?? "/Applications/OpenCode.app/Contents/Resources/icon.icns"
    let tone = tone(val("--tone"))
    let mapped = roles(val("--roles"), actions.count).map { role in
        if role == .primary || role == .defaultAction {
            return tone == .info ? role : Role(rawValue: tone.rawValue) ?? role
        }
        return role
    }
    return Cfg(
        title: title,
        subtitle: subtitle,
        message: message,
        actions: actions,
        roles: mapped,
        timeout: timeout,
        icon: icon,
        tone: tone,
        sound: sound("--sound")
    )
}()

final class Registry {
    let dir: URL
    let file: URL
    let lock: URL
    let id = UUID().uuidString
    let pid = getpid()
    var screen = "main"
    var height = 150.0

    init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/codenotifier", isDirectory: true)
        file = dir.appendingPathComponent("stack.json")
        lock = dir.appendingPathComponent("stack.lock")
    }

    func prepare() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data(#"{"items":[]}"#.utf8).write(to: file)
        }
        if !FileManager.default.fileExists(atPath: lock.path) {
            FileManager.default.createFile(atPath: lock.path, contents: Data())
        }
    }

    func update(screen: String, height: CGFloat) {
        self.screen = screen
        self.height = height
        _ = edit { store in
            let live = clean(store.items).filter { $0.id != id }
            let item = Entry(
                id: id,
                pid: pid,
                stamp: Date().timeIntervalSince1970,
                screen: screen,
                height: height,
            )
            return Store(items: live + [item])
        }
    }

    func remove() {
        _ = edit { store in
            Store(items: clean(store.items).filter { $0.id != id })
        }
    }

    func slot() -> Int {
        read()
            .items
            .filter { $0.screen == screen }
            .sorted { a, b in
                if a.stamp == b.stamp { return a.id < b.id }
                return a.stamp < b.stamp
            }
            .firstIndex { $0.id == id } ?? 0
    }

    func read() -> Store {
        prepare()
        return withLock {
            let data = (try? Data(contentsOf: file)) ?? Data(#"{"items":[]}"#.utf8)
            let store = (try? JSONDecoder().decode(Store.self, from: data)) ?? Store(items: [])
            let next = Store(items: clean(store.items))
            if next.items.count != store.items.count, let data = try? JSONEncoder().encode(next) {
                try? data.write(to: file, options: .atomic)
            }
            return next
        }
    }

    func edit(_ body: (Store) -> Store) -> Store {
        prepare()
        return withLock {
            let data = (try? Data(contentsOf: file)) ?? Data(#"{"items":[]}"#.utf8)
            let store = (try? JSONDecoder().decode(Store.self, from: data)) ?? Store(items: [])
            let next = body(Store(items: clean(store.items)))
            if let data = try? JSONEncoder().encode(next) {
                try? data.write(to: file, options: .atomic)
            }
            return next
        }
    }

    func clean(_ items: [Entry]) -> [Entry] {
        items.filter { item in
            if item.pid == pid { return true }
            if kill(item.pid, 0) == 0 { return true }
            return errno == EPERM
        }
    }

    func withLock<T>(_ body: () -> T) -> T {
        prepare()
        let fd = open(lock.path, O_RDWR)
        flock(fd, LOCK_EX)
        let out = body()
        flock(fd, LOCK_UN)
        close(fd)
        return out
    }
}

final class Box: ObservableObject {
    let cfg: Cfg
    let icon: NSImage?
    let reg = Registry()

    @Published var live = false
    @Published var over = false

    weak var panel: NSPanel?
    var mon: Any?
    var timer: Timer?
    var done = false
    var base = NSPoint.zero

    init(cfg: Cfg) {
        self.cfg = cfg
        if let path = cfg.icon, FileManager.default.fileExists(atPath: path) {
            icon = NSImage(contentsOfFile: path)
        } else {
            icon = nil
        }
    }

    func bind(_ panel: NSPanel, _ screen: NSScreen) {
        self.panel = panel
        base = point(panel, screen, 0)
        reg.update(screen: key(screen), height: panel.frame.height)
        move(false)
        play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tick()
        }
        mon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.tick()
        }
    }

    func play() {
        guard let name = cfg.sound else { return }
        if let snd = NSSound(named: NSSound.Name(name)) {
            snd.play()
            return
        }
        let path = "/System/Library/Sounds/\(name).aiff"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    func point(_ panel: NSPanel, _ screen: NSScreen, _ slot: Int) -> NSPoint {
        let frame = screen.visibleFrame
        let x = frame.maxX - panel.frame.width - 18
        let y = frame.maxY - panel.frame.height - 16 - CGFloat(slot) * (panel.frame.height + 12)
        return NSPoint(x: x, y: y)
    }

    func key(_ screen: NSScreen) -> String {
        let f = screen.visibleFrame
        return "\(Int(f.minX)):\(Int(f.minY)):\(Int(f.width)):\(Int(f.height))"
    }

    func tick() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? panel.screen
            ?? NSScreen.main
        guard let screen else { return }
        reg.update(screen: key(screen), height: panel.frame.height)
        move(true)
    }

    func move(_ anim: Bool) {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let screen else { return }
        let next = point(panel, screen, reg.slot())
        if abs(panel.frame.minY - next.y) < 1 && abs(panel.frame.minX - next.x) < 1 { return }
        if !anim {
            panel.setFrameOrigin(next)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(next)
        }
    }

    func quit(_ out: String) {
        if done { return }
        done = true
        timer?.invalidate()
        timer = nil
        if let mon {
            NSEvent.removeMonitor(mon)
            self.mon = nil
        }
        reg.remove()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel?.animator().alphaValue = 0
            if let panel {
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY + 10))
            }
            live = false
        } completionHandler: {
            print(out)
            NSApp.terminate(nil)
        }
    }
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct Hover: ViewModifier {
    let on: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onHover(perform: on)
    }
}

struct GlassEffectView: NSViewRepresentable {
    let variant: Int
    var cornerRadius: CGFloat? = nil
    
    func makeNSView(context: Context) -> NSView {
        guard let CustomClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else {
            return NSView()
        }
        let view = CustomClass.init()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        if let r = cornerRadius {
            view.layer?.cornerRadius = r
            view.layer?.cornerCurve = .continuous
        }
        updateNSView(view, context: context)
        return view
    }
    
    func updateNSView(_ view: NSView, context: Context) {
        let sel = Selector(("set_variant:"))
        if view.responds(to: sel) {
            typealias SetVariantFn = @convention(c) (AnyObject, Selector, Int) -> Void
            if let imp = view.method(for: sel) {
                let callable = unsafeBitCast(imp, to: SetVariantFn.self)
                callable(view, sel, variant)
            }
        }
        if let r = cornerRadius {
            view.layer?.cornerRadius = r
        }
    }
}

struct FallbackCard: View {
    let bodyView: AnyView

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }

            Blur()
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            bodyView
        }
    }
}

struct Panel: View {
    @ObservedObject var box: Box

    var body: some View {
        let bodyView = AnyView(
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    icon

                    VStack(alignment: .leading, spacing: 3) {
                        Text(box.cfg.title)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.96))
                            .lineLimit(1)

                        if !box.cfg.subtitle.isEmpty {
                            Text(box.cfg.subtitle)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 3)

                    Spacer(minLength: 6)
                    close
                }

                Text(box.cfg.message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !box.cfg.actions.isEmpty {
                    row
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 344, alignment: .leading)
        )

        Group {
            if #available(macOS 26.0, *) {
                bodyView
                    .background {
                        ZStack {
                            GlassEffectView(variant: 9, cornerRadius: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(Color.black.opacity(0.15))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                    }
            } else {
                FallbackCard(bodyView: bodyView)
            }
        }
        .compositingGroup()
        .scaleEffect(box.live ? 1 : 0.96, anchor: .topTrailing)
        .opacity(box.live ? 1 : 0)
        .offset(y: box.live ? 0 : -12)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: box.live)
    }

    var icon: some View {
        Group {
            if let icon = box.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: 42, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 0.8)
        }
    }

    var close: some View {
        Button {
            box.quit("@dismiss")
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(box.over ? 0.9 : 0.7))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.white.opacity(box.over ? 0.1 : 0.04))
        )
        .overlay {
            Circle()
                .stroke(Color.white.opacity(box.over ? 0.12 : 0.06), lineWidth: 0.8)
        }
        .modifier(Hover { box.over = $0 })
        .animation(.easeInOut(duration: 0.14), value: box.over)
    }

    var row: some View {
        HStack(spacing: 8) {
            ForEach(box.cfg.actions.indices, id: \.self) { i in
                pill(i)
            }
        }
    }

    func role(_ i: Int) -> Role {
        if i < box.cfg.roles.count { return box.cfg.roles[i] }
        return i == 0 ? .primary : .secondary
    }

    func pill(_ i: Int) -> some View {
        let role = role(i)
        let fill = role.fill
        return Button(action: {
            box.quit(box.cfg.actions[i])
        }) {
            HStack(spacing: 4) {
                if i < 9 {
                    Text("⌘\(i + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(role.text.opacity(0.7))
                }
                Text(box.cfg.actions[i])
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .foregroundStyle(role.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            if #available(macOS 26.0, *), fill == nil {
                GlassEffectView(variant: 9, cornerRadius: 15)
                    .clipShape(Capsule())
            } else if let fill {
                Capsule()
                    .fill(fill.opacity(role == .cancel || role == .secondary ? 0.12 : 0.94))
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.08))
            }
        }
        .overlay {
            Capsule()
                .stroke(role.edge, lineWidth: 0.8)
        }
    }
}

final class App: NSObject, NSApplicationDelegate {
    let box = Box(cfg: cfg)

    func applicationDidFinishLaunching(_ note: Notification) {
        let root = Panel(box: box)
        let host = NSHostingView(rootView: root)
        host.layoutSubtreeIfNeeded()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 168),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = host
        panel.orderFrontRegardless()

        let size = host.fittingSize
        panel.setContentSize(NSSize(width: max(320, size.width), height: max(138, size.height)))

        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            box.bind(panel, screen)
        }

        panel.alphaValue = 1

        DispatchQueue.main.async { [self] in
            self.box.live = true
        }

        if box.cfg.timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + box.cfg.timeout) { [self] in
                if NSApp.isRunning {
                    self.box.quit("@timeout")
                }
            }
        }
        
        registerHotKeys()
    }

    func registerHotKeys() {
        let hotKeyHandler: EventHandlerUPP = { _, theEvent, _ in
            var hkCom: EventHotKeyID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkCom)
            
            let actionIndex = Int(hkCom.id)
            if actionIndex >= 0 && actionIndex < delegate.box.cfg.actions.count {
                delegate.box.quit(delegate.box.cfg.actions[actionIndex])
            }
            return noErr
        }
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)
        
        // Keycodes for 1, 2, 3, 4, 5, 6, 7, 8, 9
        let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        
        for i in 0..<box.cfg.actions.count {
            if i < keyCodes.count {
                var hotKeyRef: EventHotKeyRef?
                let hotKeyID = EventHotKeyID(signature: OSType(0x484F544B), id: UInt32(i))
                RegisterEventHotKey(keyCodes[i], UInt32(cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        box.reg.remove()
    }
}

let app = NSApplication.shared
let delegate = App()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
