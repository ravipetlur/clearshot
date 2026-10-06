import CoreGraphics
@testable import CSCapture

extension WindowRecord {
    static func fixture(id: UInt32, frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300), layer: Int = 0,
                        owner: String = "Safari", bundleID: String? = "com.apple.Safari", alpha: Double = 1,
                        isOnScreen: Bool = true, title: String? = nil) -> WindowRecord {
        WindowRecord(id: id, frame: frame, layer: layer, ownerPID: 100, ownerName: owner, ownerBundleID: bundleID,
                     title: title ?? "Window \(id)", alpha: alpha, isOnScreen: isOnScreen)
    }
}
