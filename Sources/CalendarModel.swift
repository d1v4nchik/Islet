import AppKit
import SwiftUI

// MARK: - Event value type

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let tint: NSColor         // exact Google Calendar color
    let location: String?
    let meetingURL: URL?
    let meetingName: String?
    var link: URL? = nil      // opens the event in Google Calendar

    var color: Color { Color(nsColor: tint) }
    /// Same hue, lifted just enough to read as text on black.
    var textColor: Color { Color(nsColor: Palette.readable(tint)) }
    var onColor: Color { Palette.foreground(on: tint) }
}

enum Featured: Equatable {
    case ongoing(CalEvent)
    case upcoming(CalEvent)

    var event: CalEvent {
        switch self { case .ongoing(let e), .upcoming(let e): return e }
    }
    var isOngoing: Bool { if case .ongoing = self { return true } else { return false } }
}

// MARK: - Model

@MainActor
final class CalendarModel: ObservableObject {
    enum Connection: Equatable {
        case noClient       // no Google client JSON yet
        case signedOut      // client ok, needs Google sign-in
        case signingIn      // waiting on the browser
        case connected
        case apiDisabled    // Calendar API not enabled in the Cloud project
        case error(String)
    }

    struct Peek: Equatable {
        enum Kind: Equatable { case hello, soon, starting }
        var kind: Kind
        var eventID: String?
    }

    @Published private(set) var connection: Connection
    @Published private(set) var calendars: [GCalendarInfo] = []
    @Published private(set) var events: [CalEvent] = []       // timed, today + tomorrow, sorted
    @Published private(set) var allDayToday: [CalEvent] = []
    @Published private(set) var allDayEvents: [CalEvent] = []   // the whole week
    @Published private(set) var now: Date
    @Published private(set) var loading = false
    @Published var peek: Peek?

    enum TasksState: Equatable { case notConnected, ok, notShared, badToken, error(String) }
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var tasksState: TasksState = .notConnected
    let notion = NotionTasks()
    private var tasksLoading = false
    private var lastTasksFetch = Date.distantPast
    private var pendingTasks = Set<String>()

    let auth: GoogleAuth
    private lazy var api = GoogleCalendarAPI(auth: auth)
    private let isMock: Bool
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var firedPeeks = Set<String>()
    private var peekClear: DispatchWorkItem?
    private var peekHeld = false
    private var lastFetch = Date.distantPast
    private var lastCalendarsFetch = Date.distantPast
    private var signInTask: Task<Void, Never>?
    private var didHello = false

    init() {
        now = Date()
        isMock = false
        auth = GoogleAuth()
        connection = !auth.hasClient ? .noClient : (auth.isSignedIn ? .connected : .signedOut)
        tasksState = notion.isConnected ? .ok : .notConnected
    }

    /// Used for design snapshots.
    init(mock: [CalEvent], allDay: [CalEvent], now: Date, connection: Connection = .connected,
         tasks: [TaskItem] = [], tasksState: TasksState = .ok) {
        self.now = now
        isMock = true
        auth = GoogleAuth()
        self.connection = connection
        events = mock.sorted { $0.start < $1.start }
        allDayToday = allDay
        allDayEvents = allDay
        self.tasks = tasks
        self.tasksState = tasksState
    }

    private var cal: Calendar { Calendar.current }

    // MARK: Derived state

    var current: CalEvent? {
        events.filter { $0.start <= now && now < $0.end }.max { $0.start < $1.start }
    }

    var next: CalEvent? { events.first { $0.start > now } }

    /// The one event everything is "about" right now.
    var featured: Featured? {
        let c = current
        if let n = next, cal.isDate(n.start, inSameDayAs: now), n.start.timeIntervalSince(now) <= 10 * 60 {
            // Something is about to start: that wins, unless the current event runs well past it.
            if c == nil || c!.end <= n.start.addingTimeInterval(5 * 60) { return .upcoming(n) }
        }
        if let c { return .ongoing(c) }
        if let n = next, cal.isDate(n.start, inSameDayAs: now) { return .upcoming(n) }
        return nil
    }

    var laterToday: [CalEvent] {
        let fid = featured?.event.id
        return events.filter { $0.start > now && cal.isDate($0.start, inSameDayAs: now) && $0.id != fid }
    }

    var todayTimed: [CalEvent] {
        events.filter { cal.isDate($0.start, inSameDayAs: now) || ($0.start < now && $0.end > now) }
    }

    var firstTomorrow: CalEvent? {
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: now) else { return nil }
        return events.first { cal.isDate($0.start, inSameDayAs: tomorrow) }
    }

    var remainingLabel: String {
        let n = events.filter { $0.end > now && cal.isDate($0.start, inSameDayAs: now) }.count
        switch n {
        case 0: return "All done"
        case 1: return "1 left today"
        default: return "\(n) left today"
        }
    }

    var isUrgent: Bool {
        guard case .upcoming(let e) = featured else { return false }
        let d = e.start.timeIntervalSince(now)
        return d > 0 && d <= 5 * 60
    }

    var accentColor: Color {
        if let id = peek?.eventID, let e = event(id: id) { return e.color }
        return featured?.event.color ?? .white
    }

    func event(id: String?) -> CalEvent? {
        guard let id else { return nil }
        return events.first { $0.id == id }
    }

    func progress(_ f: Featured) -> Double {
        switch f {
        case .ongoing(let e):
            let total = e.end.timeIntervalSince(e.start)
            guard total > 0 else { return 1 }
            return min(1, max(0, now.timeIntervalSince(e.start) / total))
        case .upcoming(let e):
            let d = e.start.timeIntervalSince(now)
            return d >= 3600 ? 0 : 1 - d / 3600
        }
    }

    /// "in 12m", "in 45s", "48m left", "3:30 PM"
    func shortLabel(_ f: Featured) -> String {
        switch f {
        case .ongoing(let e):
            return Fmt.span(e.end.timeIntervalSince(now), seconds: false) + " left"
        case .upcoming(let e):
            let d = e.start.timeIntervalSince(now)
            if d > 6 * 3600 { return Fmt.time.string(from: e.start) }
            return "in " + Fmt.span(d)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isMock else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        })
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refreshTasks()
        if connection == .connected {
            refresh(force: true)
        } else {
            showPeek(Peek(kind: .hello, eventID: nil), for: 5)
        }
    }

    private func tick() {
        let t = Date()
        let dayChanged = !cal.isDate(t, inSameDayAs: lastFetch)
        if auth.isSignedIn && (dayChanged || t.timeIntervalSince(lastFetch) > 120) {
            refresh()
        }
        if notion.isConnected && (dayChanged || t.timeIntervalSince(lastTasksFetch) > 120) {
            refreshTasks()
        }
        withAnimation(Anim.tick) { now = t }
        checkPeeks()
    }

    func refresh(force: Bool = false) {
        guard !isMock, auth.isSignedIn, !loading else { return }
        if !force && connection == .apiDisabled && Date().timeIntervalSince(lastFetch) < 600 { return }
        loading = true
        lastFetch = Date()
        Task {
            defer { loading = false }
            do {
                if force || calendars.isEmpty || Date().timeIntervalSince(lastCalendarsFetch) > 1800 {
                    let cals = try await api.calendars()
                    if cals != calendars { calendars = cals }
                    lastCalendarsFetch = Date()
                }
                let sod = cal.startOfDay(for: Date())
                guard let eod = cal.date(byAdding: .day, value: 1, to: sod),
                      let end = cal.date(byAdding: .day, value: 8, to: sod) else { return }

                var seen = Set<String>()
                var seenKeys = Set<String>()
                var timed: [CalEvent] = []
                var allDay: [CalEvent] = []
                for c in calendars where isVisible(c) {
                    for g in try await api.events(calendarID: c.id, from: sod, to: end) {
                        guard !seen.contains(g.id), let e = CalEvent(google: g, calendar: c) else { continue }
                        let key = "\(e.title.lowercased())|\(e.start.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)"
                        guard !seenKeys.contains(key) else { continue }
                        seen.insert(g.id)
                        seenKeys.insert(key)
                        if e.isAllDay {
                            allDay.append(e)
                        } else {
                            timed.append(e)
                        }
                    }
                }
                timed.sort { $0.start < $1.start }
                withAnimation(Anim.morph) {
                    if timed != events { events = timed }
                    if allDay != allDayEvents { allDayEvents = allDay }
                    let today = allDay.filter { $0.start < eod && $0.end > sod }
                    if today != allDayToday { allDayToday = today }
                    connection = .connected
                }
                if !didHello {
                    didHello = true
                    showPeek(Peek(kind: .hello, eventID: nil), for: 4)
                }
            } catch GoogleError.invalidGrant {
                events = []
                allDayToday = []
                allDayEvents = []
                connection = .signedOut
            } catch GoogleError.apiDisabled {
                connection = .apiDisabled
            } catch is URLError {
                // Offline or flaky network: keep showing what we have and try again later.
            } catch {
                connection = .error(error.localizedDescription)
            }
        }
    }

    // MARK: Google account

    func signIn() {
        guard auth.hasClient else {
            connection = .noClient
            return
        }
        signInTask?.cancel()
        connection = .signingIn
        signInTask = Task {
            do {
                try await auth.signIn()
                connection = .connected
                calendars = []
                didHello = false
                refresh(force: true)
            } catch GoogleError.cancelled, is CancellationError {
                if connection == .signingIn { connection = .signedOut }
            } catch {
                connection = .error(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        auth.cancelSignIn()
        connection = .signedOut
    }

    func signOut() {
        auth.signOut()
        events = []
        allDayToday = []
        allDayEvents = []
        calendars = []
        connection = auth.hasClient ? .signedOut : .noClient
    }

    func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Google OAuth client JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try auth.importClient(from: url)
            connection = .signedOut
            signIn()
        } catch {
            connection = .error(error.localizedDescription)
        }
    }

    func retry() {
        if auth.isSignedIn {
            connection = .connected
            refresh(force: true)
        } else {
            connection = auth.hasClient ? .signedOut : .noClient
        }
    }

    var enableAPIURL: URL? {
        let project = auth.projectID.map { "?project=\($0)" } ?? ""
        return URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com\(project)")
    }

    // MARK: Calendar tab

    /// Today and the six days after it.
    var weekDays: [Date] {
        let sod = cal.startOfDay(for: now)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: sod) }
    }

    /// All-day events first, then timed ones, for one day.
    func events(on day: Date) -> [CalEvent] {
        let start = cal.startOfDay(for: day)
        guard let next = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let allDay = allDayEvents.filter { $0.start < next && $0.end > start }
        let timed = events.filter { $0.start >= start && $0.start < next }
        return allDay + timed
    }

    /// Up to three distinct event colors, for the dots under each day.
    func dotColors(on day: Date) -> [Color] {
        var out: [Color] = []
        for e in events(on: day) where !out.contains(e.color) {
            out.append(e.color)
            if out.count == 3 { break }
        }
        return out
    }

    // MARK: Notion tasks

    struct TaskGroup: Identifiable {
        let id: String
        let title: String
        let alert: Bool
        let items: [TaskItem]
    }

    /// Overdue / Today / Coming up. Ticked tasks stay where they are until the next refresh.
    var taskGroups: [TaskGroup] {
        let today = NotionTasks.dayKey(now)
        let overdue = tasks.filter { ($0.dueDay ?? today) < today }
        let todays = tasks.filter { $0.dueDay == today }
        let later = tasks.filter { ($0.dueDay ?? today) > today }
        return [
            TaskGroup(id: "overdue", title: "Overdue", alert: true, items: overdue),
            TaskGroup(id: "today", title: "Today", alert: false, items: todays),
            TaskGroup(id: "soon", title: "Coming up", alert: false, items: later),
        ].filter { !$0.items.isEmpty }
    }

    /// Open tasks due today or earlier (the badge on the Tasks tab).
    var openTaskCount: Int {
        let today = NotionTasks.dayKey(now)
        return tasks.filter { !$0.done && ($0.dueDay ?? today) <= today }.count
    }

    /// "Oct 28", "Yesterday", "Tomorrow", "Sat"; nothing for today.
    func taskDueText(_ t: TaskItem) -> String? {
        guard let d = t.dueDay else { return nil }
        let today = NotionTasks.dayKey(now)
        guard d != today else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: d) else { return nil }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate(d < today ? "MMM d" : "EEE")
        return out.string(from: date)
    }

    func refreshTasks() {
        guard !isMock, notion.isConnected, !tasksLoading else { return }
        tasksLoading = true
        lastTasksFetch = Date()
        Task {
            defer { tasksLoading = false }
            do {
                var fresh = try await notion.fetch(today: Date())
                // Don't undo a tick that's still on its way to Notion.
                for i in fresh.indices where pendingTasks.contains(fresh[i].id) {
                    if let local = tasks.first(where: { $0.id == fresh[i].id }) { fresh[i].done = local.done }
                }
                withAnimation(Anim.morph) {
                    if fresh != tasks { tasks = fresh }
                    tasksState = .ok
                }
            } catch NotionError.badToken {
                tasksState = .badToken
            } catch NotionError.notShared {
                tasksState = .notShared
            } catch is URLError {
                // offline: keep what we have
            } catch {
                tasksState = .error(error.localizedDescription)
            }
        }
    }

    func toggleTask(_ id: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let done = !tasks[i].done
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { tasks[i].done = done }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        pendingTasks.insert(id)
        Task {
            defer { pendingTasks.remove(id) }
            do {
                try await notion.setDone(id, done)
            } catch {
                if let j = tasks.firstIndex(where: { $0.id == id }) {
                    withAnimation { tasks[j].done = !done }
                }
                NSSound.beep()
            }
        }
    }

    /// Asks for the Notion integration secret (typed or pasted by you).
    func connectNotion() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Connect your Notion tasks"
        a.informativeText = "1. At notion.so/profile/integrations, create a new internal integration called \"Islet\" and copy its secret.\n2. In Notion, open your tasks database \u{2192} \u{2022}\u{2022}\u{2022} \u{2192} Connections \u{2192} add Islet.\n3. Paste the secret below."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Integration secret"
        a.accessoryView = field
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Open Notion Integrations")
        a.window.initialFirstResponder = field
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            notion.connect(token: token)
            tasksState = .ok
            refreshTasks()
        case .alertThirdButtonReturn:
            if let u = URL(string: "https://www.notion.so/profile/integrations") { NSWorkspace.shared.open(u) }
        default:
            break
        }
    }

    func disconnectNotion() {
        notion.disconnect()
        tasks = []
        tasksState = .notConnected
    }

    func openTasksInNotion() {
        guard let web = notion.databaseURL else { return }
        let app = URL(string: web.absoluteString.replacingOccurrences(of: "https://", with: "notion://"))
        if let app, NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(web)
        }
    }

    // MARK: Calendar selection

    private var overrides: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "calendarVisibility") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "calendarVisibility") }
    }

    func isVisible(_ c: GCalendarInfo) -> Bool { overrides[c.id] ?? c.selectedInGoogle }

    func toggleCalendar(_ id: String) {
        guard let c = calendars.first(where: { $0.id == id }) else { return }
        var o = overrides
        o[id] = !isVisible(c)
        overrides = o
        refresh(force: true)
    }

    // MARK: Peeks (short heads-ups that drop out of the notch)

    private func checkPeeks() {
        for e in events {
            let d = e.start.timeIntervalSince(now)
            if d <= 0 && d > -30 && !firedPeeks.contains(e.id + "start") {
                firedPeeks.insert(e.id + "start")
                firedPeeks.insert(e.id + "soon")
                showPeek(Peek(kind: .starting, eventID: e.id), for: 8)
                return
            }
            if d > 0 && d <= 5 * 60 && !firedPeeks.contains(e.id + "soon") {
                firedPeeks.insert(e.id + "soon")
                showPeek(Peek(kind: .soon, eventID: e.id), for: 7)
                return
            }
        }
    }

    func showPeek(_ p: Peek, for seconds: Double) {
        peekHeld = false
        withAnimation(Anim.morph) { peek = p }
        schedulePeekEnd(after: seconds)
    }

    private func schedulePeekEnd(after seconds: Double) {
        peekClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.peekHeld else { return }
                withAnimation(Anim.morph) { self.peek = nil }
            }
        }
        peekClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Cursor is on the heads-up: keep it open.
    func holdPeek() {
        peekHeld = true
        peekClear?.cancel()
    }

    func releasePeek() {
        guard peek != nil else { return }
        peekHeld = false
        schedulePeekEnd(after: 1.2)
    }

    /// Shows the heads-up for the next event (or today's summary) so you can see how it looks.
    func previewHeadsUp() {
        if let n = next {
            showPeek(Peek(kind: .soon, eventID: n.id), for: 6)
        } else {
            showPeek(Peek(kind: .hello, eventID: nil), for: 5)
        }
    }

    func dismissPeek() {
        peekClear?.cancel()
        peekHeld = false
        if peek != nil { withAnimation(Anim.morph) { peek = nil } }
    }
}

// MARK: - Helpers

enum MeetingLink {
    private static let patterns: [(name: String, regex: String)] = [
        ("Google Meet", #"https://meet\.google\.com/[a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}"#),
        ("Google Meet", #"https://meet\.google\.com/[A-Za-z0-9_\-/?=&]+"#),
        ("Zoom", #"https://(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/[^\s<>"']+"#),
        ("Teams", #"https://teams\.(?:microsoft|live)\.com/[^\s<>"']+"#),
        ("Webex", #"https://(?:[\w-]+\.)?webex\.com/[^\s<>"']+"#),
        ("FaceTime", #"https://facetime\.apple\.com/join[^\s<>"']+"#),
        ("Whereby", #"https://whereby\.com/[^\s<>"']+"#),
        ("Jitsi", #"https://meet\.jit\.si/[^\s<>"']+"#),
    ]

    static func find(in texts: [String?]) -> (url: URL, name: String)? {
        let hay = texts.compactMap { $0 }.joined(separator: "\n")
        guard !hay.isEmpty else { return nil }
        for p in patterns {
            if let r = hay.range(of: p.regex, options: [.regularExpression, .caseInsensitive]) {
                var s = String(hay[r])
                while let last = s.last, ".,;:)]}>".contains(last) { s.removeLast() }
                if let u = URL(string: s) { return (u, p.name) }
            }
        }
        return nil
    }
}

enum Palette {
    /// Brightens colors so they pop on the black island (grays stay gray, pastels wake up).
    static func vivid(_ c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.sRGB) else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let sat = s < 0.08 ? s : min(max(s, 0.45), 0.82)
        return NSColor(hue: h, saturation: sat, brightness: max(b, 0.84), alpha: 1)
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        guard let rgb = c.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
    }

    /// Lightens dark colors (Blueberry, Graphite, Tomato…) only as much as needed to read on black.
    static func readable(_ c: NSColor) -> NSColor {
        let l = luminance(c)
        guard l < 0.3 else { return c }
        return c.usingColorSpace(.sRGB)?.blended(withFraction: min(0.45, (0.3 - l) * 1.6 + 0.1), of: .white) ?? c
    }

    static func foreground(on c: NSColor) -> Color {
        luminance(c) > 0.4 ? Color.black.opacity(0.85) : .white
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

@MainActor
enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let hour: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        return f
    }()

    static let interval: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func range(_ e: CalEvent) -> String { interval.string(from: e.start, to: e.end) }

    /// "45s", "12m", "1h 5m"
    static func span(_ seconds: TimeInterval, seconds showSeconds: Bool = true) -> String {
        let s = max(0, seconds)
        if s < 60 && showSeconds { return "\(Int(s.rounded(.up)))s" }
        let mins = max(1, Int((s / 60).rounded(.up)))
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

enum GCal {
    static func open(day: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        guard let y = c.year, let m = c.month, let d = c.day,
              let url = URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(d)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func open(_ e: CalEvent) {
        if let link = e.link { NSWorkspace.shared.open(link) } else { open(day: e.start) }
    }

    static func openSettings(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") { NSWorkspace.shared.open(url) }
    }
}
