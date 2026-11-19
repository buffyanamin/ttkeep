// ttkeep menu bar app — see Core.swift for the engine.
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    let defaults = UserDefaults.standard
    var item: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["enabled": true, "intensity": 1.0])
        engine.enabled = defaults.bool(forKey: "enabled")
        engine.intensity = defaults.double(forKey: "intensity")

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        item.menu = menu
        engine.onChange = { [weak self] in self?.updateIcon() }
        engine.start()
        updateIcon()

        // Re-check promptly on wake (the timer may be stale).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.engine.tick(force: true) }
        }
    }

    func applicationWillTerminate(_ n: Notification) { engine.release(); CGDisplayRestoreColorSyncSettings() }

    // MARK: icon
    func updateIcon() {
        let source = engine.phase == .tracking && !engine.live.isEmpty ? engine.live : engine.held
        let ks = externalDisplays().compactMap { source[$0.uuid]?.kelvin }
        let kelvin = ks.isEmpty ? nil : ks.reduce(0, +) / Double(ks.count)
        let kText = kelvin.map { String(format: " ~%.0fK", $0) } ?? ""
        let tip: String = switch engine.phase {
        case .holding:  "ttkeep: holding True Tone colour\(kText) (lid closed)"
        case .tracking: "ttkeep: following True Tone\(kText) (lid open)"
        case .paused:   "ttkeep: paused"
        case .starting: "ttkeep"
        }
        item.button?.image = Self.icon(phase: engine.phase, kelvin: kelvin)
        item.button?.toolTip = tip
    }

    /// Warm tint for a colour temperature: pale yellow near 6500K -> deep amber at ~4000K.
    static func warmColor(_ kelvin: Double?) -> NSColor {
        let t = CGFloat(min(max((6500 - (kelvin ?? 5300)) / 2500, 0), 1))
        let pale = NSColor(srgbRed: 1.00, green: 0.88, blue: 0.45, alpha: 1)
        let deep = NSColor(srgbRed: 1.00, green: 0.50, blue: 0.05, alpha: 1)
        return pale.blended(withFraction: t, of: deep) ?? deep
    }

    /// Colour menu bar icon: a monitor whose screen glows with the held/live True Tone colour.
    static func icon(phase: Engine.Phase, kelvin: Double?) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let fg = NSColor.labelColor          // resolved at draw time -> adapts to light/dark menu bar
            let screen = NSRect(x: 2, y: 5.5, width: 16, height: 11)
            let body = NSBezierPath(roundedRect: screen, xRadius: 2.5, yRadius: 2.5)

            // screen fill
            let warm = warmColor(kelvin)
            switch phase {
            case .holding:
                NSGradient(starting: warm.blended(withFraction: 0.25, of: .white) ?? warm, ending: warm)?.draw(in: body, angle: -90)
            case .tracking, .starting:
                NSGradient(starting: warm.withAlphaComponent(0.35), ending: warm.withAlphaComponent(0.75))?.draw(in: body, angle: -90)
            case .paused:
                NSColor.systemGray.withAlphaComponent(0.25).setFill(); body.fill()
            }

            // bezel + stand
            fg.withAlphaComponent(phase == .paused ? 0.45 : 0.9).setStroke()
            body.lineWidth = 1.4; body.stroke()
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 10, y: 5.5)); stand.line(to: NSPoint(x: 10, y: 3))
            stand.move(to: NSPoint(x: 6.5, y: 2.3)); stand.line(to: NSPoint(x: 13.5, y: 2.3))
            stand.lineWidth = 1.4; stand.lineCapStyle = .round; stand.stroke()

            // holding: small sun badge so "locked to True Tone" reads at a glance
            if phase == .holding {
                let c = NSPoint(x: 14.5, y: 13.5)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2)).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2))
                ring.lineWidth = 0.8; ring.stroke()
            }
            // paused: diagonal slash
            if phase == .paused {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3, y: 16)); slash.line(to: NSPoint(x: 17, y: 3))
                slash.lineWidth = 1.6; slash.lineCapStyle = .round
                NSColor.systemRed.withAlphaComponent(0.85).setStroke(); slash.stroke()
            }
            return true
        }
        img.isTemplate = false   // keep the colour
        return img
    }

    // MARK: menu (rebuilt every time it opens, so it's always current)
    func menuNeedsUpdate(_ menu: NSMenu) {
        engine.tick()
        menu.removeAllItems()

        let status: String = switch engine.phase {
        case .holding:  "Lid closed — holding True Tone colour"
        case .tracking: "Lid open — following True Tone"
        case .paused:   "Paused — external displays neutral"
        case .starting: "Starting…"
        }
        menu.addItem(header(status))

        let displays = externalDisplays()
        if displays.isEmpty { menu.addItem(info("No external displays")) }
        for d in displays {
            let saved = engine.held[d.uuid]
            var line = "\(d.name):  \(saved?.kelvinText ?? "not captured yet")"
            if engine.phase == .tracking, let l = engine.live[d.uuid] { line = "\(d.name):  \(l.kelvinText) (live)" }
            if engine.phase == .tracking, engine.live[d.uuid] == nil || engine.live[d.uuid] == .identity {
                line += "  — True Tone off?"
            }
            menu.addItem(info(line))
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Keep True Tone Colour", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = engine.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        let strength = NSMenuItem(title: "Strength", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, v) in [("Lighter (50%)", 0.5), ("Lighter (75%)", 0.75), ("Same as True Tone", 1.0), ("Stronger (125%)", 1.25), ("Stronger (150%)", 1.5)] {
            let i = NSMenuItem(title: title, action: #selector(setIntensity(_:)), keyEquivalent: "")
            i.representedObject = v; i.target = self
            i.state = abs(engine.intensity - v) < 0.01 ? .on : .off
            sub.addItem(i)
        }
        strength.submenu = sub
        menu.addItem(strength)

        let preview = NSMenuItem(title: "Preview Held Colour (10 s)", action: #selector(previewHeld), keyEquivalent: "")
        preview.target = self
        preview.toolTip = "Turn True Tone off first, then compare with how it looked with True Tone on."
        preview.isEnabled = engine.phase != .holding
        menu.addItem(preview)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        let displaysPrefs = NSMenuItem(title: "Display Settings…", action: #selector(openDisplaySettings), keyEquivalent: "")
        displaysPrefs.target = self
        menu.addItem(displaysPrefs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ttkeep", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func header(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        i.isEnabled = false
        return i
    }
    func info(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; i.indentationLevel = 1; return i
    }

    // MARK: actions
    @objc func toggleEnabled() {
        engine.enabled.toggle()
        defaults.set(engine.enabled, forKey: "enabled")
    }
    @objc func setIntensity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        engine.intensity = v
        defaults.set(v, forKey: "intensity")
    }
    @objc func previewHeld() { engine.preview(seconds: 10) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = "\(error.localizedDescription)\n\nMove ttkeep.app to ~/Applications or /Applications and try again, or add it in System Settings → General → Login Items."
            a.runModal()
        }
    }
    @objc func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
}

@main
enum TTKeepApp {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}
