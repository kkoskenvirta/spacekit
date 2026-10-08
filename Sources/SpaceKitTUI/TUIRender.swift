import CoreGraphics
import Foundation
import SpaceKitCore

extension TUIApp {
    /// Below this the views can't be laid out; the screen says so instead.
    static let minimumSize = (columns: 40, rows: 14)
    /// Header, tab bar and rule above the body; rule and footer below it.
    static let chromeRows = 5

    func isTooSmall(_ size: (columns: Int, rows: Int)) -> Bool {
        size.columns < TUIApp.minimumSize.columns || size.rows < TUIApp.minimumSize.rows
    }

    /// Runs on the UI thread only: it reads the scan tree and records what the views and dialogs showed.
    func render() {
        let (width, height) = terminal.size
        guard !isTooSmall((width, height)) else {
            renderTooSmall(width: width, height: height)
            return
        }
        var lines: [String] = []
        lines.append(headerLine(width: width))
        lines.append(tabLine())
        lines.append(String(repeating: "─", count: width).fg(238))

        let bodyHeight = height - TUIApp.chromeRows
        var body: [String]
        switch state.tab {
        case .explore: body = exploreView(width: width, height: bodyHeight)
        case .dev: body = devView(width: width, height: bodyHeight)
        case .ai: body = aiView(width: width, height: bodyHeight)
        case .jobs: body = jobsView(width: width, height: bodyHeight)
        case .history: body = historyView(width: width, height: bodyHeight)
        }
        body = Array(body.prefix(bodyHeight))
        while body.count < bodyHeight { body.append("") }
        if state.modal != nil { body = overlayModal(on: body, width: width) }
        lines += body
        lines.append(String(repeating: "─", count: width).fg(238))
        lines.append(footerLine(width: width))
        draw(lines, width: width)
    }

    private func draw(_ lines: [String], width: Int) {
        let frame = lines.map { ANSI.fit($0, to: width) }.joined(separator: "\r\n")
        terminal.write("\u{1B}[H" + frame + "\u{1B}[0m\u{1B}[J")
    }

    private func renderTooSmall(width: Int, height: Int) {
        let needed = "\(TUIApp.minimumSize.columns)×\(TUIApp.minimumSize.rows)"
        let message = ["Too small", "Need \(needed)", "Have \(width)×\(height)", "q quits"]
        var lines = Array(repeating: "", count: max(0, (height - message.count) / 2)) + message
        lines = Array(lines.prefix(max(1, height)))
        draw(lines, width: width)
    }

    // MARK: Chrome

    func headerLine(width: Int) -> String {
        let title = " ◆ SpaceKit ".styled(Style(fg: 255, bg: 25, bold: true))
        // The startup warning about an invalid config is hidden by the alternate screen, so it stays up here.
        let tagline =
            context.configError == nil
            ? "  Understand your Mac. Automate the cleanup.".dim
            : "  Config file is invalid; cleaning is off. Run spacekit config validate".bold.fg(ANSI.protected)
        var right = ""
        if let capacity = state.tree?.capacity ?? VolumeCapacity.of(path: state.rootPath) {
            let fraction = capacity.usedFraction
            let color = capacity.fullness.terminalColor
            let usage = "\(ByteCount.format(capacity.used)) / \(ByteCount.format(capacity.total))".bold
            right =
                "\(TerminalText.sanitize(capacity.name))  " + usage + "  " + ANSI.bar(fraction: fraction, width: 16, color: color) + " "
        }
        let gap = max(1, width - ANSI.width(title) - ANSI.width(tagline) - ANSI.width(right))
        return title + tagline + String(repeating: " ", count: gap) + right
    }

    func tabLine() -> String {
        var line = " "
        for tab in Tab.allCases {
            let label = " \(tab.rawValue + 1) \(tab.title) "
            line += tab == state.tab ? label.styled(Style(fg: 255, bg: 238, bold: true)) : label.dim
            line += " "
        }
        return line
    }

    func footerLine(width: Int) -> String {
        if let flash = state.flash, Date() < state.flashUntil { return " " + flash.fg(ANSI.accent) }
        if let activity = state.activity { return " " + spinner() + " " + activity.text }
        let hints: String
        switch state.tab {
        case .explore: hints = "↑↓ move  → open  ← up  t treemap  space mark  d clean  o reveal  r rescan  ? help  q quit"
        case .dev: hints = "↑↓ move  enter details  space mark  d clean  n new job  r refresh  ? help  q quit"
        case .ai: hints = "↑↓ move  d remove model  ? help  q quit"
        case .jobs: hints = "↑↓ move  e enable/disable  m mode  x run now  i install/remove agent  q quit"
        case .history: hints = "Tab switch view  q quit"
        }
        var right = ""
        if state.tab == .explore, !state.marked.isEmpty {
            let total = state.marked.values.reduce(0) { $0 &+ $1.size }
            right = "\(state.marked.count) marked · \(ByteCount.format(total)) ".fg(ANSI.review)
        }
        if state.tab == .dev, !state.markedRules.isEmpty { right = "\(state.markedRules.count) marked ".fg(ANSI.review) }
        let gap = max(1, width - ANSI.width(hints) - ANSI.width(right) - 1)
        return " " + hints.dim + String(repeating: " ", count: gap) + right
    }

    func spinner() -> String {
        String(Spinner.frame()).fg(ANSI.accent)
    }

    /// The selected-row highlight.
    func highlighted(_ line: String) -> String {
        line.styled(Style(bg: 237)) + Style(bg: 237).sequence
    }

    func progressView(_ progress: ScanProgress, title: String, width: Int, height: Int) -> [String] {
        let p = progress.snapshot
        var lines = Array(repeating: "", count: max(0, height / 3))
        lines.append("  " + spinner() + " " + TerminalText.sanitize(title).bold)
        lines.append("")
        lines.append(
            "    " + "\(ByteCount.format(p.bytes))".bold.fg(ANSI.accent)
                + "   \(p.files.formatted()) files · \(p.directories.formatted()) folders")
        lines.append("    " + ANSI.truncateMiddle(TerminalText.sanitize(PathUtil.abbreviate(p.currentPath)), to: width - 8).dim)
        if p.errors > 0 {
            lines.append("")
            let advice = "\(p.errors) locations unreadable — grant Full Disk Access to your terminal for a complete picture"
            lines.append("    " + advice.fg(ANSI.review))
        }
        if progress.liveRoot?.isListed == true {
            lines.append("")
            let children = progress.liveChildren.filter(\.isListed).sorted { $0.liveSize > $1.liveSize }
                .prefix(max(0, height - lines.count - 2))
            let largest = children.first?.liveSize ?? 1
            for child in children where child.liveSize > 0 {
                lines.append(
                    "    " + ANSI.pad(ByteCount.format(child.liveSize), to: 9, alignRight: true) + "  "
                        + ANSI.bar(fraction: Double(child.liveSize) / Double(max(largest, 1)), width: 20, color: ANSI.accent) + "  "
                        + TerminalText.sanitize(child.name))
            }
        }
        return lines
    }

    // MARK: Modal

    /// Lays a dialog out in a body `bodyHeight` rows tall: long lines wrap to the box, and the scrolling rows
    /// get what the borders, the key hint and the pinned footer leave.
    func modalLayout(_ modal: Modal, width: Int, bodyHeight: Int) -> ModalLayout {
        let count = modal.lines.count
        let position = "\(count)–\(count) of \(count) · "
        let hints = [position + TUIApp.scrollToConfirmHint, position + modal.confirmLabel]
        let longest = (modal.lines + modal.footer + hints).map(ANSI.width).max() ?? 0
        let boxWidth = max(10, min(width - 4, max(50, longest + 4, ANSI.width(modal.title) + 8)))
        let inner = boxWidth - 4
        var rows: [(text: String, line: Int)] = []
        var lineRows: [Range<Int>] = []
        for (index, line) in modal.lines.enumerated() {
            let wrapped = ANSI.wrap(line, to: inner)
            lineRows.append(rows.count..<(rows.count + wrapped.count))
            rows += wrapped.map { (text: $0, line: index) }
        }
        let footer = modal.footer.flatMap { ANSI.wrap($0, to: inner) }
        let footerRows = footer.isEmpty ? 0 : footer.count + 1
        let visible = max(0, min(rows.count, bodyHeight - 3 - footerRows))
        return ModalLayout(boxWidth: boxWidth, rows: rows, lineRows: lineRows, footer: footer, visible: visible)
    }

    static let scrollToConfirmHint = "scroll through the list (↓ PgDn) to confirm · n cancel"

    func overlayModal(on body: [String], width: Int) -> [String] {
        guard var modal = state.modal else { return body }
        let layout = modalLayout(modal, width: width, bodyHeight: body.count)
        let range = modal.display(layout)
        state.modal = modal

        let boxWidth = layout.boxWidth
        let inner = boxWidth - 4
        func row(_ line: String) -> String { "│ " + ANSI.fit(ANSI.truncate(line, to: inner), to: inner) + " │" }

        var box: [String] = []
        let title = ANSI.truncate(modal.title, to: max(0, boxWidth - 6))
        box.append("╭─ " + title.bold + " " + String(repeating: "─", count: max(0, boxWidth - ANSI.width(title) - 5)) + "╮")
        for index in range { box.append(row(layout.rows[index].text)) }
        if !layout.footer.isEmpty {
            box.append("├" + String(repeating: "─", count: boxWidth - 2) + "┤")
            for line in layout.footer { box.append(row(line)) }
        }
        box.append(row(modalHint(modal, range: range, total: layout.rows.count).fg(ANSI.accent)))
        box.append("╰" + String(repeating: "─", count: boxWidth - 2) + "╯")

        var result = body
        let top = max(0, (body.count - box.count) / 2)
        let left = max(0, (width - boxWidth) / 2)
        for (offset, line) in box.enumerated() where top + offset < result.count {
            result[top + offset] = String(repeating: " ", count: left) + line.styled(Style(bg: 235)) + Style(bg: 235).sequence
        }
        return result
    }

    private func modalHint(_ modal: Modal, range: Range<Int>, total: Int) -> String {
        if range.isEmpty && total > 0 { return "Make the window taller to see this list · n close" }
        let position = range.count < total ? "\(range.lowerBound + 1)–\(range.upperBound) of \(total) · " : ""
        guard modal.onConfirm != nil else {
            return position + (position.isEmpty ? "any key to close" : "↑↓ scroll · other keys close")
        }
        guard modal.hasShownEveryLine else { return position + TUIApp.scrollToConfirmHint }
        return position + modal.confirmLabel
    }

    // MARK: Explore

    func exploreView(width: Int, height: Int) -> [String] {
        if let progress = state.scanProgress {
            return progressView(progress, title: "Scanning \(PathUtil.abbreviate(state.rootPath))…", width: width, height: height)
        }
        if let error = state.error { return ["", "  " + error.fg(ANSI.protected)] }
        guard let current = state.current, let tree = state.tree else { return [] }

        var lines: [String] = []
        let crumbs = current.path.isEmpty ? "Scan" : TerminalText.sanitize(PathUtil.abbreviate(current.path))
        let info = "\(ByteCount.format(current.size))".bold + "  \(current.fileCount.formatted()) files".dim
        var label = ""
        if let rule = state.ruleIndex.rule(for: current.path) {
            label = "  " + TerminalText.sanitize(rule.name).fg(ANSI.color(for: rule.safety.level))
        }
        lines.append(" " + ANSI.truncateMiddle(crumbs, to: width / 2).bold + label + "   " + info)
        if tree.stats.errors > 0 && current === tree.root {
            lines.append(
                " "
                    + "\(tree.stats.errors) folders couldn't be read (privacy-protected). Grant Full Disk Access to see everything.".fg(
                        ANSI.review))
        }
        lines.append("")
        let available = max(0, height - lines.count)
        if state.mapMode {
            return lines + treemapView(current, selection: state.explore.selection, width: width, height: available)
        }
        return lines + listView(current, width: width, height: available)
    }

    func listView(_ current: DirNode, width: Int, height: Int) -> [String] {
        let items = current.items
        guard !items.isEmpty else { return ["   (empty)".dim] }
        let largest = Double(max(items.first?.size ?? 1, 1))
        let total = Double(max(current.size, 1))
        let barWidth = max(8, min(30, width / 5))
        let nameWidth = max(12, width - barWidth - 46)
        var lines: [String] = []
        for index in state.explore.visibleRows(height, count: items.count) {
            let item = items[index]
            let path = item.path ?? ""
            let marker = state.marked[path] != nil ? "◉".fg(ANSI.review) : " "
            let glyph = item.isDirectory ? "▸" : " "
            let name = TerminalText.sanitize(item.name) + (item.isDirectory ? "/" : "")
            let size = ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true)
            let percent = ANSI.pad(String(format: "%.0f%%", Double(item.size) / total * 100), to: 4, alignRight: true)
            let color = ANSI.branches[index % ANSI.branches.count]
            let bar = ANSI.bar(fraction: Double(item.size) / largest, width: barWidth, color: color)
            let note = item.note(rule: path.isEmpty ? nil : state.ruleIndex.rule(for: path))?.terminalText ?? ""
            let row =
                " \(marker) \(glyph) " + ANSI.pad(ANSI.truncate(name, to: nameWidth), to: nameWidth) + " \(size)  \(bar) \(percent)  " + note
            lines.append(index == state.explore.selection ? highlighted(row) : row)
        }
        return lines
    }

    /// Squarified treemap drawn with colored cells. Terminal cells are about twice as tall as wide,
    /// so the layout runs in a space with doubled height to keep cells visually square.
    func treemapView(_ node: DirNode, selection: Int, width: Int, height: Int) -> [String] {
        guard height > 2, width > 10 else { return [] }
        let cells = Treemap.layout(
            node, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height * 2)),
            maxDepth: 2, minCellArea: 6, padding: 0)
        var grid = Array(
            repeating: Array(repeating: (character: Character(" "), fg: UInt8(255), bg: UInt8(235)), count: width), count: height)
        let items = node.items
        let selectedID = items.indices.contains(selection) ? MapItem.item(items[selection]).id : nil
        let shades: [[UInt8]] = [
            [25, 31], [30, 37], [28, 34], [136, 178], [130, 166], [125, 162], [54, 92], [60, 67], [100, 142], [95, 132], [23, 29],
            [94, 137],
        ]

        for cell in cells {
            let x0 = Int(cell.rect.minX.rounded())
            let x1 = Int(cell.rect.maxX.rounded())
            let y0 = Int((cell.rect.minY / 2).rounded())
            let y1 = Int((cell.rect.maxY / 2).rounded())
            guard x1 > x0, y1 > y0 else { continue }
            let palette = shades[max(0, cell.branch) % shades.count]
            var bg = cell.depth == 0 ? palette[0] : palette[cell.id.hashValue & 1]
            if case .remainder = cell.item { bg = 239 }
            let isSelected = cell.depth == 0 && cell.id == selectedID
            if isSelected { bg = 250 }
            for y in max(0, y0)..<max(max(0, y0), min(height, y1)) {
                for x in max(0, x0)..<max(max(0, x0), min(width, x1)) {
                    grid[y][x] = (" ", isSelected ? 232 : 255, bg)
                }
            }
            // Label at the top-left of cells that have room. Wide characters would shift the row, so
            // the label keeps only one-column characters.
            if cell.depth == 0 || (x1 - x0 >= 10 && y1 - y0 >= 2) {
                let text = TerminalText.sanitize(" \(cell.item.name) \(ByteCount.format(cell.item.size))")
                let label = text.filter { TerminalWidth.columns($0) == 1 }
                let row = max(0, min(height - 1, y0))
                for (offset, character) in label.prefix(max(0, x1 - x0 - 1)).enumerated() where x0 + offset >= 0 && x0 + offset < width {
                    grid[row][x0 + offset].character = character
                }
            }
            // Thin separators between top-level cells.
            if cell.depth == 0 && x0 > 0 && x0 < width {
                for y in max(0, y0)..<max(max(0, y0), min(height, y1)) where grid[y][x0].character == " " {
                    grid[y][x0].character = "▏"
                    grid[y][x0].fg = 235
                }
            }
        }
        return grid.map { row in
            var line = ""
            var last: (UInt8, UInt8)?
            for cell in row {
                if last == nil || last! != (cell.fg, cell.bg) {
                    line += ANSI.enabled ? Style(fg: cell.fg, bg: cell.bg).sequence : ""
                    last = (cell.fg, cell.bg)
                }
                line.append(cell.character)
            }
            return line + ANSI.reset
        }
    }
}
