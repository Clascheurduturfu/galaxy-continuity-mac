import Foundation
import CoreWLAN
import CoreLocation

@MainActor public final class HotspotJoiner: NSObject, @preconcurrency CLLocationManagerDelegate {
    private var location: CLLocationManager?
    private var permission: CheckedContinuation<Void, Error>?
    public var progress: ((String) -> Void)?
    public override init() { super.init() }
    public func join(_ credentials: HotspotCredentials) async throws {
        guard permission == nil else { throw ContinuityError.message("A Wi-Fi permission request is already pending.") }
        let manager = CLLocationManager(); location = manager; manager.delegate = self
        progress?("Wi-Fi location authorization state: \(manager.authorizationStatus.rawValue).")
        if manager.authorizationStatus == .notDetermined {
            try await withCheckedThrowingContinuation { continuation in
                permission = continuation; manager.requestWhenInUseAuthorization()
            }
        }
        guard manager.authorizationStatus == .authorizedAlways else {
            throw ContinuityError.message("Allow Galaxy Continuity Lab in System Settings → Privacy & Security → Location Services so macOS can find the phone's Wi-Fi network.")
        }
        for attempt in 0..<4 {
            do { try await Task.detached { try credentials.join() }.value; return }
            catch {
                if attempt == 3 { throw error }
                progress?("Waiting for the phone's hotspot to become visible…")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined, let pending = permission else { return }
        permission = nil
        if manager.authorizationStatus == .authorizedAlways { pending.resume() }
        else { pending.resume(throwing: ContinuityError.message("Location permission is required by macOS to discover the hotspot's Wi-Fi network.")) }
    }
}

public struct HotspotCredentials: Decodable, Sendable {
    public var messagetype: Int
    public var isSuccess: Bool?
    public var ssid: String?
    public var password: String?
    public var mhsfailed_reason: Int?
    public static func request() throws -> Data {
        // AutoHotspotMDE v0.C0104l.d(): same-account member type 1,
        // conservative 2.4/5 GHz and WPA2 capabilities.
        try JSONSerialization.data(withJSONObject: ["version": 1, "messagetype": 3, "membertype": 1, "clientsupportedhighband": 5, "clientsupportedband": 3, "wpa3personalsupport": 0, "owesupport": 0])
    }
    public func join() throws {
        guard isSuccess == true, let ssid, !ssid.isEmpty, let password else { throw ContinuityError.message("The phone did not return hotspot credentials (reason \(mhsfailed_reason ?? -1)).") }
        guard let interface = CWWiFiClient.shared().interface() else { throw ContinuityError.message("No Mac Wi-Fi interface is available.") }
        let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
        guard let network = networks.first(where: { $0.ssid == ssid }) else { throw ContinuityError.message("The phone enabled its hotspot, but the Mac cannot find its Wi-Fi network. Check Wi-Fi and macOS location permission.") }
        try interface.associate(to: network, password: password)
        guard interface.ssid() == ssid else { throw ContinuityError.message("Wi-Fi association did not complete.") }
    }
}
