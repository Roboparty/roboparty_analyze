#!/usr/bin/env python3
"""Exercise recorder lifecycle with fake tools; no hardware or systemd access."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.tools = self.base / "bin"
        self.dimensions = self.base / "dimensions"
        self.tools.mkdir()
        self.dimensions.mkdir()
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        SEVEN_ALLOW_NON_ROOT="yes", SESSION_MAX_DURATION_SECS="0",
                        USBCAN_CAPTURE_DIR=str(self.base / "ring"),
                        SEVEN_DIMENSIONS_DIR=str(self.dimensions),
                        SESSION_CLEANUP_COMMAND="/nonexistent",
                        SESSION_ROOT=str(self.base / "sessions"))
        self.tool("systemctl", "#!/bin/sh\nexit 0\n")
        self.tool("screen", "#!/bin/sh\nexit 0\n")
        self.tool("df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 99999999 0 99999999 0 /\\n'\n")
        self.tool("log2asc", "#!/bin/sh\nexit 99\n")
        self.tool("candump", """#!/usr/bin/env python3
import os, signal, sys, time
print('(1.000000) can0 001#0102', flush=True)
if 'CAN_EXIT' in os.environ:
    sys.exit(int(os.environ['CAN_EXIT']))
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
while True:
    time.sleep(0.1)
""")
        idle = "#!/bin/sh\ntrap 'exit 0' TERM INT\nwhile :; do sleep 0.1 & wait $!; done\n"
        for name in ("01_bms_status.sh", "02_can_details.sh", "03_kernel_dmesg.sh",
                     "04_hpm_uart.sh", "08_thermal.sh"):
            self.executable(self.dimensions / name, idle)
        self.executable(self.dimensions / "07_inference_screen.sh", "#!/bin/sh\nexit 0\n")
        self.executable(self.dimensions / "06_can_asc.sh",
                        f'#!/bin/sh\nexec bash "{ROOT}/dimensions/06_can_asc.sh" "$@"\n')
        ring = self.base / "capture"
        self.executable(ring, """#!/usr/bin/env python3
import os, pathlib, signal, sys, time
p = pathlib.Path(os.environ['CAPTURE_DIR'])
(p / 'usbcan.pcap').write_bytes(b'pcap')
print('rolling=' + os.environ['CAPTURE_ROLLING'], flush=True)
if 'USB_EXIT' in os.environ:
    sys.exit(int(os.environ['USB_EXIT']))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(0.1)
""")
        self.env["USBCAN_RING_CAPTURE_COMMAND"] = str(ring)

    def executable(self, path, contents):
        path.write_text(contents)
        path.chmod(0o755)

    def tool(self, name, contents):
        self.executable(self.tools / name, contents)

    def start(self):
        p = subprocess.Popen(["bash", str(ROOT / "capture/capture_seven_dimensions.sh")],
                             env=self.env, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        def cleanup():
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
        self.addCleanup(cleanup)
        return p

    def sessions(self):
        return sorted((self.base / "sessions").glob("seven-*"))

    def await_condition(self, condition):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.05)
        self.fail("capture condition timed out")

    def test_normal_stop_direct_pcap_without_asc_conversion(self):
        p = self.start()
        self.await_condition(lambda: self.sessions() and
                             (self.sessions()[0] / "can.log").stat().st_size > 0 and
                             (self.sessions()[0] / "usbcan.pcap").exists())
        p.terminate()
        self.assertEqual(p.wait(timeout=8), 0)
        session = self.sessions()[0]
        manifest = json.loads((session / "manifest.json").read_text())
        self.assertFalse(manifest["capture_failed"])
        self.assertEqual(manifest["candump_status"], 0)
        self.assertEqual(manifest["usb_capture_status"], 0)
        self.assertFalse((session / "can.asc").exists())
        self.assertEqual((session / "usbcan.pcap").read_bytes(), b"pcap")
        self.assertEqual((self.base / "ring/current-session").resolve(), session)

    def test_can_failure_preserves_status(self):
        self.env["CAN_EXIT"] = "7"
        p = self.start()
        self.assertEqual(p.wait(timeout=8), 1)
        manifest = json.loads((self.sessions()[0] / "manifest.json").read_text())
        self.assertEqual(manifest["candump_status"], 7)
        self.assertTrue(manifest["capture_failed"])
        self.assertEqual(manifest["failed_recorder"], "can")

    def test_usb_unexpected_clean_exit_is_failure(self):
        self.env["USB_EXIT"] = "0"
        p = self.start()
        self.assertEqual(p.wait(timeout=8), 1)
        manifest = json.loads((self.sessions()[0] / "manifest.json").read_text())
        self.assertEqual(manifest["usb_capture_status"], 0)
        self.assertTrue(manifest["capture_failed"])
        self.assertEqual(manifest["failed_recorder"], "usb")

    def test_rotation_finalizes_previous_session(self):
        self.env["SESSION_MAX_DURATION_SECS"] = "1"
        p = self.start()
        self.await_condition(lambda: len(self.sessions()) >= 2 and
                             (self.sessions()[-1] / "usbcan.pcap").exists())
        p.terminate()
        self.assertEqual(p.wait(timeout=8), 0)
        for session in self.sessions():
            manifest = json.loads((session / "manifest.json").read_text())
            self.assertFalse(manifest["capture_failed"])
            self.assertIn("ended_at_unix", manifest)

    def test_offline_conversion_failure_preserves_old_asc(self):
        session = self.base / "offline"
        session.mkdir()
        (session / "can.log").write_text("(1.0) can0 001#01\n")
        (session / "can.asc").write_text("previous\n")
        result = subprocess.run(["bash", str(ROOT / "dimensions/06_can_asc.sh"),
                                 "--convert", str(session)], env=self.env)
        self.assertEqual(result.returncode, 99)
        self.assertEqual((session / "can.asc").read_text(), "previous\n")

    def test_offline_conversion_success_never_starts_candump(self):
        session = self.base / "offline"
        session.mkdir()
        (session / "can.log").write_text("(1.0) can0 001#01\n")
        self.tool("candump", "#!/bin/sh\nexit 88\n")
        self.tool("log2asc", '#!/bin/sh\nprintf "converted\\n" > "$4"\n')
        result = subprocess.run(["bash", str(ROOT / "dimensions/06_can_asc.sh"),
                                 "--convert", str(session)], env=self.env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual((session / "can.asc").read_text(), "converted\n")

    def test_tcpdump_direct_and_standalone_rotation_arguments(self):
        net = self.base / "net"
        (net / "can0").mkdir(parents=True)
        self.tool("modprobe", "#!/bin/sh\nexit 0\n")
        self.tool("tcpdump", '#!/bin/sh\nprintf "%s\\n" "$@"\n')
        self.env.update(USBMON_IFACE="usbmon3", USBCAN_SYS_CLASS_NET=str(net),
                        USBCAN_MODPROBE_BIN=str(self.tools / "modprobe"),
                        USBCAN_TCPDUMP_BIN=str(self.tools / "tcpdump"),
                        CAPTURE_DIR=str(self.base / "pcap"),
                        USBCAN_ALLOW_NON_RUN_CAPTURE_DIR="yes")
        for rolling in ("yes", "no"):
            self.env["CAPTURE_ROLLING"] = rolling
            result = subprocess.run(["sh", str(ROOT / "capture/capture_usbcan_ring.sh")],
                                    env=self.env, capture_output=True, text=True, check=True)
            self.assertEqual("-W" in result.stdout.splitlines(), rolling == "yes")
            self.assertEqual("-U" in result.stdout.splitlines(), rolling == "yes")
            self.assertIn("-C", result.stdout.splitlines())


if __name__ == "__main__":
    unittest.main()
