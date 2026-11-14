// R+ fork: on-disk copy of IntelligenceEngine's per-night score cache (`dayScanCache`).
//
// Why: the cache lived in memory only. iOS kills NOOP overnight, so the morning sync always ran in a fresh
// process and re-scored all 21 nights from raw (5 to 19 min CPU on this phone). In the background iOS
// suspends that pass after ~30 s and the partial work is lost, so the Sleep tab stayed on "calculating".
// With this copy the cold pass reuses every unchanged night and only scores the new one (seconds).
// The same applies to DayCycleIntelligenceIntegration.Cache (per-cycle steps/Effort), the second cold cost.
//
// Safety: a separate file in Library/Caches, never the database, never in a .noopbak. It holds only
// scan results that the cache would have reused anyway, keyed by the same per-day key and config
// signature, plus a build stamp so a different app binary never reads results from older scoring code.
// Any read problem (missing, purged by iOS, other build, decode error) means "no cache" = the original
// full re-score. Nothing here writes to WhoopStore.

import Foundation
import MachO

enum RPADayCacheStore {
    static let dayScanFile = "rpa-dayScanCache.v1.plist"
    static let dayCycleFile = "rpa-dayCycleCache.v1.plist"

    private struct Envelope<Payload: Codable>: Codable {
        let format: Int
        let build: String
        let configSig: String
        let payload: Payload
    }

    private static func fileURL(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(name)
    }

    /// LC_UUIDs of every image loaded from inside the app bundle (main executable, debug dylib, frameworks).
    /// Changes when the code changes, not when the weekly re-sign only re-signs.
    static let buildStamp: String = {
        let bundlePath = Bundle.main.bundlePath
        var uuids: [String] = []
        for i in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(i), let header = _dyld_get_image_header(i) else { continue }
            let path = String(cString: cName)
            guard path.hasPrefix(bundlePath) else { continue }
            var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let lc = cmd.assumingMemoryBound(to: load_command.self).pointee
                if lc.cmd == LC_UUID {
                    let u = cmd.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                    uuids.append(UUID(uuid: u).uuidString)
                    break
                }
                cmd = cmd.advanced(by: Int(lc.cmdsize))
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return ([version] + uuids.sorted()).joined(separator: ",")
    }()

    static func load<Payload: Codable>(_ type: Payload.Type, file: String = dayScanFile)
        -> (configSig: String, payload: Payload)? {
        guard let url = fileURL(file), let data = try? Data(contentsOf: url),
              let env = try? PropertyListDecoder().decode(Envelope<Payload>.self, from: data),
              env.format == 1, env.build == buildStamp else { return nil }
        return (env.configSig, env.payload)
    }

    /// Encodes on the caller, writes off it; a failed encode or write just leaves the previous file or none.
    static func save<Payload: Codable>(configSig: String, payload: Payload, file: String = dayScanFile) {
        guard let url = fileURL(file) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Envelope(format: 1, build: buildStamp, configSig: configSig,
                                                      payload: payload)) else { return }
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }
}
