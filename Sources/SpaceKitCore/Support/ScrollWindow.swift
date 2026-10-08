/// The part of a list a screen shows, moved as little as possible to keep the selected row in view.
///
/// Every result is a valid range of the list for any input, including a screen with no room for a single
/// row, an empty list and a selection past the end.
public struct ScrollWindow: Equatable, Sendable {
    public private(set) var offset: Int

    public init(offset: Int = 0) { self.offset = max(0, offset) }

    /// Scrolls so `selection` is visible in `visible` rows of a `count`-row list and returns the rows to draw.
    public mutating func follow(selection: Int, visible: Int, count: Int) -> Range<Int> {
        let count = max(0, count)
        let visible = max(0, visible)
        guard count > 0, visible > 0 else {
            offset = 0
            return 0..<0
        }
        let selection = min(max(selection, 0), count - 1)
        var start = offset
        if selection < start { start = selection }
        if selection >= start + visible { start = selection - visible + 1 }
        offset = min(max(start, 0), max(0, count - visible))
        return offset..<min(count, offset + visible)
    }
}
