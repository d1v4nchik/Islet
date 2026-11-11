import Foundation

/// `Islet --debug-colors`: prints which Google color id each calendar/event uses (for palette mapping).
@MainActor
enum DebugDump {
    static func colors() async {
        let auth = GoogleAuth()
        let api = GoogleCalendarAPI(auth: auth)
        do {
            let cals = try await api.calendars()
            for c in cals { print("CAL", c.selectedInGoogle ? "on " : "off", c.colorHex ?? "-", c.name) }
            let from = Date().addingTimeInterval(-30 * 86400), to = Date().addingTimeInterval(60 * 86400)
            var byColor: [String: [String]] = [:]
            for c in cals where c.selectedInGoogle {
                for e in try await api.events(calendarID: c.id, from: from, to: to) {
                    let key = "\(c.name) / colorId=\(e.colorId ?? "none")"
                    let t = e.summary ?? "?"
                    if byColor[key, default: []].count < 6 && !(byColor[key]?.contains(t) ?? false) {
                        byColor[key, default: []].append(t)
                    }
                }
            }
            for k in byColor.keys.sorted() { print(k, "->", byColor[k]!.joined(separator: " | ")) }
        } catch {
            print("error:", error.localizedDescription)
        }
    }
}
