"""Exercise the production launch-record check in two sandboxed app processes."""
from pathlib import Path
import plistlib
import selectors
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE = r'''
import AppKit
import Foundation

let app = NSApplication.shared
let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(CommandLine.arguments[1])
if CommandLine.arguments.count == 2 {
    _ = LaunchRecordStore.beginRun(in: directory, version: "probe")
    print(ProcessInfo.processInfo.processIdentifier)
    fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(60))
} else {
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let peer = Int32(CommandLine.arguments[2]) else { exit(2) }
    let live = LaunchRecord(startedAt: Date(), version: "probe", processIdentifier: peer)
    let stale = LaunchRecord(startedAt: .distantPast, version: "probe", processIdentifier: peer)
    guard LaunchRecordStore.isRunning(live), !LaunchRecordStore.isRunning(stale),
        LaunchRecordStore.beginRun(in: directory, version: "probe") == nil,
        FileManager.default.fileExists(atPath: LaunchRecordStore.recordURL(in: directory, processIdentifier: peer).path)
    else { exit(1) }
    print("Sandboxed peer retained; pre-boot marker rejected")
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="GlassEQ-launch-record-test-") as temporary:
        directory = Path(temporary)
        contents = directory / "Probe.app/Contents"
        executable = contents / "MacOS/Probe"
        executable.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.glasseq.tests.launch-records",
            "CFBundleName": "Probe", "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL", "LSUIElement": True,
        }))
        source = directory / "main.swift"
        source.write_text(SOURCE)
        subprocess.run(["xcrun", "swiftc", str(ROOT / "Sources/GlassEQApp/LaunchRecord.swift"),
                        str(ROOT / "Sources/GlassEQApp/BoundedFile.swift"),
                        str(source), "-o", str(executable)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                        str(ROOT / "GlassEQ.entitlements"), str(contents.parent)], check=True)
        session = str(uuid.uuid4())
        with subprocess.Popen([str(executable), session], stdout=subprocess.PIPE, text=True) as peer:
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(peer.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=20):
                        raise RuntimeError("sandboxed peer did not start")
                    pid = peer.stdout.readline().strip()
                if pid != str(peer.pid):
                    raise RuntimeError(f"unexpected peer startup: {pid!r}")
                subprocess.run([str(executable), session, pid], check=True, timeout=20)
                if peer.poll() is not None:
                    raise RuntimeError("peer exited before its liveness check")
            finally:
                peer.terminate()
                peer.wait(timeout=10)


if __name__ == "__main__":
    main()
