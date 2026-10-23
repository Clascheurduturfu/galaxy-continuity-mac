import Foundation

public enum DeviceSide: String, Codable, CaseIterable, Sendable {
    case left, right, above, below
    public var title: String { rawValue.capitalized }
}

/// Normalized placement survives display resolution changes. Screen ID 0 follows the main screen.
public struct DevicePlacement: Codable, Equatable, Sendable {
    public var side: DeviceSide
    public var offset: Double
    public var screenID: UInt32
    public init(side: DeviceSide = .right, offset: Double = 0, screenID: UInt32 = 0) {
        self.side = side; self.offset = min(0.65, max(-0.65, offset.isFinite ? offset : 0)); self.screenID = screenID
    }
    /// A central portal avoids hot corners. Offset moves its center along the selected edge.
    public func containsPortal(_ fraction: Double) -> Bool {
        fraction.isFinite && abs(fraction - (0.5 + offset * 0.5)) <= 0.28
    }
    /// Host coordinates use top-left origin, just like the Samsung layout protocol.
    public func remoteOrigin(hostWidth: Int, hostHeight: Int, remoteWidth: Int, remoteHeight: Int) -> (x: Int, y: Int) {
        switch side {
        case .left: return (-remoteWidth, Int(Double(hostHeight - remoteHeight) / 2 + Double(hostHeight) * offset * 0.5))
        case .right: return (hostWidth, Int(Double(hostHeight - remoteHeight) / 2 + Double(hostHeight) * offset * 0.5))
        case .above: return (Int(Double(hostWidth - remoteWidth) / 2 + Double(hostWidth) * offset * 0.5), -remoteHeight)
        case .below: return (Int(Double(hostWidth - remoteWidth) / 2 + Double(hostWidth) * offset * 0.5), hostHeight)
        }
    }
    public func remoteEntry(width: Int, height: Int, fraction: Double) -> (x: Int, y: Int) {
        let t = min(1, max(0, fraction.isFinite ? fraction : 0.5))
        switch side {
        case .left: return (max(0, width - 3), Int(Double(max(0, height - 1)) * t))
        case .right: return (min(2, max(0, width - 1)), Int(Double(max(0, height - 1)) * t))
        case .above: return (Int(Double(max(0, width - 1)) * t), max(0, height - 3))
        case .below: return (Int(Double(max(0, width - 1)) * t), min(2, max(0, height - 1)))
        }
    }
}
