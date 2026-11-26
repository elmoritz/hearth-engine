import Foundation

/// The drawable size for a layout (E-LIFE-4, pitfall 2.18).
///
/// `points x scale`, rounded to whole pixels, each side at least 1 and at most the device's texture limit. A size
/// or scale that is not positive and finite has no drawable: no frame is drawn until the next layout.
struct PixelSize: Sendable, Hashable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init?(points: CGSize, scale: CGFloat, maxSide: Int) {
        let width = Double(points.width) * Double(scale)
        let height = Double(points.height) * Double(scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let limit = Double(Swift.max(1, maxSide))
        self.width = Int(Swift.min(Swift.max(width.rounded(), 1), limit))
        self.height = Int(Swift.min(Swift.max(height.rounded(), 1), limit))
    }

    var cgSize: CGSize { CGSize(width: width, height: height) }
}
