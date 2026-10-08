import Combine
import SpaceKitCore
import SwiftUI

/// First-run guide: what SpaceKit does, Full Disk Access, the safety promise, and configuration.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var hasAccess = FullDiskAccess.isGranted
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: access
                case 2: safety
                default: configure
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4) { index in
                        Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 3 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Scan My Disk") { finish(scan: true) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .onReceive(timer) { _ in hasAccess = FullDiskAccess.isGranted }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "internaldrive").font(.system(size: 44)).foregroundStyle(Theme.categorical[0])
            Text("Understand your Mac.\nAutomate the cleanup.").font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                feature("circle.circle", "Explore", "An interactive map of the whole disk, hidden folders included.")
                feature(
                    "hammer", "Dev Intelligence", "Recognises Xcode, Node, Python, Rust, Docker and more, and says what's safe to remove.")
                feature("cpu", "AI Development", "Ollama, Hugging Face, LM Studio: what you use, and what's been idle for months.")
                feature("clock.arrow.2.circlepath", "Automation", "Rules that observe, suggest or clean on schedule, within strict limits.")
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(hasAccess ? Theme.good : Theme.warning)
            Text("Full Disk Access").font(.title.weight(.semibold))
            Text(
                "macOS hides Mail, Messages, Safari, other apps' containers and parts of Library from every app unless you allow it. Without access, SpaceKit still works, but that space shows up as “Hidden”."
            )
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open System Settings → Privacy & Security → Full Disk Access")
                Text("2. Turn on SpaceKit (or click + and choose it)")
                Text("3. Quit and reopen SpaceKit if asked")
            }
            .font(.callout)
            HStack {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                if hasAccess {
                    Label("Access granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else {
                    Label("Not granted yet", systemImage: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            Text("SpaceKit reads file names and sizes. It never reads file contents and never sends anything anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.shield").font(.system(size: 40)).foregroundStyle(Theme.good)
            Text("Our safety promise").font(.title.weight(.semibold))
            SafetyPromiseList()
        }
    }

    private var configure: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 40)).foregroundStyle(Theme.categorical[0])
            Text("Settings your way").font(.title.weight(.semibold))
            Text(
                "Use the Settings window, or edit a YAML file you can keep in your dotfiles. Both change the same file, and the command-line tool and terminal UI read it too."
            )
            .foregroundStyle(.secondary)
            Text(PathUtil.abbreviate(model.paths.configFile)).font(.callout.monospaced())
            HStack { ConfigFileButtons() }
            Text(
                "The starter config includes three example jobs (Xcode DerivedData, stale node_modules, package caches). They only run once you install the background agent in Automation."
            )
            .font(.caption).foregroundStyle(.secondary)
            Text("Terminal: `spacekit tui` · `spacekit dev` · `spacekit --help`").font(.callout.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(Theme.categorical[0])
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish(scan: Bool) {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        dismiss()
        if scan && model.tree == nil { model.scan() }
    }
}

struct SafetyPromiseList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            promise("eye", "Nothing is removed without a preview. Every item shows exactly why it's safe, risky, or refused.")
            promise(
                "lock",
                "Your disk, volumes, home folder, Documents, Desktop, photos, credentials and system folders can never be removed, and neither can anything that contains them."
            )
            promise(
                "chevron.left.forwardslash.chevron.right",
                "Git repositories are never removed automatically, and by hand only after you confirm.")
            promise("trash", "By default everything goes to the Trash, so you can put it back.")
            promise(
                "clock",
                "Automatic jobs only touch regenerable data that a rule recognises, stay under a per-run limit, and tell you what they did."
            )
            promise("person", "SpaceKit never runs as root and never deletes as root.")
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Theme.good)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SafetySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Safety Guidelines").font(.title2.weight(.semibold))
            SafetyPromiseList()
            Text(
                "These rules live in one place (SafetyGuard) that the app, the terminal UI, the command-line tool and the background agent all go through. Your config can add protected folders but can't remove the built-in protections. Full details: docs/SAFETY.md."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
