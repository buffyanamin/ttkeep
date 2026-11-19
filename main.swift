// HoldColorTemp CLI — see Core.swift.
import Foundation
import CoreGraphics

var cfg = Config()
var args = Array(CommandLine.arguments.dropFirst())
func opt(_ key: String) -> Double? {
    guard let i = args.firstIndex(of: key), i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
    args.removeSubrange(i...i + 1); return v
}
if let v = opt("--gamma") { cfg.gamma = v }
if let v = opt("--interval") { cfg.interval = v }
if let v = opt("--settle") { cfg.settle = v }
let hold = opt("--hold") ?? 20

func cmdStatus() {
    log("lid: \(lidClosed().map { $0 ? "closed" : "open" } ?? "unknown")")
    guard let snap = readCoreBrightness() else { log("corebrightnessdiag: unavailable"); return }
    let saved = loadSaved()
    for d in externalDisplays() {
        log("\(d.name) [\(d.uuid.prefix(8))]")
        log("  True Tone now : \(snap.displays[d.uuid]?.text ?? "not active")")
        log("  saved         : \(saved[d.uuid]?.text ?? "none")")
        log("  table applied : \(readBack(d))")
    }
}

/// Visual test: apply the saved (or current) True Tone gains for `hold` seconds, then restore.
func cmdApply(hold: Double) {
    var gains = loadSaved()
    if let snap = readCoreBrightness(), !snap.clamshell {
        for (k, v) in snap.displays where v != .identity { gains[k] = v }   // prefer live values if True Tone is on
        save(gains)
    }
    let ds = externalDisplays()
    if ds.isEmpty { log("no external displays"); exit(1) }
    log(String(format: "applying True Tone gains (gamma %.2f) for %.0fs", cfg.gamma, hold))
    for d in ds {
        guard let g = gains[d.uuid] else { log("  \(d.name): no saved gains — run with True Tone on first"); continue }
        let ok = apply(g, to: d, gamma: cfg.gamma)
        log("  \(d.name): \(g.text) -> table \(readBack(d)) \(ok ? "" : "(set failed)")")
    }
    Thread.sleep(forTimeInterval: hold)
    CGDisplayRestoreColorSyncSettings()
    log("restored")
}

var sources: [DispatchSourceSignal] = []
func cmdRun() {
    let engine = Engine(cfg: cfg)
    engine.start()
    for s in [SIGTERM, SIGINT] {
        signal(s, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
        src.setEventHandler { engine.release(); CGDisplayRestoreColorSyncSettings(); log("stopped"); exit(0) }
        src.resume(); sources.append(src)
    }
    RunLoop.main.run()
}

switch args.first {
case "status": cmdStatus()
case "apply": cmdApply(hold: hold)
case "run": cmdRun()
default:
    print("""
    usage: holdcolortemp <command> [options]
      status                 lid state; per external display: live True Tone gains, saved gains, applied table
      apply [--hold s]       visual test: apply saved True Tone gains for s seconds (default 20), then restore
      run                    service: hold True Tone's colour on external displays while the lid is closed
    options: --gamma 2.2  --interval 5  --settle 10
    """)
}
