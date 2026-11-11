import AppKit
import Foundation

struct TaskItem: Identifiable, Equatable {
    let id: String              // Notion page id
    let title: String
    let dueDay: String?         // yyyy-MM-dd
    var done: Bool
    let tagColor: NSColor?      // e.g. the Subject select color
    let url: URL?
}

enum NotionError: LocalizedError {
    case badToken
    case notShared
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badToken: return "Notion didn't accept that secret."
        case .notShared: return "Islet can't see your tasks database yet."
        case .http(let c, let m): return "Notion error \(c): \(m)"
        }
    }
}

/// Talks to one Notion tasks database through an internal integration secret.
@MainActor
final class NotionTasks {
    private struct Config: Codable {
        var token: String
        var databaseID: String?
    }

    private struct Schema {
        let title: String
        let done: String
        let due: String
        let tag: String?
    }

    private var config: Config?
    private var schema: Schema?

    var isConnected: Bool { !(config?.token.isEmpty ?? true) }
    private var url: URL { Storage.dir.appendingPathComponent("notion.json") }

    var databaseURL: URL? {
        guard let id = config?.databaseID?.replacingOccurrences(of: "-", with: "") else {
            return URL(string: "https://www.notion.so")
        }
        return URL(string: "https://www.notion.so/\(id)")
    }

    init() {
        if let d = try? Data(contentsOf: url) { config = try? JSONDecoder().decode(Config.self, from: d) }
    }

    func connect(token: String) {
        config = Config(token: token, databaseID: config?.databaseID)
        schema = nil
        if let d = try? JSONEncoder().encode(config) { try? Storage.writePrivate(d, to: url) }
    }

    func disconnect() {
        config = nil
        schema = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Reading

    /// Open tasks due within the next few days (plus overdue ones), and anything ticked off today.
    func fetch(today: Date) async throws -> [TaskItem] {
        let s = try await resolveSchema()
        let cal = Calendar.current
        let todayKey = Self.dayKey(today)
        let horizon = Self.dayKey(cal.date(byAdding: .day, value: 3, to: today) ?? today)
        let body: [String: Any] = [
            "filter": ["and": [
                ["property": s.due, "date": ["on_or_before": horizon]],
                ["or": [
                    ["property": s.done, "checkbox": ["equals": false]],
                    ["property": s.due, "date": ["equals": todayKey]],
                ]],
            ]],
            "sorts": [["property": s.due, "direction": "ascending"]],
            "page_size": 50,
        ]
        let json = try await send("POST", "databases/\(config?.databaseID ?? "")/query", body: body)
        let results = json["results"] as? [[String: Any]] ?? []
        return results.compactMap { page in
            guard let id = page["id"] as? String,
                  let props = page["properties"] as? [String: Any] else { return nil }
            let titleParts = ((props[s.title] as? [String: Any])?["title"] as? [[String: Any]]) ?? []
            let title = titleParts.compactMap { $0["plain_text"] as? String }.joined()
            let done = ((props[s.done] as? [String: Any])?["checkbox"] as? Bool) ?? false
            let start = (((props[s.due] as? [String: Any])?["date"] as? [String: Any])?["start"] as? String)
            let tagColor = s.tag
                .flatMap { ((props[$0] as? [String: Any])?["select"] as? [String: Any])?["color"] as? String }
                .flatMap(Self.notionColor)
            return TaskItem(id: id, title: title.isEmpty ? "Untitled" : title,
                            dueDay: start.map { String($0.prefix(10)) }, done: done,
                            tagColor: tagColor, url: (page["url"] as? String).flatMap(URL.init(string:)))
        }
    }

    func setDone(_ id: String, _ done: Bool) async throws {
        let s = try await resolveSchema()
        _ = try await send("PATCH", "pages/\(id)", body: ["properties": [s.done: ["checkbox": done]]])
    }

    // MARK: Schema

    /// Finds your tasks database and its title / checkbox / date / subject properties, whatever they're called.
    private func resolveSchema() async throws -> Schema {
        if let schema { return schema }
        if let id = config?.databaseID, let db = try? await send("GET", "databases/\(id)"), let s = Self.schema(from: db) {
            schema = s
            return s
        }
        // Use the database you connected Islet to (preferring one with "task" in its name).
        let found = try await send("POST", "search", body: ["filter": ["property": "object", "value": "database"]])
        let dbs = (found["results"] as? [[String: Any]] ?? []).filter { Self.schema(from: $0) != nil }
        guard let pick = dbs.first(where: { Self.title(of: $0).lowercased().contains("task") }) ?? dbs.first,
              let id = pick["id"] as? String, let s = Self.schema(from: pick) else {
            throw NotionError.notShared
        }
        config?.databaseID = id
        if let d = try? JSONEncoder().encode(config) { try? Storage.writePrivate(d, to: url) }
        schema = s
        return s
    }

    private static func title(of db: [String: Any]) -> String {
        ((db["title"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    private static func schema(from db: [String: Any]) -> Schema? {
        guard let props = db["properties"] as? [String: Any] else { return nil }
        func names(_ type: String) -> [String] {
            props.compactMap { (k, v) in ((v as? [String: Any])?["type"] as? String) == type ? k : nil }.sorted()
        }
        func prefer(_ list: [String], _ hints: [String]) -> String? {
            list.first { n in hints.contains { n.lowercased().contains($0) } } ?? list.first
        }
        guard let title = names("title").first,
              let done = prefer(names("checkbox"), ["done", "complete", "finished"]),
              let due = prefer(names("date"), ["due", "deadline", "date"]) else { return nil }
        let selects = names("select").filter { !$0.lowercased().contains("priority") }
        let tag = prefer(selects, ["subject", "class", "course", "project", "category", "area", "tag"])
        return Schema(title: title, done: done, due: due, tag: tag)
    }

    // MARK: HTTP

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token = config?.token else { throw NotionError.badToken }
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200: return json
        case 401: throw NotionError.badToken
        case 404: throw NotionError.notShared
        default: throw NotionError.http(status, json["message"] as? String ?? "Request failed")
        }
    }

    // MARK: Utils

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Notion's select colors as they look in dark mode.
    static func notionColor(_ name: String) -> NSColor? {
        let map: [String: UInt32] = [
            "gray": 0x9B9A97, "brown": 0xBA856F, "orange": 0xC77D48, "yellow": 0xCA9849, "green": 0x529E72,
            "blue": 0x5E87C9, "purple": 0x9D68D3, "pink": 0xD15796, "red": 0xDF5452,
        ]
        return map[name].map { NSColor(hex: $0) }
    }
}
