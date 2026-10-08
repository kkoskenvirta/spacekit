import Foundation

extension PathUtil {
    /// A path typed on the command line or stored in a plan, made absolute. Unlike `expand`, it neither trims whitespace nor
    /// replaces `$HOME`: the shell already did its expansion, and `"report "` names a different file than
    /// `report`. Only a leading `~` or `~/` is expanded, for arguments the shell left quoted.
    public static func expandArgument(_ path: String, home: String = PathUtil.home) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return standardize(home + path.dropFirst(1)) }
        return standardize(path)
    }
}
