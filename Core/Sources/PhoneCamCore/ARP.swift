import Foundation

/// The iPhone over USB shows up in the Mac's ARP table with a link-local address (169.254.x.x).
public enum ARP {
    /// Link-local addresses from `arp -an` output, in table order, without the broadcast and
    /// unresolved (incomplete) entries.
    public static func linkLocal(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n")
        where !line.contains("ff:ff:ff:ff:ff:ff") && !line.contains("incomplete") {
            guard let a = line.firstIndex(of: "("), let b = line.firstIndex(of: ")"), a < b else { continue }
            let ip = String(line[line.index(after: a)..<b])
            if ip.hasPrefix("169.254."), !ip.hasSuffix(".255"), !out.contains(ip) { out.append(ip) }
        }
        return out
    }
}
