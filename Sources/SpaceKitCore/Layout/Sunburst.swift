import CoreGraphics
import Foundation

public struct SunburstArc: Sendable, Identifiable {
    public let item: MapItem
    /// Ring index, 1 for the direct children of the center directory.
    public let ring: Int
    /// Radians, measured clockwise from 12 o'clock.
    public let startAngle: Double
    public let endAngle: Double
    /// Index of the ring-1 ancestor, for coloring by branch.
    public let branch: Int
    public var id: String { item.id }
    public var sweep: Double { endAngle - startAngle }
    public var midAngle: Double { (startAngle + endAngle) / 2 }
}

/// Radial "sector" layout: the center is the current directory, each ring one level deeper,
/// and each arc's sweep proportional to its size.
public enum Sunburst {
    public static func layout(_ directory: DirNode, maxRings: Int = 5, minSweep: Double = 0.006) -> [SunburstArc] {
        var arcs: [SunburstArc] = []
        arcs.reserveCapacity(2048)
        var queue: [(DirNode, Double, Double, Int, Int)] = [(directory, 0, 2 * .pi, 1, -1)]
        var head = 0
        while head < queue.count {
            let (node, start, end, ring, branch) = queue[head]
            head += 1
            guard node.size > 0 else { continue }
            let sweep = end - start
            let radiansPerByte = sweep / Double(node.size)
            var angle = start
            // Integer sizes: size >= ceil(x) exactly when size * radiansPerByte >= minSweep.
            let (visible, restCount, restSize) = Treemap.split(node.items, minBytes: UInt64((minSweep / radiansPerByte).rounded(.up)))
            for (index, item) in visible.enumerated() {
                let itemSweep = Double(item.size) * radiansPerByte
                let arcBranch = ring == 1 ? index : branch
                let arc = SunburstArc(item: .item(item), ring: ring, startAngle: angle, endAngle: angle + itemSweep, branch: arcBranch)
                arcs.append(arc)
                if ring < maxRings, let child = item.directory {
                    queue.append((child, angle, angle + itemSweep, ring + 1, arcBranch))
                }
                angle += itemSweep
            }
            if restCount > 0, restSize > 0 {
                let restSweep = Double(restSize) * radiansPerByte
                if restSweep >= minSweep / 2 {
                    arcs.append(
                        SunburstArc(
                            item: .remainder(parent: node, count: restCount, size: restSize),
                            ring: ring, startAngle: angle, endAngle: angle + restSweep,
                            branch: ring == 1 ? visible.count : branch))
                }
            }
        }
        return arcs
    }

    /// Finds the arc under `point` for a chart centered at `center` whose rings start at `innerRadius`
    /// and are `ringWidth` thick. Returns `nil` for the center disc (meaning "go up").
    public static func hitTest(_ arcs: [SunburstArc], at point: CGPoint, center: CGPoint, innerRadius: CGFloat, ringWidth: CGFloat)
        -> SunburstArc?
    {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= Double(innerRadius) else { return nil }
        let ring = Int((radius - Double(innerRadius)) / Double(ringWidth)) + 1
        // atan2 measured from 12 o'clock, clockwise, in 0..<2π. Screen y grows downward.
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return arcs.first { $0.ring == ring && angle >= $0.startAngle && angle < $0.endAngle }
    }
}
