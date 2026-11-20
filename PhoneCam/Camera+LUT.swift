import Foundation
import PhoneCamCore

/// Your own developing: a .cube LUT made for Apple Log footage (Apple Log in, Rec.709 out) used instead of
/// PhoneCam's built-in developing. The files live on the iPhone in Application Support/LUTs as the original text.
extension Camera {
    static let maxLUTBytes = 8 * 1024 * 1024
    /// Core Image's colour cube takes up to 64 points a side; bigger tables (65 is common) are resampled.
    static let maxCubeSize = 64

    static var lutDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LUTs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The LUTs' names, sorted.
    static func userLUTs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: lutDir, includingPropertiesForKeys: nil)) ?? []
        return Presets.sortedNames(Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "cube" }
            .map { ($0.deletingPathExtension().lastPathComponent, [String: String]()) }))
    }

    /// File-safe display name from an uploaded file name.
    static func lutName(_ raw: String) -> String? {
        var stem = (raw as NSString).deletingPathExtension
        stem = String(stem.unicodeScalars.filter { !"/\\:\0".unicodeScalars.contains($0) })
        stem = String(stem.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !stem.isEmpty, !stem.hasPrefix(".") else { return nil }
        return stem
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
        lut = "" // a file with the same name may have been replaced: load it again
        apply(["lut": name])
        return nil
    }

    func deleteLUT(_ name: String) {
        guard Camera.userLUTs().contains(name) else { return }
        try? FileManager.default.removeItem(at: Camera.lutFile(name))
        if lut == name { apply(["lut": ""]) }
    }

    /// queue: the cube `source` develops Apple Log frames with: the chosen LUT, or nil for the built-in developing.
    func rebuildLUT() {
        var cube: (data: Data, size: Int)?
        if !lut.isEmpty, let text = try? String(contentsOf: Camera.lutFile(lut), encoding: .utf8) ?? String(contentsOf: Camera.lutFile(lut), encoding: .isoLatin1),
           let table = try? CubeLUT.parse(text) {
            let t = table.resampled(to: min(table.size, Camera.maxCubeSize))
            cube = (t.cubeData(amount: 1), t.size)
        } else {
            lut = ""
        }
        lock.withLock { devLUT = cube }
    }
}
