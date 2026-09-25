#!/usr/bin/env python3
"""Validate the real IOKit assertion lifecycle without putting the Mac to sleep."""
import pathlib, subprocess, tempfile
source = pathlib.Path(__file__).resolve().parent.parent / "Player/MPVPlayerClient.swift"
s = source.read_text()
s = s[s.index("final class PlaybackDisplaySleepAssertion"):s.index("enum PlayerTeardownMode")]
test = 'func count() -> Int {\n var result: Unmanaged<CFDictionary>?\n precondition(IOPMCopyAssertionsByProcess(&result) == kIOReturnSuccess)\n let processes = result!.takeRetainedValue() as NSDictionary\n let list = processes[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []\n return list.filter { $0[kIOPMAssertionNameKey] as? String == "OKVideoMac video playback" }.count\n}\nprecondition(count() == 0)\nvar assertion: PlaybackDisplaySleepAssertion? = PlaybackDisplaySleepAssertion()\nassertion!.update(playing: true); precondition(count() == 1)\nassertion!.update(playing: true); precondition(count() == 1)\nassertion!.update(playing: false); precondition(count() == 0)\nassertion!.update(playing: false); precondition(count() == 0)\nassertion!.update(playing: true); precondition(count() == 1)\nassertion = nil; precondition(count() == 0)\nprint("PASS: real IOKit assertion acquire/idempotence/pause/deinit lifecycle")\n'
with tempfile.TemporaryDirectory(prefix="tvbox-power-test-") as tmp:
    root = pathlib.Path(tmp)
    (root / "test.swift").write_text("import Foundation\nimport IOKit.pwr_mgt\n" + s + test)
    subprocess.run(["xcrun", "swiftc", str(root / "test.swift"), "-o", str(root / "test")], check=True)
    subprocess.run([str(root / "test")], check=True)
