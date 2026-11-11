import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: IslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = CalendarModel()
        controller = IslandController(model: model)
        model.start()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        // Renders design previews with sample events, no calendar access needed.
        Snapshot.run(into: args[i + 1])
        exit(0)
    }

    if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
        Snapshot.icon(to: args[i + 1])
        exit(0)
    }

    if args.contains("--debug-colors") {
        Task { await DebugDump.colors(); exit(0) }
        RunLoop.main.run()
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
