import AppKit
import SwiftUI

// MARK: - Shared UI state

enum IslandMode: Hashable { case collapsed, peek, expanded }
enum PanelTab: Hashable { case today, week, tasks }

struct NotchGeometry: Equatable {
    var hasNotch = true
    var notchWidth: CGFloat = 185
    var height: CGFloat = 32
    /// Width of the part that lives inside the menu bar. Only the notch itself, never wider.
    var neckWidth: CGFloat { hasNotch ? notchWidth : 0 }
}

@MainActor
final class IslandUI: ObservableObject {
    @Published var hovering = false
    @Published var pinned = false          // opened from the menu bar item
    @Published var tab: PanelTab = .today
    @Published var selectedDay: Date? = nil
    @Published var geo = NotchGeometry()
    @Published var sizes: [IslandMode: CGSize] = [:]

    func mode(peeking: Bool) -> IslandMode {
        (hovering || pinned) ? .expanded : (peeking ? .peek : .collapsed)
    }

    /// Size of the part that hangs *below* the menu bar.
    func bodySize(for m: IslandMode) -> CGSize {
        m == .collapsed ? CGSize(width: geo.neckWidth, height: 0) : (sizes[m] ?? CGSize(width: geo.neckWidth, height: 0))
    }
}

enum Style {
    static let expandedWidth: CGFloat = 400
    static func radius(_ m: IslandMode) -> CGFloat { m == .expanded ? 30 : 22 }
}

enum Anim {
    static let morph = Animation.spring(duration: 0.42, bounce: 0.08)
    static let tick = Animation.smooth(duration: 0.35)
}

// MARK: - Root

struct IslandRoot: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var ui: IslandUI
    var forcedMode: IslandMode? = nil

    var body: some View {
        let m = forcedMode ?? ui.mode(peeking: model.peek != nil)
        let neckW = ui.geo.neckWidth
        let neckH = ui.geo.height
        let b = ui.bodySize(for: m)
        let radius = Style.radius(m)
        let shape = IslandShape(neckWidth: neckW, neckHeight: neckH, bodyWidth: b.width, bodyHeight: b.height, radius: radius)

        ZStack(alignment: .top) {
            PeekView(model: model)
                .fixedSize()
                .onSize { ui.sizes[.peek] = $0 }
                .shown(m == .peek)
            ExpandedView(model: model, ui: ui)
                .fixedSize()
                .onSize { ui.sizes[.expanded] = $0 }
                .shown(m == .expanded)
        }
        .frame(width: b.width, height: b.height, alignment: .top)
        .padding(.top, neckH)
        .frame(width: max(b.width, neckW) + 24, height: neckH + b.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(Anim.morph, value: m)
        .animation(Anim.morph, value: b)
    }
}

// MARK: - Peek (short heads-up): one slim line that drops out of the notch

struct PeekView: View {
    @ObservedObject var model: CalendarModel

    private struct Info {
        var color: Color
        var onColor: Color = .black
        var title: String
        var detail: String? = nil
        var url: URL? = nil
        var action: (title: String, run: () -> Void)? = nil
        var pulse = false
    }

    private var info: Info {
        let now = model.now
        if let p = model.peek, p.kind != .hello, let e = model.event(id: p.eventID) {
            let d = e.start.timeIntervalSince(now)
            return Info(color: e.color, onColor: e.onColor, title: e.title,
                        detail: d > 0 ? "in \(Fmt.span(d))" : "now", url: e.meetingURL, pulse: true)
        }
        switch model.connection {
        case .noClient, .signedOut, .signingIn:
            return Info(color: Color(nsColor: NSColor(hex: 0x8AB4F8)), title: "Connect Google Calendar",
                        action: ("Connect", { model.signIn() }))
        case .apiDisabled, .error:
            return Info(color: .orange, title: "Can't reach Google Calendar")
        case .connected:
            break
        }
        if let f = model.featured {
            return Info(color: f.event.color, onColor: f.event.onColor, title: f.event.title,
                        detail: model.shortLabel(f), url: f.event.meetingURL, pulse: model.isUrgent)
        }
        return Info(color: .mint, title: "All clear today")
    }

    var body: some View {
        let i = info
        let hasButton = i.url != nil || i.action != nil
        HStack(spacing: 8) {
            Circle()
                .fill(i.color)
                .frame(width: 7, height: 7)
                .modifier(Pulse(active: i.pulse))
            CappedWidth(max: 210) {
                Text(i.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let d = i.detail {
                Text(d)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(i.color)
                    .contentTransition(.numericText(countsDown: true))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if let url = i.url {
                MiniButton(title: "Join", icon: "video.fill", color: i.color, onColor: i.onColor) {
                    NSWorkspace.shared.open(url)
                }
            } else if let a = i.action {
                MiniButton(title: a.title, color: i.color, onColor: .black, action: a.run)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, hasButton ? 7 : 16)
        .padding(.vertical, 8)
        .frame(minWidth: 230)
    }
}

struct MiniButton: View {
    let title: String
    var icon: String? = nil
    let color: Color
    let onColor: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                Text(title).font(.system(size: 11.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(onColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
            .brightness(hover ? 0.06 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Expanded (hover the notch, or click the menu bar item)

struct ExpandedView: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var ui: IslandUI

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(Fmt.day.string(from: model.now))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                TabSwitch(tab: $ui.tab, taskCount: model.tasksState == .ok ? model.openTaskCount : 0)
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .padding(.top, 12)

            ZStack(alignment: .top) {
                // The old tab leaves at once so the panel resizes straight to the new one.
                switch ui.tab {
                case .today:
                    TodayTab(model: model).transition(.asymmetric(insertion: .opacity, removal: .identity))
                case .week:
                    WeekTab(model: model, ui: ui).transition(.asymmetric(insertion: .opacity, removal: .identity))
                case .tasks:
                    TasksTab(model: model).transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
            }
        }
        .padding(.bottom, 12)
        .frame(width: Style.expandedWidth)
    }
}

struct TodayTab: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        let connected = model.connection == .connected
        let allDay = Array(model.allDayToday.prefix(2))
        let later = Array(model.laterToday.prefix(3))
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if !connected {
                    ConnectCard(model: model)
                } else if let f = model.featured {
                    HeroCard(model: model, featured: f)
                } else {
                    FreeCard(model: model)
                }
            }
            .padding(.horizontal, 12)

            if connected && !(allDay.isEmpty && later.isEmpty) {
                ListSection(title: "Today", accessory: {
                    TinyLink(title: "Calendar") { GCal.open(day: model.now) }
                }) {
                    ForEach(later) { EventRow(event: $0, now: model.now) }
                    ForEach(allDay) { EventRow(event: $0, now: model.now) }
                }
            }
        }
    }
}

struct HeroCard: View {
    @ObservedObject var model: CalendarModel
    let featured: Featured

    var body: some View {
        let e = featured.event
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text((featured.isOngoing ? "Now · " : "Up next · ") + model.shortLabel(featured))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(e.color)
                    .contentTransition(.numericText(countsDown: true))
                Text(e.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(Fmt.range(e))
                    if let loc = e.location {
                        Text("·")
                        Text(loc).lineLimit(1)
                    } else if let name = e.meetingName {
                        Text("·")
                        Image(systemName: "video.fill").font(.system(size: 9))
                        Text(name)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                if featured.isOngoing {
                    ProgressBar(value: model.progress(featured), color: e.color)
                        .padding(.top, 6)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule().fill(e.color).frame(width: 4)
            }
            Spacer(minLength: 6)
            if let url = e.meetingURL {
                JoinButton(url: url, color: e.color, onColor: e.onColor)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [e.color.opacity(0.24), e.color.opacity(0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.07))
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { GCal.open(e) }
    }
}

struct FreeCard: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Free for the rest of today")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                if let t = model.firstTomorrow {
                    Text("Tomorrow · \(t.title) at \(Fmt.time.string(from: t.start))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
    }
}

struct ConnectCard: View {
    @ObservedObject var model: CalendarModel
    private let blue = Color(nsColor: NSColor(hex: 0x8AB4F8))

    var body: some View {
        switch model.connection {
        case .noClient:
            Card(icon: "doc.badge.plus", tint: blue, title: "Connect Google Calendar",
                 subtitle: "Pick the OAuth client JSON from your Google Cloud project.") {
                SolidButton(title: "Choose file…", color: blue, onColor: .black) { model.chooseClientFile() }
            }
        case .signedOut:
            Card(icon: "calendar.badge.plus", tint: blue, title: "Connect Google Calendar",
                 subtitle: "Sign in once. Islet can only read your events, never change them.") {
                SolidButton(title: "Sign in with Google", color: blue, onColor: .black) { model.signIn() }
            }
        case .signingIn:
            Card(icon: "person.badge.key.fill", tint: blue, title: "Finish in your browser",
                 subtitle: "Pick your Google account and allow access, then come back here.") {
                PillButton(title: "Cancel", icon: "xmark") { model.cancelSignIn() }
            }
        case .apiDisabled:
            Card(icon: "power", tint: .orange, title: "Turn on the Calendar API",
                 subtitle: "Your Google Cloud project needs the Google Calendar API enabled. Click Enable, then Retry.") {
                HStack(spacing: 6) {
                    SolidButton(title: "Enable", color: .orange, onColor: .black) {
                        if let u = model.enableAPIURL { NSWorkspace.shared.open(u) }
                    }
                    PillButton(title: "Retry", icon: "arrow.clockwise") { model.retry() }
                }
            }
        case .error(let msg):
            Card(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't load your calendar",
                 subtitle: msg) {
                PillButton(title: "Retry", icon: "arrow.clockwise") { model.retry() }
            }
        case .connected:
            EmptyView()
        }
    }
}

/// Icon + title + subtitle card, with an optional trailing control.
struct Card<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String, tint: Color, title: String, subtitle: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                trailing()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

struct EventRow: View {
    let event: CalEvent
    let now: Date
    var countdown = true        // "in 12m" (today) vs. the location (other days)
    @State private var hover = false

    var body: some View {
        let past = !event.isAllDay && event.end <= now
        HStack(spacing: 10) {
            Circle().fill(event.color).frame(width: 7, height: 7)
            Text(event.isAllDay ? "All day" : Fmt.time.string(from: event.start))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 62, alignment: .leading)
            Text(event.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 6)
            if event.meetingURL != nil {
                Image(systemName: "video.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
        .opacity(past ? 0.4 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hover ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { GCal.open(event) }
    }

    private var trailing: String? {
        guard !event.isAllDay else { return nil }
        if !countdown { return event.location }
        if event.start > now { return "in " + Fmt.span(event.start.timeIntervalSince(now), seconds: false) }
        return event.end > now ? "now" : nil
    }
}

// MARK: - Calendar tab (the next seven days)

struct WeekTab: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var ui: IslandUI

    var body: some View {
        let days = model.weekDays
        let cal = Calendar.current
        let selected = ui.selectedDay.flatMap { d in days.first { cal.isDate($0, inSameDayAs: d) } } ?? days.first ?? model.now
        let isToday = cal.isDateInToday(selected)
        let list = model.events(on: selected)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                ForEach(days, id: \.self) { d in
                    DayChip(day: d, selected: cal.isDate(d, inSameDayAs: selected), isToday: cal.isDateInToday(d),
                            dots: model.dotColors(on: d)) {
                        withAnimation(.snappy(duration: 0.25)) { ui.selectedDay = d }
                    }
                }
            }
            .padding(.horizontal, 12)

            ListSection(title: isToday ? "Today" : Fmt.day.string(from: selected), accessory: {
                TinyLink(title: "Calendar") { GCal.open(day: selected) }
            }) {
                if list.isEmpty {
                    Text(model.connection == .connected ? "Nothing planned" : "Connect Google Calendar in the Today tab")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    CappedScroll(maxHeight: 250) {
                        VStack(spacing: 0) {
                            ForEach(list) { EventRow(event: $0, now: model.now, countdown: isToday) }
                        }
                    }
                }
            }
        }
    }
}

struct DayChip: View {
    let day: Date
    let selected: Bool
    let isToday: Bool
    let dots: [Color]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(Self.weekday.string(from: day).uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(isToday ? 0.8 : 0.4))
                Text(Self.number.string(from: day))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.black : .white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(selected ? Color.white : .white.opacity(isToday ? 0.12 : 0)))
                HStack(spacing: 3) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 4.5, height: 4.5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(hover && !selected ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let number: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()
}

/// A titled list block ("Today", "Overdue") with an optional control on the right.
struct ListSection<Content: View, Accessory: View>: View {
    let title: String
    var tint: Color? = nil
    let accessory: () -> Accessory
    let content: () -> Content

    init(title: String, tint: Color? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.tint = tint
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: title, color: tint ?? .white.opacity(0.35))
                Spacer()
                accessory()
            }
            .frame(height: 18)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
            content()
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Notion tasks

struct TasksTab: View {
    @ObservedObject var model: CalendarModel
    private let softRed = Color(nsColor: NSColor(hex: 0xFF8A80))

    var body: some View {
        switch model.tasksState {
        case .notConnected:
            InlineNote(icon: "checklist", text: "Tick off your Notion tasks here", button: "Connect") {
                model.connectNotion()
            }
            .padding(.vertical, 8)
        case .badToken:
            InlineNote(icon: "key.fill", text: "Notion didn't accept that secret", button: "Try again") {
                model.connectNotion()
            }
            .padding(.vertical, 8)
        case .notShared:
            InlineNote(icon: "link", text: "In Notion, add Islet under Connections on your tasks database",
                       button: "Retry") { model.refreshTasks() }
            .padding(.vertical, 8)
        case .error(let msg):
            InlineNote(icon: "exclamationmark.triangle", text: msg, button: "Retry") { model.refreshTasks() }
                .padding(.vertical, 8)
        case .ok:
            let groups = model.taskGroups
            if groups.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                    Text("Nothing due. Nice.").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    TinyLink(title: "Notion") { model.openTasksInNotion() }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            } else {
                CappedScroll(maxHeight: 330) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { g in
                            ListSection(title: g.alert ? "\(g.title) · \(g.items.count)" : g.title,
                                        tint: g.alert ? softRed.opacity(0.85) : nil, accessory: {
                                if g.id == groups.first?.id {
                                    TinyLink(title: "Notion") { model.openTasksInNotion() }
                                }
                            }) {
                                ForEach(g.items) { t in
                                    TaskRow(task: t, due: g.id == "today" ? nil : model.taskDueText(t)) {
                                        model.toggleTask(t.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem
    let due: String?
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(done: task.done,
                        tint: task.tagColor.map { Color(nsColor: Palette.vivid($0)) } ?? Color(nsColor: NSColor(hex: 0x8AB4F8)))
            Text(task.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(task.done ? 0.35 : 0.9))
                .strikethrough(task.done, color: .white.opacity(0.35))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let due {
                Text(due)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hover ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture(perform: toggle)
    }
}

struct CheckCircle: View {
    var done: Bool
    var tint: Color

    var body: some View {
        ZStack {
            Circle().strokeBorder(tint.opacity(done ? 0 : 0.75), lineWidth: 1.5)
            Circle().fill(tint).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.black.opacity(0.8))
                .scaleEffect(done ? 1 : 0.4)
                .opacity(done ? 1 : 0)
        }
        .frame(width: 16, height: 16)
    }
}

struct InlineNote: View {
    let icon: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            PillButton(title: button, icon: "arrow.right", action: action)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Menu bar label (Notion-style, always visible)

/// Everything the menu bar label shows, as plain values, so its final width can be measured up front
/// and the menu bar item can glide to it instead of snapping.
struct StatusState: Equatable {
    enum Kind: Equatable { case event, idle, signingIn, connect, problem }
    var kind: Kind
    var eventID = ""
    var title = ""
    var detail = ""
    var color: Color = .white
    var remaining: Double = 1
    var pulsing = false
    /// A heads-up is out of the notch: the text lives there, only the pill stays here.
    var compact = false
}

extension CalendarModel {
    var statusState: StatusState {
        let compact = peek != nil
        switch connection {
        case .connected:
            guard let f = featured else { return StatusState(kind: .idle) }
            return StatusState(kind: .event, eventID: f.event.id, title: f.event.title, detail: shortLabel(f),
                               color: f.event.color, remaining: f.isOngoing ? 1 - progress(f) : 1,
                               pulsing: isUrgent || compact, compact: compact)
        case .signingIn: return StatusState(kind: .signingIn, compact: compact)
        case .noClient, .signedOut: return StatusState(kind: .connect, compact: compact)
        case .apiDisabled, .error: return StatusState(kind: .problem)
        }
    }
}

/// The live label inside the menu bar item.
struct StatusLabel: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        StatusLabelContent(state: model.statusState)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Keeps the same width whether or not a heads-up is showing, so the menu bar never shifts;
/// during a heads-up the text simply fades out and back in.
struct StatusLabelContent: View {
    let state: StatusState

    var body: some View {
        let textOpacity: Double = state.compact ? 0 : 1
        HStack(spacing: 6) {
            switch state.kind {
            case .event:
                EventBar(remaining: state.remaining, color: state.color, pulsing: false)
                    .frame(width: 4, height: 14)
                HStack(spacing: 5) {
                    CappedWidth(max: 140) {
                        Text(state.title).lineLimit(1).truncationMode(.tail)
                    }
                    Text(state.detail)
                        .monospacedDigit()
                        .opacity(0.5)
                        .contentTransition(.numericText(countsDown: true))
                }
                .opacity(textOpacity)
            case .idle:
                Image(systemName: "calendar")
            case .signingIn:
                Image(systemName: "person.badge.key")
                Text("Signing in…").opacity(textOpacity)
            case .connect:
                Image(systemName: "calendar.badge.plus")
                Text("Connect").opacity(textOpacity)
            case .problem:
                Image(systemName: "calendar.badge.exclamationmark")
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .padding(.horizontal, 5)
        .fixedSize()
        .animation(.easeInOut(duration: 0.25), value: state.compact)
        .animation(.easeInOut(duration: 0.3), value: state.title)
    }
}

/// The little color pill. During an event it drains as time runs out.
struct EventBar: View {
    var remaining: Double
    var color: Color
    var pulsing: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(color.opacity(0.32))
            Capsule().fill(color).frame(height: max(4, 14 * min(1, max(0, remaining))))
        }
        .modifier(Pulse(active: pulsing))
    }
}

private struct Pulse: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        content   // pulsing turned off: calm, nothing blinks
    }
}

// MARK: - Small components

struct ProgressBar: View {
    var value: Double
    var color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, g.size.width * value))
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 5)
    }
}

struct JoinButton: View {
    let url: URL
    let color: Color
    let onColor: Color

    var body: some View {
        SolidButton(title: "Join", icon: "video.fill", color: color, onColor: onColor) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SolidButton: View {
    let title: String
    var icon: String? = nil
    let color: Color
    let onColor: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 12.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(onColor)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(color))
            .shadow(color: color.opacity(hover ? 0.65 : 0.3), radius: hover ? 10 : 5)
            .scaleEffect(hover ? 1.05 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hover = h } }
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: icon).font(.system(size: 8.5, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(hover ? 0.95 : 0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct IconButton: View {
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(hover ? 0.9 : 0.5))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct TinyLink: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 7.5, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(hover ? 0.85 : 0.4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct SectionLabel: View {
    let text: String
    var color: Color = .white.opacity(0.35)
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.9)
            .foregroundStyle(color)
    }
}

/// Two-tab pill switch with a sliding highlight.
struct TabSwitch: View {
    @Binding var tab: PanelTab
    let taskCount: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            item(.today, "Today", badge: 0)
            item(.week, "Calendar", badge: 0)
            item(.tasks, "Tasks", badge: taskCount)
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.07)))
    }

    private func item(_ t: PanelTab, _ title: String, badge: Int) -> some View {
        let on = tab == t
        return Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { tab = t }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(on ? 0.2 : 0.1)))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(on ? 0.95 : 0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if on { Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "tab", in: ns) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Scrolls only when the content is taller than `maxHeight`, with a soft fade at the bottom.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    init(maxHeight: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.maxHeight = maxHeight
        self.content = content
    }

    var body: some View {
        let measured = content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        if contentHeight > maxHeight + 1 {
            ScrollView(.vertical) { content() }
                .scrollIndicators(.never)
                .frame(height: maxHeight)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.86),
                        .init(color: .black.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .background(alignment: .top) { measured.hidden() }
        } else {
            measured
        }
    }
}

// MARK: - Shape

/// The notch, with a rounded panel hanging *below* the menu bar.
/// Inside the menu bar it is never wider than the notch itself, so it can't cover menus or icons.
struct IslandShape: Shape {
    var neckWidth: CGFloat
    var neckHeight: CGFloat
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(bodyWidth, bodyHeight), radius) }
        set {
            bodyWidth = newValue.first.first
            bodyHeight = newValue.first.second
            radius = newValue.second
        }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX, top = r.minY
        let N = neckWidth, H = neckHeight
        let W = max(bodyWidth, N), B = max(0, bodyHeight)
        let ln = cx - N / 2, rn = cx + N / 2

        // Closed: draw nothing. The real notch is already black, and an overlay could leave hairline edges.
        if B < 0.5 { return p }

        let lb = cx - W / 2, rb = cx + W / 2
        let shoulder = (W - N) / 2
        let rj = N > 0 ? max(0, min(9, shoulder * 0.4, H)) : 0     // fillet where neck meets panel
        let rt = max(0, min(20, shoulder - rj, B / 2))              // panel's top corners
        let rr = max(0, min(radius, B / 2, W / 2))                  // panel's bottom corners
        let k: CGFloat = 0.45
        let bodyTop = top + H, bottom = bodyTop + B

        if N > 0 {
            p.move(to: CGPoint(x: ln, y: top))
            p.addLine(to: CGPoint(x: ln, y: bodyTop - rj))
            p.addQuadCurve(to: CGPoint(x: ln - rj, y: bodyTop), control: CGPoint(x: ln, y: bodyTop))
        } else {
            p.move(to: CGPoint(x: cx, y: bodyTop))
        }
        p.addLine(to: CGPoint(x: lb + rt, y: bodyTop))
        p.addQuadCurve(to: CGPoint(x: lb, y: bodyTop + rt), control: CGPoint(x: lb, y: bodyTop))
        p.addLine(to: CGPoint(x: lb, y: bottom - rr))
        p.addCurve(to: CGPoint(x: lb + rr, y: bottom),
                   control1: CGPoint(x: lb, y: bottom - rr * k),
                   control2: CGPoint(x: lb + rr * k, y: bottom))
        p.addLine(to: CGPoint(x: rb - rr, y: bottom))
        p.addCurve(to: CGPoint(x: rb, y: bottom - rr),
                   control1: CGPoint(x: rb - rr * k, y: bottom),
                   control2: CGPoint(x: rb, y: bottom - rr * k))
        p.addLine(to: CGPoint(x: rb, y: bodyTop + rt))
        p.addQuadCurve(to: CGPoint(x: rb - rt, y: bodyTop), control: CGPoint(x: rb, y: bodyTop))
        if N > 0 {
            p.addLine(to: CGPoint(x: rn + rj, y: bodyTop))
            p.addQuadCurve(to: CGPoint(x: rn, y: bodyTop - rj), control: CGPoint(x: rn, y: bodyTop))
            p.addLine(to: CGPoint(x: rn, y: top))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Layout helpers

/// Lets a single-line Text grow to its natural width, but never past `max` (then it truncates).
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(.unspecified)
        let w = Swift.min(ideal.width, max, proposal.width ?? .infinity)
        return s.sizeThatFits(ProposedViewSize(width: w, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    func shown(_ visible: Bool) -> some View {
        self.opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.97, anchor: .top)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    func onSize(_ action: @escaping (CGSize) -> Void) -> some View {
        onGeometryChange(for: CGSize.self) { $0.size } action: { action($0) }
    }
}
