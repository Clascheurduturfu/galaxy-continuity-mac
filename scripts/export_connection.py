"""Export only Samsung continuity bootstrap data from the signed-in Windows app.

Requires Python and cryptography. The unlock code is displayed once in the user's
terminal. Neither the Samsung account bearer token nor the database is exported.
"""
import argparse
import base64
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def profile_from_database(path: Path, reuse_device_model: str | None = None) -> dict:
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        account = db.execute("SELECT * FROM SCRetrieveCertificateResponses LIMIT 1").fetchone()
        local = db.execute("SELECT * FROM ThisDeviceInfoes LIMIT 1").fetchone()
        key = db.execute("SELECT * FROM UserAesKeys WHERE ExpireTime > ? ORDER BY ExpireTime LIMIT 1", (int(time.time() * 1000),)).fetchone()
        if account is None or local is None or key is None:
            raise ValueError("Galaxy Connect has no current signed-in continuity profile.")
        if len(base64.b64decode(key["Aes256Key"], validate=True)) != 32:
            raise ValueError("The stored continuity key has an unsupported format.")
        def normalize(address):
            value = re.sub(r"[:-]", "", address or "").upper()
            if not re.fullmatch(r"[0-9A-F]{12}", value):
                raise ValueError("Invalid registered-device identity.")
            return ":".join(value[i:i + 2] for i in range(0, 12, 2))
        registered = list(db.execute("SELECT * FROM DeviceInfoLists ORDER BY ServerCreateTime"))
        if reuse_device_model:
            matches = {normalize(d["BtAddr"]): d for d in registered if d["BtAddr"] and d["DeviceType"] == "pc" and d["DeviceModel"] == reuse_device_model}
            if len(matches) != 1:
                raise ValueError("Choose an exact PC model with one registered Bluetooth identity.")
            local = next(iter(matches.values()))
        local_address = normalize(local["BtAddr"])
        peers = {}
        for device in registered:
            if not device["BtAddr"]:
                continue
            address = normalize(device["BtAddr"])
            if address != local_address:
                peers[address] = {"address": address, "name": device["DeviceName"] or "Samsung device", "deviceType": device["DeviceType"], "model": device["DeviceModel"]}
        if not peers:
            raise ValueError("No other Samsung devices are registered on this account.")
        phones = [p for p in peers.values() if (p["deviceType"] or "").lower() == "phone"]
        return {"format": "galaxy-continuity-profile-v1", "accountKey": key["Aes256Key"],
                "localBluetoothAddress": local_address, "peers": list(peers.values()),
                "revision": account["Revision"], "expiresAt": key["ExpireTime"],
                "borrowedIdentity": True, "preferredPeerAddress": phones[-1]["address"] if phones else None,
                "accountFingerprint": base64.b64encode(bytes.fromhex(account["UserFingerprint"])).decode()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version="Galaxy Continuity connection exporter 0.1.7.1")
    parser.add_argument("--database", type=Path, default=Path(os.environ.get("LOCALAPPDATA", ".")) / "Packages/SAMSUNGELECTRONICSCoLtd.SamsungContinuityService_wyx1vj98g3asy/LocalState/PCSamsungContinuityDB.db")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reuse-device-model", help="Reuse this exact registered PC model instead of this Windows PC; that PC must keep Galaxy Connect stopped while the Mac uses its registration.")
    args = parser.parse_args()
    profile = profile_from_database(args.database, args.reuse_device_model)
    key, nonce = AESGCM.generate_key(bit_length=256), os.urandom(12)
    sealed = nonce + AESGCM(key).encrypt(nonce, json.dumps(profile).encode(), None)
    envelope = {"format": "galaxy-continuity-connection", "version": 1, "sealed": base64.b64encode(sealed).decode()}
    # Do not overwrite a prior connection accidentally.
    with args.output.open("x", encoding="utf-8") as file:
        json.dump(envelope, file)
    print("Encrypted connection saved. Import it in Galaxy Continuity Lab on the Mac.")
    print("Unlock code (keep separate from the file):", base64.b64encode(key).decode())


if __name__ == "__main__":
    main()
