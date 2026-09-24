import Foundation

// MARK: - Display formatting
//
// Every string the dashboard derives from a number or a time. Portable so the
// exact output is covered by tests on Linux; the views only lay these out.

public enum Format {
    public static func rate(_ bytesPerSec: Int64) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1fM", Double(bytesPerSec) / 1_048_576)
        }
        if bytesPerSec >= 1024 {
            return "\(bytesPerSec / 1024)K"
        }
        return "\(bytesPerSec)B"
    }

    public static func uptime(_ secs: Int) -> String {
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        if d > 0 { return "\(d)d" }
        return "\(h)h"
    }

    public static func bytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1024 { return String(format: "%.1fT", gb / 1024) }
        if gb >= 10 { return String(format: "%.0fG", gb) }
        return String(format: "%.1fG", gb)
    }

    public static func megabytes(_ mb: Int) -> String {
        if mb >= 1024 { return String(format: "%.1fG", Double(mb) / 1024) }
        return "\(mb)M"
    }

    // MARK: System bar

    /// Local uptime in the system bar: "3d 4h", or "4h 12m" under a day.
    public static func uptimeLong(_ secs: Int) -> String {
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        return "\(h)h \(m)m"
    }

    /// Free and total space of the root volume in GB: "245/494GB". Empty
    /// when the volume can't be read.
    public static func diskFree(_ usage: DiskUsage?) -> String {
        guard let usage else { return "" }
        let freeGB = Double(usage.freeBytes) / 1_073_741_824
        let totalGB = Double(usage.totalBytes) / 1_073_741_824
        return String(format: "%.0f/%.0fGB", freeGB, totalGB)
    }

    /// Battery time left: "2h 5m", or "45m" under an hour.
    public static func batteryRemaining(minutes mins: Int) -> String {
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: Agenda

    /// Time until the next event starts: "now", "in 25m", "in 2h", "in 2h 5m".
    public static func startsIn(minutes mins: Int) -> String {
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins)m" }
        let h = mins / 60, m = mins % 60
        return m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
    }

    // MARK: Weather

    /// Contextual sun info from 24h "H:mm" times: "rises in Xh Ym",
    /// "sets in Xm", or "Xh Ym daylight" once the sun is down. Nil if either
    /// time is missing or malformed.
    public static func sunContext(
        sunrise: String?, sunset: String?, now: Date, calendar: Calendar = .current
    ) -> String? {
        guard let sr = sunrise, let ss = sunset else { return nil }
        let srParts = sr.split(separator: ":"), ssParts = ss.split(separator: ":")
        guard srParts.count == 2, ssParts.count == 2,
              let srH = Int(srParts[0]), let srM = Int(srParts[1]),
              let ssH = Int(ssParts[0]), let ssM = Int(ssParts[1]) else { return nil }
        let nowH = calendar.component(.hour, from: now)
        let nowM = calendar.component(.minute, from: now)
        let current = nowH * 60 + nowM
        let rise = srH * 60 + srM
        let set = ssH * 60 + ssM
        if current < rise {
            let d = rise - current
            return d < 60 ? "rises in \(d)m" : "rises in \(d / 60)h \(d % 60)m"
        }
        if current < set {
            let d = set - current
            return d < 60 ? "sets in \(d)m" : "sets in \(d / 60)h \(d % 60)m"
        }
        let daylight = set - rise
        guard daylight > 0 else { return nil }
        return "\(daylight / 60)h \(daylight % 60)m daylight"
    }
}
