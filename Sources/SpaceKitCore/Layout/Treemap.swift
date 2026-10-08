import CoreGraphics
import Foundation

/// Something drawn in a disk map: a real item, or the merged remainder of items too small to see.
public enum MapItem: Sendable, Hashable, Identifiable {
    case item(DiskItem)
    case remainder(parent: DirNode, count: Int, size: UInt64)

    public var id: String {
        switch self {
        case .item(let item): return item.id
        case .remainder(let parent, _, _): return "r:\(parent.address)"
        }
    }

    public var size: UInt64 {
        switch self {
        case .item(let item): return item.size
        case .remainder(_, _, let size): return size
        }
    }

    public var name: String {
        switch self {
        case .item(let item): return item.name
        case .remainder(_, let count, _): return "\(count) more items"
        }
    }

    public var directory: DirNode? {
        if case .item(let item) = self { return item.directory }
        return nil
    }

    public var diskItem: DiskItem? {
        if case .item(let item) = self { return item }
        return nil
    }

    public var path: String? { diskItem?.path }
}

public struct TreemapCell: Sendable, Identifiable {
    public let item: MapItem
    public let rect: CGRect
    /// 0 for the direct children of the laid-out directory.
    public let depth: Int
    /// Index of the top-level ancestor cell, handy for coloring by branch.
    public let branch: Int
    public var id: String { item.id }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
public enum Treemap {
    /// Lays out `weights` (any order, non-negative) inside `rect`. Returns one rectangle per weight,
    /// in the same order. Cells come out close to square, which keeps them readable and clickable.
    public static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        let order = weights.indices.filter { weights[$0] > 0 }.sorted { weights[$0] > weights[$1] }
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { weights[$0] * scale }

        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start
            var sum = 0.0
            var worst = Double.infinity
            while end < areas.count {
                let candidateSum = sum + areas[end]
                let candidateWorst = worstAspect(maxArea: areas[start], minArea: areas[end], sum: candidateSum, side: side)
                if end > start && candidateWorst > worst { break }
                worst = candidateWorst
                sum = candidateSum
                end += 1
            }

            let isLastRow = end == areas.count
            if remaining.width >= remaining.height {
                // Vertical strip along the left edge.
                let width = isLastRow ? remaining.width : CGFloat(sum / Double(remaining.height))
                var y = remaining.minY
                for index in start..<end {
                    let height = index == end - 1 ? remaining.maxY - y : CGFloat(areas[index] / Double(width))
                    result[order[index]] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(
                    x: remaining.minX + width, y: remaining.minY,
                    width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // Horizontal strip along the top edge.
                let height = isLastRow ? remaining.height : CGFloat(sum / Double(remaining.width))
                var x = remaining.minX
                for index in start..<end {
                    let width = index == end - 1 ? remaining.maxX - x : CGFloat(areas[index] / Double(height))
                    result[order[index]] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(
                    x: remaining.minX, y: remaining.minY + height,
                    width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return result
    }

    private static func worstAspect(maxArea: Double, minArea: Double, sum: Double, side: Double) -> Double {
        let s2 = side * side
        let sum2 = sum * sum
        return max(s2 * maxArea / sum2, sum2 / (s2 * minArea))
    }

    /// Nested treemap of a directory.
    ///
    /// - Parameters:
    ///   - maxDepth: how many directory levels to nest (1 = only direct children).
    ///   - minCellArea: items that would be smaller than this (in points²) are merged into one remainder cell.
    ///   - padding: inset applied to a directory before laying out its children.
    ///   - headerHeight: space reserved at the top of a directory cell for its label, when it's big enough.
    public static func layout(
        _ directory: DirNode,
        in rect: CGRect,
        maxDepth: Int = 3,
        minCellArea: CGFloat = 24,
        padding: CGFloat = 2,
        headerHeight: CGFloat = 0
    ) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        cells.reserveCapacity(1024)
        var queue: [(DirNode, CGRect, Int, Int)] = [(directory, rect, 0, -1)]
        var head = 0
        while head < queue.count {
            let (node, area, depth, branch) = queue[head]
            head += 1
            let mapItems = visibleItems(of: node, area: area.width * area.height, minCellArea: minCellArea)
            let rects = squarify(mapItems.map { Double($0.size) }, in: area)
            for (index, (item, cellRect)) in zip(mapItems, rects).enumerated() where cellRect.width > 0 && cellRect.height > 0 {
                let cellBranch = depth == 0 ? index : branch
                cells.append(TreemapCell(item: item, rect: cellRect, depth: depth, branch: cellBranch))
                guard depth + 1 < maxDepth, let child = item.directory, !child.children.isEmpty || !child.files.isEmpty else { continue }
                var inner = cellRect.insetBy(dx: padding, dy: padding)
                let header = inner.height > headerHeight * 3 && inner.width > 48 ? headerHeight : 0
                inner = CGRect(x: inner.minX, y: inner.minY + header, width: inner.width, height: inner.height - header)
                if inner.width * inner.height >= minCellArea * 4, inner.width > 4, inner.height > 4 {
                    queue.append((child, inner, depth + 1, cellBranch))
                }
            }
        }
        return cells
    }

    /// Items of a directory that are big enough to draw, plus one remainder for the rest.
    public static func visibleItems(of node: DirNode, area: CGFloat, minCellArea: CGFloat) -> [MapItem] {
        let items = node.items
        guard node.size > 0, area > 0 else { return [] }
        let bytesPerPoint = Double(node.size) / Double(area)
        let split = split(items, minBytes: UInt64(Double(minCellArea) * bytesPerPoint))
        var result = split.visible.map(MapItem.item)
        if split.restCount == 1, let last = items.last {
            result.append(.item(last))
        } else if split.restCount > 1, split.restSize > 0 {
            result.append(.remainder(parent: node, count: split.restCount, size: split.restSize))
        }
        return result
    }

    /// Splits items (largest first) into those big enough to draw (at least `minBytes`, and not empty)
    /// and the count and size of the rest.
    static func split(_ items: [DiskItem], minBytes: UInt64) -> (visible: [DiskItem], restCount: Int, restSize: UInt64) {
        var visible: [DiskItem] = []
        var restSize: UInt64 = 0
        var restCount = 0
        for item in items {
            if item.size >= minBytes && item.size > 0 {
                visible.append(item)
            } else {
                restSize += item.size
                restCount += 1
            }
        }
        return (visible, restCount, restSize)
    }

    /// The deepest cell containing `point`.
    public static func hitTest(_ cells: [TreemapCell], at point: CGPoint) -> TreemapCell? {
        cells.last { $0.rect.contains(point) }
    }
}
