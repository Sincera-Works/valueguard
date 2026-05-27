import Foundation
import ValueGuard

let usage = """
Usage: valueguard --policy <policy.bin> [options]

  --policy <path>           Required. Path to compiled policy.bin.
  --rate <hz>               Sampling rate in Hz. Default 1.
  --log-only                Disable blur/block actions; log everything.

Window selection (per-window capture model):
  --monitor-apps a,b,c      Comma-separated app names to classify.
                            Default: Safari,Google Chrome,Firefox,Chromium,
                            Microsoft Edge,Brave Browser,Opera,Arc
  --greenlist a,b,c         Comma-separated app names to NEVER classify.
                            Appended to the built-in greenlist.
  --all-windows             Classify every visible window not in the greenlist.
                            Useful for smoke testing on a non-browser screen.

Audit log:
  --include-window-info     Include the foreground app name in each audit
                            entry. Off by default (window_id is logged either
                            way; the app name is gated as PII-adjacent).

Performance + debouncing:
  --no-hash-gate            Disable per-window hash skip. Default on.
  --hash-distance N         Hamming-distance threshold for "unchanged". Default 4.
  --hits N                  Hysteresis positive-hit count required to trigger. Default 3.
  --hysteresis-seconds S    Hysteresis time window. Default 10.
"""

struct Args {
    var policyPath: String?
    var rateHz: Double = 1.0
    var logOnly: Bool = false
    var monitorAppsCSV: String?
    var extraGreenlistCSV: String?
    var allWindows: Bool = false
    var includeWindowInfo: Bool = false
    var hashGate: Bool = true
    var hashDistance: Int = 4
    var hits: Int = 3
    var hysteresisSeconds: Double = 10
}

func parseArgs() -> Args {
    var args = Args()
    var iter = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--policy":              args.policyPath = iter.next()
        case "--rate":                if let v = iter.next(), let n = Double(v) { args.rateHz = n }
        case "--log-only":            args.logOnly = true
        case "--monitor-apps":        args.monitorAppsCSV = iter.next()
        case "--greenlist":           args.extraGreenlistCSV = iter.next()
        case "--all-windows":         args.allWindows = true
        case "--include-window-info": args.includeWindowInfo = true
        case "--no-hash-gate":        args.hashGate = false
        case "--hash-distance":       if let v = iter.next(), let n = Int(v) { args.hashDistance = n }
        case "--hits":                if let v = iter.next(), let n = Int(v) { args.hits = n }
        case "--hysteresis-seconds":  if let v = iter.next(), let n = Double(v) { args.hysteresisSeconds = n }
        case "-h", "--help":          print(usage); exit(0)
        default:
            FileHandle.standardError.write(Data("error: unknown argument \(arg)\n".utf8))
            FileHandle.standardError.write(Data(usage.utf8))
            exit(2)
        }
    }
    return args
}

let args = parseArgs()
guard let policyPath = args.policyPath else {
    FileHandle.standardError.write(Data("error: --policy is required\n".utf8))
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

func parseCSV(_ s: String?) -> [String] {
    guard let s = s else { return [] }
    return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

let filter: CaptureFilter
if args.allWindows {
    // --all-windows is the diagnostic / smoke-test mode: capture every visible
    // window, including the greenlist. For production use the default or an
    // explicit --monitor-apps list.
    filter = CaptureFilter(monitorApps: [], greenlistApps: parseCSV(args.extraGreenlistCSV))
} else if let csv = args.monitorAppsCSV {
    filter = CaptureFilter(
        monitorApps: parseCSV(csv),
        greenlistApps: CaptureFilter.defaultGreenlist + parseCSV(args.extraGreenlistCSV)
    )
} else {
    var f = CaptureFilter.browsersOnly
    f.greenlistApps += parseCSV(args.extraGreenlistCSV)
    filter = f
}

do {
    let daemon = try await ValueGuardDaemon(
        policyPath: policyPath,
        sampleRateHz: args.rateHz,
        logOnly: args.logOnly,
        filter: filter,
        includeWindowInfo: args.includeWindowInfo,
        hashGateEnabled: args.hashGate,
        hashDistanceThreshold: args.hashDistance,
        hysteresisRequired: args.hits,
        hysteresisSeconds: args.hysteresisSeconds
    )
    try await daemon.run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
