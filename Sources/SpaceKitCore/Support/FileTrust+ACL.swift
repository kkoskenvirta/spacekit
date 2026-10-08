import Foundation

extension FileTrust {
    /// What lets someone change a file's contents, its metadata or who may change it.
    static let fileWrites: [acl_perm_t] = [
        ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_CHANGE_OWNER,
        ACL_WRITE_SECURITY,
    ]

    /// What lets someone put a different file in a folder, or change who may.
    static let folderWrites: [acl_perm_t] = [
        ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_CHANGE_OWNER, ACL_WRITE_SECURITY,
    ]

    /// True if the access control list of `path` (not followed if it's a symlink) allows any of `permissions` to
    /// someone other than `owner` or root. Deny entries don't matter here, and a path without an ACL has none.
    static func aclAllowsOthers(_ path: String, _ permissions: [acl_perm_t], owner: uid_t) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let trusted = [owner, 0].compactMap(uuid)
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            which = ACL_NEXT_ENTRY.rawValue
            guard allows(current, permissions) else { continue }
            guard let qualifier = acl_get_qualifier(current) else { return true }
            let who = Array(UnsafeRawBufferPointer(start: qualifier, count: 16))
            acl_free(qualifier)
            if !trusted.contains(who) { return true }
        }
        return false
    }

    /// True if `entry` is an allow entry with any of `permissions`.
    private static func allows(_ entry: acl_entry_t, _ permissions: [acl_perm_t]) -> Bool {
        var tag = acl_tag_t(rawValue: 0)
        var permset: acl_permset_t?
        guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_ALLOW else { return false }
        guard acl_get_permset(entry, &permset) == 0, let permset else { return false }
        return permissions.contains { acl_get_perm_np(permset, $0) == 1 }
    }

    /// The UUID that ACL entries name the account `uid` by. `nil` if it can't be found, which leaves only entries
    /// for nobody trusted: the check fails closed.
    private static func uuid(_ uid: uid_t) -> [UInt8]? {
        // `mbr_uid_to_uuid` is in libSystem, but its header isn't part of the Darwin module in every SDK.
        typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mbr_uid_to_uuid") else { return nil }
        let uidToUUID = unsafeBitCast(symbol, to: UIDToUUID.self)
        var bytes = [UInt8](repeating: 0, count: 16)
        guard uidToUUID(uid, &bytes) == 0 else { return nil }
        return bytes
    }
}
