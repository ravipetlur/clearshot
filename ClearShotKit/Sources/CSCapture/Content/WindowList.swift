import AppKit
import CoreGraphics

public enum WindowList {
    /// On-screen windows, front to back, from CGWindowList. Titles need Screen Recording permission.
    @MainActor
    public static func onScreen() -> [WindowRecord] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var bundleIDs: [Int32: String?] = [:]
        return info.compactMap { entry -> WindowRecord? in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if bundleIDs[pid] == nil {
                bundleIDs[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            return WindowRecord(
                id: number.uint32Value,
                frame: frame,
                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                ownerPID: pid,
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                ownerBundleID: bundleIDs[pid] ?? nil,
                title: entry[kCGWindowName as String] as? String,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            )
        }
    }
}
