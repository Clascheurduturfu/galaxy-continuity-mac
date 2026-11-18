import Foundation

/// Guard ensuring emergency numbers are never routed through Samsung CMC relay
/// or Continuity calling paths. macOS Macs without cellular hardware report
/// `+[TUDialRequest isHandleEmergencyNumber:telephonyProvider:] == NO`, so
/// Galaxy Continuity enforces an explicit cross-region emergency blocklist.
public enum CallingEmergencyGuard {
    private static let shortcodes: Set<String> = [
        "112", "911", "999", "000", "110", "111", "118", "119",
        "15", "17", "18", "114", "115", "191", "196", "197",
        "*911", "#911", "+112", "+911"
    ]

    /// Strips visual formatting while keeping dialable characters (`0-9`, `+`, `*`, `#`).
    public static func sanitizeDigits(_ raw: String) -> String {
        String(raw.filter { $0.isNumber || "+*#".contains($0) })
    }

    public static func isEmergencyNumber(_ raw: String) -> Bool {
        let digits = sanitizeDigits(raw)
        return !digits.isEmpty && shortcodes.contains(digits)
    }
}
