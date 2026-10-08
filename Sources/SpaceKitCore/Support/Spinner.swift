import Foundation

/// The braille spinner the terminal front ends show while something runs.
public enum Spinner {
    public static let frames: [Character] = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// The frame for the `tick`th redraw.
    public static func frame(_ tick: Int) -> Character { frames[abs(tick) % frames.count] }

    /// The frame for a moment in time, ten frames a second, for screens that redraw at their own pace.
    public static func frame(at date: Date = Date()) -> Character { frame(Int(date.timeIntervalSince1970 * 10)) }
}
