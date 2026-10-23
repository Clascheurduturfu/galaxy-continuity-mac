"""Synthetic database coverage for the Windows bootstrap exporter."""
import base64
from contextlib import closing
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("export_connection", Path(__file__).resolve().parents[1] / "scripts/export_connection.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ConnectionExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "synthetic.db"
        with closing(sqlite3.connect(self.path)) as db, db:
            db.executescript("""
                CREATE TABLE SCRetrieveCertificateResponses(Revision INTEGER, UserFingerprint TEXT);
                CREATE TABLE ThisDeviceInfoes(BtAddr TEXT);
                CREATE TABLE UserAesKeys(Aes256Key TEXT, ExpireTime INTEGER);
                CREATE TABLE DeviceInfoLists(BtAddr TEXT, DeviceName TEXT, DeviceType TEXT, DeviceModel TEXT, ServerCreateTime INTEGER);
                INSERT INTO SCRetrieveCertificateResponses VALUES(7, '000102030405060708090a0b0c0d0e0f');
                INSERT INTO ThisDeviceInfoes VALUES('01:02:03:04:05:06');
                INSERT INTO DeviceInfoLists VALUES('11:12:13:14:15:16', 'Test phone', 'phone', 'SYNTHETIC_PHONE', 1);
                INSERT INTO DeviceInfoLists VALUES('21:22:23:24:25:26', 'Inactive test PC', 'pc', 'SYNTHETIC_PC', 2);
            """)
            db.execute("INSERT INTO UserAesKeys VALUES(?,?)", (base64.b64encode(bytes(range(32))).decode(), int(time.time()*1000)+3600000))

    def test_default_and_explicit_inactive_registration(self):
        profile = exporter.profile_from_database(self.path)
        self.assertEqual(profile["preferredPeerAddress"], "11:12:13:14:15:16")
        self.assertEqual(profile["localBluetoothAddress"], "01:02:03:04:05:06")
        other = exporter.profile_from_database(self.path, "SYNTHETIC_PC")
        self.assertEqual(other["localBluetoothAddress"], "21:22:23:24:25:26")
        self.assertNotIn(other["localBluetoothAddress"], [p["address"] for p in other["peers"]])
        with self.assertRaises(ValueError):
            exporter.profile_from_database(self.path, "SYNTHETIC_PHONE")

    def test_expired_key_and_ambiguous_registration_rejected(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("INSERT INTO DeviceInfoLists VALUES('31:32:33:34:35:36','Another PC','pc','SYNTHETIC_PC',3)")
        with self.assertRaises(ValueError):
            exporter.profile_from_database(self.path, "SYNTHETIC_PC")
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("UPDATE UserAesKeys SET ExpireTime=0")
        with self.assertRaises(ValueError):
            exporter.profile_from_database(self.path)


if __name__ == "__main__":
    unittest.main()
