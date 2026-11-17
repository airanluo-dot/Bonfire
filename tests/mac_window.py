"""Verify that the installed AppKit application presents a WindowServer window."""
import subprocess
import tempfile
from pathlib import Path

swift = """
import AppKit
import CoreGraphics
import Foundation
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let active = NSRunningApplication.runningApplications(withBundleIdentifier: "app.bonfire.savetransfer")
let expected = Set(active.map { Int($0.processIdentifier) })
let appWindows = windows.filter { win in
    guard let pid = win[kCGWindowOwnerPID as String] as? Int else { return false }
    return expected.contains(pid) && (win[kCGWindowLayer as String] as? Int) == 0
}
if appWindows.isEmpty { exit(1) }
print("Installed Bonfire presents a native application window.")
"""
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp) / "Window.swift"
    path.write_text(swift)
    subprocess.run(["xcrun", "swift", path], check=True)
