import Foundation
import PhoneCamCore

/// Looks: PhoneCam's built-in looks and the user's own .cube LUTs, applied with a strength (0…1).
/// User LUTs live on the iPhone in Application Support/LUTs as the original .cube text.
extension Camera {
    static let maxLUTBytes = 8 * 1024 * 1024

    static var lutDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LUTs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The user's LUT names, sorted.
    static func userLUTs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: lutDir, includingPropertiesForKeys: nil)) ?? []
        return Presets.sortedNames(Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "cube" }
            .map { ($0.deletingPathExtension().lastPathComponent, [String: String]()) }))
    }

    /// File-safe display name from an uploaded file name; never one of the built-in names.
    static func lutName(_ raw: String) -> String? {
        var stem = (raw as NSString).deletingPathExtension
        stem = String(stem.unicodeScalars.filter { !"/\\:\0".unicodeScalars.contains($0) })
        stem = String(stem.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !stem.isEmpty, !stem.hasPrefix(".") else { return nil }
        return Looks.names.contains(stem) ? stem + " (mine)" : stem
    }

    private static func lutFile(_ name: String) -> URL { lutDir.appendingPathComponent(name + ".cube") }

    /// queue: store an uploaded .cube and switch to it. Returns an error message for the page, or nil.
    func saveLUT(name raw: String, data: Data) -> String? {
        guard data.count <= Camera.maxLUTBytes else { return "The file is too big (8 MB at most)." }
        guard let name = Camera.lutName(raw) else { return "Give the file a name." }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return "This is not a text .cube file."
        }
        do { _ = try CubeLUT.parse(text) } catch { return "Can't read this LUT: \(error)." }
        do { try data.write(to: Camera.lutFile(name), options: .atomic) } catch { return "Can't save it on the iPhone." }
        lutTable = nil // a file with the same name may have been replaced
        apply(["lut": name])
        return nil
    }

    /// queue: the table for a look name (built-in or the user's), nil for none or unknown.
    func loadLUT(_ name: String) -> CubeLUT? {
        if name.isEmpty { return nil }
        if Camera.userLUTs().contains(name),
           let text = try? String(contentsOf: Camera.lutFile(name), encoding: .utf8),
           let lut = try? CubeLUT.parse(text) { return lut }
        return Looks.lut(name)
    }

    func deleteLUT(_ name: String) {
        guard Camera.userLUTs().contains(name) else { return }
        try? FileManager.default.removeItem(at: Camera.lutFile(name))
        if lut == name { apply(["lut": ""]) }
    }

    /// queue: rebuild the cube the frame pipeline uses from the current look and strength.
    func rebuildLUT() {
        if lutTable?.name != lut { lutTable = loadLUT(lut).map { (lut, $0) } }
        let cube = lutTable.flatMap { t in lutAmt > 0.005 ? (data: t.lut.cubeData(amount: lutAmt), size: t.lut.size) : nil }
        lock.withLock { lutCube = cube }
    }
}
