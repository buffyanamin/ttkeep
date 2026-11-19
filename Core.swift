// ttkeep core — keep True Tone's colour on external displays after the MacBook lid closes.
//
// While the lid is open, True Tone (CoreBrightness) applies a per-display colour matrix that
// `/usr/libexec/corebrightnessdiag status-info` reports. We snapshot each display's white gains
// from it; when the lid closes and True Tone stops, we re-create those gains on the external
// displays via the display transfer table, and hand back to True Tone when the lid opens.
import Foundation
import CoreGraphics
import ColorSync
import IOKit

// MARK: config
struct Config {
    var gamma = 2.2       // True Tone gains are linear-light; transfer table works on encoded values
    var interval = 5.0    // seconds between ticks
    var settle = 10.0     // ignore snapshots taken this close to the lid-close moment
}

let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ttkeep")
let stateFile = stateDir.appendingPathComponent("gains.json")

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(s)"); fflush(stdout)
}

// MARK: model
struct Gains: Codable, Equatable {
    var r, g, b: Double
    var kelvin: Double?          // approx CCT of True Tone's white point target, for display only
    static let identity = Gains(r: 1, g: 1, b: 1, kelvin: nil)
    var text: String { String(format: "R=%.3f G=%.3f B=%.3f", r, g, b) + (kelvin.map { String(format: " (~%.0fK)", $0) } ?? "") }
    var kelvinText: String { kelvin.map { String(format: "~%.0fK", $0) } ?? (self == .identity ? "neutral" : "—") }
    /// Linear-light gains -> encoded-value multipliers for the transfer table.
    func encoded(_ gamma: Double) -> Gains { Gains(r: pow(r, 1 / gamma), g: pow(g, 1 / gamma), b: pow(b, 1 / gamma), kelvin: kelvin) }
    /// Scale the deviation from neutral: 1 = as True Tone, 0 = neutral, >1 = stronger.
    func scaled(_ k: Double) -> Gains {
        func s(_ v: Double) -> Double { min(max(1 - k * (1 - v), 0.3), 1) }
        return Gains(r: s(r), g: s(g), b: s(b), kelvin: kelvin)
    }
}

struct Snapshot {
    var clamshell: Bool
    var displays: [String: Gains]        // UUID -> gains (identity if True Tone disabled for it)
}

// MARK: CoreBrightness snapshot
func mccamy(_ x: Double, _ y: Double) -> Double {
    let n = (x - 0.3320) / (0.1858 - y)
    return 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
}

func readCoreBrightness() -> Snapshot? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/libexec/corebrightnessdiag")
    p.arguments = ["status-info"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
    var snap = Snapshot(clamshell: root["CBClamshellState"] as? Bool ?? false, displays: [:])
    for (uuid, v) in root["CBDisplays"] as? [String: Any] ?? [:] {
        guard let cm = (v as? [String: Any])?["ColorModule"] as? [String: Any] else { continue }
        let enabled = cm["ColorAdaptationEnabled"] as? Bool ?? false
        let active = cm["ColorAdaptationActive"] as? Bool ?? false
        if !enabled { snap.displays[uuid.uppercased()] = .identity; continue }
        guard active,
              let ramp = cm["ColorRamp"] as? [String: Any],
              let m = ramp["ColorRampTarget"] as? [Double], m.count == 9 else { continue }
        var g = Gains(r: m[0] + m[1] + m[2], g: m[3] + m[4] + m[5], b: m[6] + m[7] + m[8], kelvin: nil)
        let mx = max(g.r, g.g, g.b); g.r /= mx; g.g /= mx; g.b /= mx
        if let wp = ramp["ColorRampWhitePointTarget"] as? [Double], wp.count == 2 { g.kelvin = mccamy(wp[0], wp[1]) }
        snap.displays[uuid.uppercased()] = g
    }
    return snap
}

// MARK: lid (public IOKit)
func lidClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}

// MARK: displays
struct Display { let id: CGDirectDisplayID; let uuid: String; let name: String }

/// Product name from IOKit (e.g. "DELL U2723QX"), matched by vendor/model; falls back to resolution.
func productName(_ id: CGDirectDisplayID) -> String {
    let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &it) == KERN_SUCCESS else {
        return "Display \(CGDisplayPixelsWide(id))×\(CGDisplayPixelsHigh(id))"
    }
    defer { IOObjectRelease(it) }
    var fallback: String?
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        guard let attrs = IORegistryEntryCreateCFProperty(s, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let p = attrs["ProductAttributes"] as? [String: Any],
              let name = p["ProductName"] as? String,
              (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor,
              (p["ProductID"] as? NSNumber)?.uint32Value == model else { continue }
        if (p["SerialNumber"] as? NSNumber)?.uint32Value == serial { return name }
        fallback = name
    }
    return fallback ?? "Display \(CGDisplayPixelsWide(id))×\(CGDisplayPixelsHigh(id))"
}

func externalDisplays() -> [Display] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n))
        .filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        .compactMap { id in
            guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let s = CFUUIDCreateString(nil, u) as String? else { return nil }
            return Display(id: id, uuid: s.uppercased(), name: productName(id))
        }
}

@discardableResult
func apply(_ g: Gains, to d: Display, gamma: Double) -> Bool {
    let e = g.encoded(gamma)
    return CGSetDisplayTransferByFormula(d.id, 0, Float(e.r), 1, 0, Float(e.g), 1, 0, Float(e.b), 1) == .success
}

func readBack(_ d: Display) -> String {
    var a: Float = 0, r: Float = 0, b: Float = 0, c: Float = 0, g: Float = 0, e: Float = 0, f: Float = 0, bl: Float = 0, h: Float = 0
    guard CGGetDisplayTransferByFormula(d.id, &a, &r, &b, &c, &g, &e, &f, &bl, &h) == .success else { return "?" }
    return String(format: "R=%.3f G=%.3f B=%.3f", r, g, bl)
}

// MARK: persistence
func loadSaved() -> [String: Gains] {
    guard let d = try? Data(contentsOf: stateFile) else { return [:] }
    return (try? JSONDecoder().decode([String: Gains].self, from: d)) ?? [:]
}
func save(_ g: [String: Gains]) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(g) { try? d.write(to: stateFile, options: .atomic) }
}

// MARK: engine
/// Polls lid + True Tone state; holds True Tone's colour on external displays while the lid is closed.
final class Engine {
    enum Phase: Equatable { case starting, tracking, holding, paused }

    var cfg: Config
    var enabled = true { didSet { if !enabled { release() }; tick(force: true) } }
    var intensity = 1.0 { didSet { tick(force: true) } }
    var onChange: (() -> Void)?

    private(set) var phase: Phase = .starting
    private(set) var held: [String: Gains] = loadSaved()
    private(set) var live: [String: Gains] = [:]
    private(set) var lid: Bool? = nil
    private var history: [(Date, [String: Gains])] = []
    private var applying = false
    private var timer: Timer?

    init(cfg: Config = Config()) { self.cfg = cfg }

    private var openedAt: Date?

    /// Most recent snapshot taken at least `settle` seconds before `t`, and at least `settle` seconds
    /// after the lid opened (True Tone re-settles after reopening). No fallback to fresher snapshots.
    private func settled(before t: Date) -> [String: Gains]? {
        guard let opened = openedAt else { return nil }
        return history.last {
            $0.0 <= t.addingTimeInterval(-cfg.settle) && $0.0 >= opened.addingTimeInterval(cfg.settle)
        }?.1
    }

    /// True when the last three snapshots agree (True Tone isn't mid-transition).
    private var stable: Bool {
        guard history.count >= 3 else { return false }
        let last = history.suffix(3).map(\.1)
        return last.allSatisfy { snap in
            snap.keys == last[0].keys && snap.allSatisfy { k, g in
                guard let r = last[0][k] else { return false }
                return abs(g.r - r.r) < 0.01 && abs(g.g - r.g) < 0.01 && abs(g.b - r.b) < 0.01
            }
        }
    }

    func release() {
        if applying { CGDisplayRestoreColorSyncSettings(); applying = false }
    }

    func tick(force: Bool = false) {
        defer { onChange?() }
        guard let closed = lidClosed() else { return }
        let wasLid = lid
        lid = closed
        if !closed {
            if applying { release(); log("lid open -> restored external displays, True Tone in charge") }
            if wasLid != false { openedAt = Date(); history.removeAll() }
            if let snap = readCoreBrightness(), !snap.clamshell, !snap.displays.isEmpty {
                live = snap.displays
                history.append((Date(), snap.displays))
                history.removeAll { $0.0 < Date().addingTimeInterval(-120) }
                if stable, let s = settled(before: Date()) {
                    var merged = held; merged.merge(s) { $1 }
                    if merged != held { held = merged; save(held) }
                }
            }
            phase = enabled ? .tracking : .paused
            return
        }
        live = [:]
        if wasLid == false, let s = settled(before: Date()) { held.merge(s) { $1 }; save(held) }
        guard enabled else { phase = .paused; return }
        let first = !applying || force
        for d in externalDisplays() {
            guard let g = held[d.uuid] else { if first { log("\(d.name): no saved gains, leaving untouched") }; continue }
            if g == .identity { continue }
            let s = g.scaled(intensity)
            if !apply(s, to: d, gamma: cfg.gamma) { log("\(d.name): set failed") }
            else if first { log("lid closed -> \(d.name): \(s.text)") }
        }
        applying = true      // re-applied every tick: covers sleep/wake and anything that resets the tables
        phase = .holding
    }

    func start() {
        log(String(format: "ttkeep started: gamma=%.2f interval=%.0fs settle=%.0fs", cfg.gamma, cfg.interval, cfg.settle))
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            if flags.contains(.beginConfigurationFlag) { return }
            let e = Unmanaged<Engine>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { e.tick(force: true) }
        }, Unmanaged.passUnretained(self).toOpaque())
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: cfg.interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Temporarily apply held gains (for comparing against True Tone with it switched off).
    func preview(seconds: Double) {
        for d in externalDisplays() { if let g = held[d.uuid], g != .identity { apply(g.scaled(intensity), to: d, gamma: cfg.gamma) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if self.phase != .holding { CGDisplayRestoreColorSyncSettings() }
            self.tick(force: true)
        }
    }
}
