import Foundation
import ValueGuard

let usage = """
Usage: valueguard --policy <policy.bin> [--rate <hz>] [--log-only]

  --policy   Path to compiled policy.bin (from model-conversion/embed_captions.py)
  --rate     Sampling rate in Hz. Default 1.
  --log-only Disable blur/block actions; log everything. Recommended for v1.
"""

struct Args {
    var policyPath: String?
    var rateHz: Double = 1.0
    var logOnly: Bool = false
}

func parseArgs() -> Args {
    var args = Args()
    var iter = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--policy":
            args.policyPath = iter.next()
        case "--rate":
            if let v = iter.next(), let n = Double(v) { args.rateHz = n }
        case "--log-only":
            args.logOnly = true
        case "-h", "--help":
            print(usage)
            exit(0)
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

do {
    let daemon = try await ValueGuardDaemon(
        policyPath: policyPath,
        sampleRateHz: args.rateHz,
        logOnly: args.logOnly
    )
    try await daemon.run()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error)\n".utf8))
    exit(1)
}
