import AppKit
import SwiftUI

/// Renders screenshots with sample data (`--snapshot <dir>`) and the app icon (`--icon <file.png>`).
@MainActor
enum Snapshot {
    struct Scene {
        let name: String
        let now: Date
        let mode: IslandMode
        var peek: CalendarModel.Peek? = nil
        var connection: CalendarModel.Connection = .connected
        var tasksState: CalendarModel.TasksState = .ok
        var tab: PanelTab = .today
        var selectedDay: Int? = nil
        var height: CGFloat = 560
    }

    static func run(into dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let sod = Calendar.current.startOfDay(for: Date())
        func t(_ h: Int, _ m: Int) -> Date { sod.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        func ev(_ id: String, _ title: String, _ s: Date, _ e: Date, _ hex: UInt32,
                loc: String? = nil, meet: Bool = false, allDay: Bool = false) -> CalEvent {
            CalEvent(id: id, title: title, start: s, end: e, isAllDay: allDay,
                     tint: Palette.vivid(NSColor(hex: hex)), location: loc,
                     meetingURL: meet ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                     meetingName: meet ? "Google Meet" : nil)
        }

        let events = [
            ev("focus", "Focus time", t(8, 20), t(8, 40), 0xE6BC92),
            ev("spanish", "Spanish", t(8, 40), t(9, 40), 0x9D4946, loc: "Room 3"),
            ev("review", "Design Review", t(9, 45), t(10, 45), 0x7986CB, meet: true),
            ev("coffee", "Coffee break", t(10, 45), t(11, 5), 0xE6BC92),
            ev("cs", "Computer Science", t(11, 5), t(12, 5), 0x9D4946, loc: "Lab 2"),
            ev("study", "Study group", t(12, 10), t(13, 10), 0x33B679, meet: true),
            ev("lunch", "Lunch", t(13, 10), t(13, 55), 0xE6BC92),
            ev("sync", "Product sync", t(15, 0), t(15, 30), 0x039BE5, meet: true),
            ev("yoga", "Yoga", t(33, 0), t(34, 0), 0x33B679),
            ev("film", "Film club", t(40, 0), t(41, 30), 0x8E24AA),
            ev("d2a", "Spanish", t(56, 40), t(57, 40), 0x9D4946, loc: "Room 3"),
            ev("d2b", "Dentist", t(63, 30), t(64, 0), 0x039BE5),
            ev("d2c", "Study group", t(59, 0), t(60, 0), 0x33B679, meet: true),
            ev("d2d", "Pottery class", t(66, 0), t(67, 30), 0xF4511E, loc: "Studio B"),
            ev("d3a", "Design Review", t(82, 0), t(83, 0), 0x7986CB, meet: true),
            ev("d4a", "Coffee with Maya", t(107, 0), t(108, 0), 0xE6BC92),
            ev("d5a", "Hike", t(129, 0), t(133, 0), 0x33B679),
        ]
        let allDay = [
            ev("essay", "Essay due", sod, sod.addingTimeInterval(86400), 0xFFFFFF, allDay: true),
            ev("bday", "Mom's birthday", sod, sod.addingTimeInterval(86400), 0x8E24AA, allDay: true),
        ]
        func task(_ id: String, _ title: String, _ day: Int, _ color: String, done: Bool = false) -> TaskItem {
            let d = Calendar.current.date(byAdding: .day, value: day, to: sod)!
            return TaskItem(id: id, title: title, dueDay: NotionTasks.dayKey(d), done: done,
                            tagColor: NotionTasks.notionColor(color), url: nil)
        }
        let tasks = [
            task("t1", "Essay first draft", -1, "red"),
            task("t2", "Read chapter 4", 0, "blue"),
            task("t3", "Slides for Friday", 0, "purple", done: true),
            task("t4", "Lab report", 0, "green"),
            task("t5", "Book the dentist", 1, "gray"),
        ]

        let scenes = [
            Scene(name: "menu-bar", now: t(11, 41), mode: .collapsed, height: 60),
            Scene(name: "heads-up", now: t(14, 56), mode: .peek, peek: .init(kind: .soon, eventID: "sync"), height: 120),
            Scene(name: "today", now: t(11, 41), mode: .expanded, height: 400),
            Scene(name: "calendar", now: t(11, 41), mode: .expanded, tab: .week, selectedDay: 2, height: 345),
            Scene(name: "tasks", now: t(11, 41), mode: .expanded, tab: .tasks, height: 355),
            Scene(name: "connect", now: t(11, 41), mode: .expanded, connection: .signedOut,
                  tasksState: .notConnected, height: 360),
        ]

        for s in scenes {
            let model = CalendarModel(mock: events, allDay: allDay, now: s.now, connection: s.connection,
                                      tasks: s.tasksState == .ok ? tasks : [], tasksState: s.tasksState)
            model.peek = s.peek
            let ui = IslandUI()
            ui.geo = NotchGeometry(hasNotch: true, notchWidth: 185, height: 32)
            ui.tab = s.tab
            ui.selectedDay = s.selectedDay.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: sod) }
            let view = SnapshotScene(model: model, ui: ui, mode: s.mode, clock: Self.clock.string(from: s.now))
                .frame(width: 1180, height: s.height)
            save(view, to: out.appendingPathComponent(s.name + ".png"), scale: 2, passes: 5)
            print("wrote", s.name)
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d h:mm a")
        return f
    }()

    static func icon(to path: String) {
        save(IconArt(), to: URL(fileURLWithPath: path), scale: 1, passes: 1)
        print("wrote icon", path)
    }

    private static func save<V: View>(_ view: V, to url: URL, scale: CGFloat, passes: Int) {
        let r = ImageRenderer(content: view)
        r.scale = scale
        for _ in 0..<passes {
            _ = r.cgImage
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

private struct SnapshotScene: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var ui: IslandUI
    let mode: IslandMode
    let clock: String

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.22, blue: 0.32), Color(red: 0.42, green: 0.36, blue: 0.55)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 16) {
                Image(systemName: "apple.logo")
                Text("Finder").bold()
                Text("File")
                Text("Edit")
                Text("View")
                Text("Go")
                Text("Window")
                Spacer()
                StatusLabelContent(state: model.statusState)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(clock)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: ui.geo.height)
            .background(Color.black.opacity(0.35))
            .environment(\.colorScheme, .dark)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(.black)
                .frame(width: ui.geo.notchWidth, height: ui.geo.height)
            IslandRoot(model: model, ui: ui, forcedMode: mode)
        }
    }
}

/// The app icon: the island on a dark graphite tile, holding one event and a thin time-left line.
private struct IconArt: View {
    private let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
    private let coral = Color(nsColor: NSColor(hex: 0xFF6B5E))

    var body: some View {
        ZStack {
            tile.fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x2C2C31)), Color(nsColor: NSColor(hex: 0x111113))],
                                     startPoint: .top, endPoint: .bottom))
            tile.fill(LinearGradient(colors: [.white.opacity(0.09), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
            tile.strokeBorder(.white.opacity(0.08), lineWidth: 3)

            VStack(spacing: 64) {
                Capsule()
                    .fill(Color.black)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 3))
                    .frame(width: 580, height: 176)
                    .overlay(
                        HStack(spacing: 34) {
                            Circle().fill(coral).frame(width: 56, height: 56)
                                .shadow(color: coral.opacity(0.8), radius: 18)
                            Capsule().fill(.white.opacity(0.92)).frame(width: 250, height: 34)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 62)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 14)

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(coral).frame(width: 250)
                }
                .frame(width: 430, height: 16)
            }
            .offset(y: -10)
        }
        .frame(width: 824, height: 824)
        .clipShape(tile)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .frame(width: 1024, height: 1024)
    }
}
