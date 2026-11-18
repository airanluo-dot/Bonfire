"""Verify that the installed AppKit application presents a WindowServer window."""
import subprocess
import tempfile
import plistlib
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

    # Exercise the same localized progress formatter against the installed product's resources.
    root = Path(__file__).resolve().parents[1]
    contents = Path(temp) / "ProgressCheck.app/Contents"
    binary = contents / "MacOS/ProgressCheck"
    binary.parent.mkdir(parents=True)
    (contents / "Resources").symlink_to("/Applications/Bonfire.app/Contents/Resources", target_is_directory=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": binary.name, "CFBundleIdentifier": "app.bonfire.progress-test", "CFBundlePackageType": "APPL",
    }))
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", root / "tests/mac_progress.mm",
                    root / "macos/Presentation.mm", "-framework", "AppKit", "-framework", "Foundation", "-o", binary], check=True)
    subprocess.run([binary], check=True)
