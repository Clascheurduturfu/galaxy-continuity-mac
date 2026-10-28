import SwiftUI

struct DeviceBatteryBadge: View {
    let percent: Int
    private var symbol: String {
        switch percent {
        case ...10: return "battery.0percent"
        case ...35: return "battery.25percent"
        case ...60: return "battery.50percent"
        case ...85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    var body: some View {
        Label("\(percent)%", systemImage: symbol)
            .font(.caption).foregroundStyle(percent <= 15 ? Color.orange : Color.secondary)
            .help("Battery level reported by this Galaxy over authenticated Bluetooth. Cached for up to five minutes; charging state is not reported.")
            .accessibilityLabel("Battery \(percent) percent")
    }
}
