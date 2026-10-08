#if DEBUG
    import AppKit
    import SpaceKitCore
    import SwiftUI

    /// Development helper for screenshots and UI checks without Screen Recording permission.
    ///
    /// Set `SPACEKIT_DEBUG_DIR` to a folder. Writing a `request` file there containing lines like
    /// `section=explore`, `visualization=treemap`, `color=category`, `depth=3`, `focus=~/Library`, `scan=~`,
    /// `select=Developer` and `snapshot=explore.png` makes the app apply them and save a PNG of its window
    /// into the folder. Debug builds only.
    @MainActor
    enum DebugAutomation {
        static func start(model: AppModel) {
            guard let directory = ProcessInfo.processInfo.environment["SPACEKIT_DEBUG_DIR"] else { return }
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { poll(directory: directory, model: model) }
            }
        }

        private static func poll(directory: String, model: AppModel) {
            let request = directory + "/request"
            guard let text = try? String(contentsOfFile: request, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(atPath: request)
            var snapshot: String?
            var sheet: String?
            for (key, value) in settings(in: text) {
                switch key {
                case "sheet": sheet = value
                case "snapshot":
                    // A bare file name only, so the PNG lands inside the debug folder.
                    guard !value.contains("/"), value != ".", value != "..", !value.isEmpty else {
                        try? "refused: snapshot must be a file name, not a path\n".appendLine(to: directory + "/events.log")
                        break
                    }
                    snapshot = value
                case "confirm-cleanup": confirmCleanup(directory: directory, model: model)
                default: apply(key, value, to: model)
                }
            }
            showSheet(sheet, model: model)
            if let snapshot {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated { save(directory + "/" + snapshot) }
                }
            }
        }

        /// The request's `key=value` lines, in order.
        private static func settings(in text: String) -> [(key: String, value: String)] {
            text.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        }

        /// One setting that changes what the window shows.
        private static func apply(_ key: String, _ value: String, to model: AppModel) {
            switch key {
            case "section": if let section = AppSection(rawValue: value) { model.section = section }
            case "visualization": if let v = UISettings.Visualization(rawValue: value) { model.visualization = v }
            case "color": if let c = UISettings.ColorMode(rawValue: value) { model.colorMode = c }
            case "depth": if let d = Int(value) { model.mapDepth = d }
            case "scan": model.scan(value)
            case "focus": if let node = model.tree?.node(at: PathUtil.expand(value)) { model.focus = node }
            case "select":
                if let item = model.focus?.items.first(where: { $0.name == value }) { model.selection = .item(item) }
            case "hover":
                if let item = model.focus?.items.first(where: { $0.name == value }) {
                    model.hovered = .item(item)
                } else {
                    model.hovered = nil
                }
            case "close":
                model.pendingCleanup = nil
                model.jobDraft = nil
                model.showOnboarding = false
                model.showSafety = false
            default: break
            }
        }

        private static func confirmCleanup(directory: String, model: AppModel) {
            // Only ever inside a throwaway sandbox home, so a debug hook can't touch real data:
            // the home must be a temp folder, every item must live inside it, and tool commands
            // (which act system-wide, e.g. `brew cleanup`) are refused outright. The home is resolved
            // because scanned paths are: a `/tmp/…` sandbox shows up as `/private/tmp/…` in the plan.
            // Items are deleted, never moved to the Trash: the Trash is the real one, outside the sandbox.
            let home = PathUtil.realpath(PathUtil.home) ?? PathUtil.home
            guard home.hasPrefix("/private/tmp/") || home.hasPrefix("/private/var/folders/"),
                !model.config.safety.trashesEverything,
                let pending = model.pendingCleanup,
                pending.plan.commands.isEmpty,
                !pending.plan.items.isEmpty,
                pending.plan.items.allSatisfy({ PathUtil.isStrictAncestor(home, of: $0.path) })
            else {
                try? "refused: plan is not confined to the sandbox home, or the config sends everything to the Trash\n"
                    .appendLine(to: directory + "/events.log")
                return
            }
            let started = Date()
            var deleting = pending.plan
            deleting.useTrash = false
            let plan = deleting
            Task {
                // Through the review like every manual run, accepting no warnings: nobody saw them, so only
                // items the guard allows outright are removed.
                let review = await model.cleanupReview(of: plan)
                _ = await model.execute(review.acknowledge(acceptingWarnings: false), run: pending.run, onProgress: { _, _, _ in })
                model.pendingCleanup = nil
                let elapsed = Date().timeIntervalSince(started)
                try? "cleanup applied in \(elapsed)s; analysing=\(model.isAnalysing)\n"
                    .appendLine(to: directory + "/events.log")
            }
        }

        private static func showSheet(_ sheet: String?, model: AppModel) {
            switch sheet {
            case "onboarding": model.showOnboarding = true
            case "safety": model.showSafety = true
            case "job": model.jobDraft = JobDraft(rule: model.library.rule(id: "xcode.derived-data") ?? model.library.rules[0])
            case let value? where value.hasPrefix("cleanup:"):
                let ruleID = String(value.dropFirst("cleanup:".count))
                if let finding = model.analysis?.finding(ruleID: ruleID) { model.reviewFinding(finding) }
            case "cleanup":
                if let finding = model.analysis?.findings.first(where: { $0.isCleanable }) { model.reviewFinding(finding) }
            case "settings":
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            default: break
            }
        }

        private static func save(_ path: String) {
            // Prefer an attached sheet if one is showing; otherwise the main window.
            let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
            let key = NSApp.keyWindow.flatMap { windows.contains($0) ? $0 : nil }
            guard let window = windows.first(where: { $0.isSheet }) ?? key ?? windows.max(by: { $0.frame.width < $1.frame.width }),
                let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    extension String {
        func appendLine(to path: String) throws {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(utf8))
                try handle.close()
            } else {
                try write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
#endif
