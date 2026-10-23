import Foundation
import CryptoKit

struct CallingAccountContext {
    let userID: String
    let installationID: String
    let lineID: String
    let primaryID: String
    let servers: [String]
    let headers: [String: String]
    let entitlement: URL
    let devices: [[String: Any]]
    var deviceID: String { "pc_" + Self.uuid5(installationID + userID).replacingOccurrences(of: "-", with: "") }
    static func uuid5(_ name: String) -> String {
        let namespace: [UInt8] = [0x7d,0x51,0x09,0xb9,0x2d,0x79,0x5b,0x72,0xbe,0xf6,0x33,0xf9,0x91,0xe2,0x1f,0xcf]
        var hash = Array(Insecure.SHA1.hash(data: Data(namespace) + Data(name.utf8)).prefix(16))
        hash[6] = (hash[6] & 15) | 0x50; hash[8] = (hash[8] & 63) | 0x80
        let hex = hash.map { String(format: "%02x", $0) }
        return [hex[0..<4],hex[4..<6],hex[6..<8],hex[8..<10],hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }
    var enrollment: [String: Any] {
        ["account_type": "Samsung Account", "device_id": deviceID, "device_name": "Galaxy Continuity Lab for Mac",
         "push_type": "wns", "push_token": "push-token-not-ready", "device_type": "PC", "model_number": "Mac",
         "cmc_version": "2", "include_device_counting": true, "active_services": ["callforking", "calllogv2"],
         "device_data": [
            "general_info": ["version": "1.1.03"], "device_property": ["network_info": ["serial": Self.uuid5(installationID)]],
            "cmc_policy": ["migrate_device": ["value": true], "activation_control": ["value": true],
                           "respective_control": ["value": true], "same_wifi_network": ["value": false], "emergency_call": ["supported": false]],
            "cmc_capability": ["cmc_service_type": ["message_sync": ["supported": false], "call_log_sync": ["supported": true],
                                                   "call_forking": ["supported": true]], "dual_sim_supported": ["supported": true],
                               "contact_sync_mode": ["access_type": 0, "value": 1]],
            "cmc_state": ["cmc_activation_info": ["activation": 1, "call_activation": 1, "message_activation": 0]]]]
    }
}
