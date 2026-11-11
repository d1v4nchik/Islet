import AppKit
import Foundation
import SwiftUI

struct GCalendarInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let colorHex: String?
    let selectedInGoogle: Bool
    let primary: Bool

    /// Google's API still reports the old calendar palette; the web app shows the newer one.
    var nsColor: NSColor {
        guard let hex = colorHex?.lowercased() else { return NSColor(hex: 0x039BE5) }
        if let modern = GoogleColors.calendar[hex] { return NSColor(hex: modern) }
        return NSColor(hexString: hex) ?? NSColor(hex: 0x039BE5)
    }
}

// MARK: - API payloads

private struct CalendarListResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let backgroundColor: String?
        let selected: Bool?
        let primary: Bool?
        let hidden: Bool?
        let deleted: Bool?
    }
    let items: [Item]?
    let nextPageToken: String?
}

struct GEvent: Decodable {
    struct Time: Decodable {
        let dateTime: String?
        let date: String?
    }
    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
    }
    struct Conference: Decodable {
        struct EntryPoint: Decodable {
            let entryPointType: String?
            let uri: String?
        }
        struct Solution: Decodable { let name: String? }
        let entryPoints: [EntryPoint]?
        let conferenceSolution: Solution?
    }

    let id: String
    let status: String?
    let summary: String?
    let location: String?
    let description: String?
    let colorId: String?
    let htmlLink: String?
    let hangoutLink: String?
    let eventType: String?
    let start: Time?
    let end: Time?
    let attendees: [Attendee]?
    let conferenceData: Conference?
}

private struct EventsResponse: Decodable {
    let items: [GEvent]?
    let nextPageToken: String?
}

private struct APIErrorResponse: Decodable {
    struct Body: Decodable {
        struct Detail: Decodable { let reason: String? }
        let code: Int?
        let message: String?
        let status: String?
        let errors: [Detail]?
    }
    let error: Body
}

// MARK: - Client

@MainActor
final class GoogleCalendarAPI {
    let auth: GoogleAuth

    init(auth: GoogleAuth) { self.auth = auth }

    func calendars() async throws -> [GCalendarInfo] {
        var out: [GCalendarInfo] = []
        var page: String?
        repeat {
            var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            var q = [URLQueryItem(name: "maxResults", value: "250")]
            if let page { q.append(URLQueryItem(name: "pageToken", value: page)) }
            c.queryItems = q
            let r: CalendarListResponse = try await get(c.url!)
            for i in r.items ?? [] where i.deleted != true && i.hidden != true {
                out.append(GCalendarInfo(id: i.id,
                                         name: i.summaryOverride ?? i.summary ?? i.id,
                                         colorHex: i.backgroundColor,
                                         selectedInGoogle: i.selected ?? false,
                                         primary: i.primary ?? false))
            }
            page = r.nextPageToken
        } while page != nil
        return out.sorted { ($0.primary ? 0 : 1, $0.name.lowercased()) < ($1.primary ? 0 : 1, $1.name.lowercased()) }
    }

    func events(calendarID: String, from: Date, to: Date) async throws -> [GEvent] {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/#?")
        let encoded = calendarID.addingPercentEncoding(withAllowedCharacters: allowed) ?? calendarID
        let iso = ISO8601DateFormatter()
        var out: [GEvent] = []
        var page: String?
        repeat {
            var c = URLComponents()
            c.scheme = "https"
            c.host = "www.googleapis.com"
            c.percentEncodedPath = "/calendar/v3/calendars/\(encoded)/events"
            var q = [
                URLQueryItem(name: "timeMin", value: iso.string(from: from)),
                URLQueryItem(name: "timeMax", value: iso.string(from: to)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "fields", value: "nextPageToken,items(id,status,summary,location,description,colorId,htmlLink,hangoutLink,eventType,start,end,attendees(self,responseStatus),conferenceData(entryPoints(entryPointType,uri),conferenceSolution(name)))"),
            ]
            if let page { q.append(URLQueryItem(name: "pageToken", value: page)) }
            c.queryItems = q
            let r: EventsResponse = try await get(c.url!)
            out.append(contentsOf: r.items ?? [])
            page = r.nextPageToken
        } while page != nil
        return out
    }

    private func get<T: Decodable>(_ url: URL, retried: Bool = false) async throws -> T {
        let token = try await auth.accessToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && !retried {
            auth.expireAccessToken()
            return try await get(url, retried: true)
        }
        guard status == 200 else {
            let body = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error
            let reason = body?.errors?.first?.reason ?? ""
            let message = body?.message ?? "HTTP \(status)"
            if status == 403 && (reason == "accessNotConfigured" || message.contains("has not been used")
                                 || message.contains("is disabled")) {
                throw GoogleError.apiDisabled
            }
            throw GoogleError.http(status, message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Mapping to CalEvent

enum GoogleColors {
    /// Google's event colors by colorId.
    static let standardEvent: [String: UInt32] = [
        "1": 0x7986CB, "2": 0x33B679, "3": 0x8E24AA, "4": 0xE67C73, "5": 0xF6BF26, "6": 0xF4511E,
        "7": 0x039BE5, "8": 0x616161, "9": 0x3F51B5, "10": 0x0B8043, "11": 0xD50000,
    ]

    /// If you've recolored Google's color labels, override them in
    /// ~/Library/Application Support/Islet/colors.json, e.g. {"4": "#E6BC92", "11": "#FFFFFF"}.
    static let event: [String: NSColor] = {
        var out = standardEvent.mapValues { NSColor(hex: $0) }
        if let data = try? Data(contentsOf: Storage.dir.appendingPathComponent("colors.json")),
           let custom = try? JSONDecoder().decode([String: String].self, from: data) {
            for (id, hex) in custom {
                if let c = NSColor(hexString: hex) { out[id] = c }
            }
        }
        return out
    }()

    /// Calendar colors: legacy hex from the API -> color shown in Google Calendar today.
    static let calendar: [String: UInt32] = [
        "#ac725e": 0x795548, "#d06b64": 0xE67C73, "#f83a22": 0xD50000, "#fa573c": 0xF4511E,
        "#ff7537": 0xEF6C00, "#ffad46": 0xF09300, "#42d692": 0x009688, "#16a765": 0x0B8043,
        "#7bd148": 0x7CB342, "#b3dc6c": 0xC0CA33, "#fbe983": 0xE4C441, "#fad165": 0xF6BF26,
        "#92e1c0": 0x33B679, "#9fe1e7": 0x039BE5, "#9fc6e7": 0x4285F4, "#4986e7": 0x3F51B5,
        "#9a9cff": 0x7986CB, "#b99aff": 0xB39DDB, "#c2c2c2": 0x616161, "#cabdbf": 0xA79B8E,
        "#cca6ac": 0xAD1457, "#f691b2": 0xD81B60, "#cd74e6": 0x8E24AA, "#a47ae2": 0x9E69AF,
    ]
}

extension CalEvent {
    init?(google e: GEvent, calendar: GCalendarInfo) {
        if e.status == "cancelled" { return nil }
        if e.eventType == "workingLocation" { return nil }
        if e.attendees?.first(where: { $0.isSelf == true })?.responseStatus == "declined" { return nil }
        guard let s = GoogleTime.parse(e.start), let en = GoogleTime.parse(e.end) else { return nil }

        let tint = Palette.vivid(e.colorId.flatMap { GoogleColors.event[$0] } ?? calendar.nsColor)

        var meetURL: URL?
        var meetName: String?
        if let video = e.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri {
            meetURL = URL(string: video)
            meetName = e.conferenceData?.conferenceSolution?.name
        } else if let h = e.hangoutLink {
            meetURL = URL(string: h)
            meetName = "Google Meet"
        } else if let found = MeetingLink.find(in: [e.location, e.description]) {
            meetURL = found.url
            meetName = found.name
        }
        if meetURL != nil && meetName == nil { meetName = "Video call" }

        var loc = e.location?.split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if let l = loc, l.isEmpty || l.lowercased().hasPrefix("http") || MeetingLink.find(in: [l]) != nil { loc = nil }

        let t = (e.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: "\(calendar.id)|\(e.id)",
                  title: t.isEmpty ? "(No title)" : t,
                  start: s.date, end: en.date, isAllDay: s.allDay,
                  tint: tint,
                  location: loc, meetingURL: meetURL, meetingName: meetName,
                  link: e.htmlLink.flatMap(URL.init(string:)))
    }
}

enum GoogleTime {
    static func parse(_ t: GEvent.Time?) -> (date: Date, allDay: Bool)? {
        guard let t else { return nil }
        if let dt = t.dateTime {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: dt) { return (d, false) }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: dt) { return (d, false) }
            return nil
        }
        if let day = t.date {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: day) { return (d, true) }
        }
        return nil
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}
