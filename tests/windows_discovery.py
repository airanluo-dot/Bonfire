"""Exercise the shipped Windows DLL with an empty user hive and two Steam libraries."""
import ctypes
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import uuid
import winreg


def erase_test_hive(name):
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, name) as key:
        children = [winreg.EnumKey(key, i) for i in range(winreg.QueryInfoKey(key)[0])]
    for child in children:
        erase_test_hive(name + "\\" + child)
    winreg.DeleteKey(winreg.HKEY_CURRENT_USER, name)


def main(library):
    dll = ctypes.WinDLL(str(library.resolve()))
    dll.bf_token_new.restype = ctypes.c_void_p
    dll.bf_token_free.argtypes = [ctypes.c_void_p]
    dll.bf_cancel.argtypes = [ctypes.c_void_p]
    dll.bf_request.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
    dll.bf_request.restype = ctypes.c_void_p
    dll.bf_free.argtypes = [ctypes.c_void_p]
    redirect = ctypes.WinDLL("advapi32").RegOverridePredefKey
    redirect.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    current_user, local_machine = ctypes.c_void_p(-2147483647), ctypes.c_void_p(-2147483646)

    with tempfile.TemporaryDirectory(prefix="bonfire-steam-") as tmp:
        folder = Path(tmp)
        steam, second = folder / "client", folder / "different volume"
        expected = set()
        for storage in (steam, second):
            install = storage / "steamapps/common/Nekojishi"
            (install / "game").mkdir(parents=True)
            (install / "Nekojishi.exe").touch()
            (install / "Nekojishi.py").touch()
            (install / "game/script.rpyc").touch()
            (install / "game/options.rpy").write_text('define config.save_directory = "Neko-171107s"\n')
            expected.add(install.resolve())
        escaped = str(second).replace("\\", "\\\\")
        (steam / "steamapps/libraryfolders.vdf").write_text(f'"libraryfolders"\n{{\n"1"\n{{\n"path" "{escaped}"\n}}\n}}')

        # Redirect predefined roots only in this short-lived process.
        hive = "Software\\Bonfire.SteamTest." + uuid.uuid4().hex
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, hive + "\\User") as user, \
                winreg.CreateKey(winreg.HKEY_CURRENT_USER, hive + "\\Machine") as machine:
            try:
                assert redirect(current_user, int(user)) == 0 and redirect(local_machine, int(machine)) == 0
                with winreg.CreateKeyEx(winreg.HKEY_LOCAL_MACHINE, "Software\\Valve\\Steam", 0,
                                        winreg.KEY_WRITE | winreg.KEY_WOW64_32KEY) as key:
                    winreg.SetValueEx(key, "InstallPath", 0, winreg.REG_SZ, str(steam))
                token = dll.bf_token_new()
                timer = threading.Timer(5, lambda: dll.bf_cancel(token))
                timer.start()
                try:
                    start = time.monotonic()
                    result = dll.bf_request(b'{"op":"locate","game":"nekojishi"}', token)
                    try:
                        answer = json.loads(ctypes.string_at(result))
                    finally:
                        dll.bf_free(result)
                    elapsed = time.monotonic() - start
                    assert {Path(p["root"]).resolve() for p in answer["value"]} == expected, answer
                    assert elapsed < 5, f"Steam lookup entered a deep scan ({elapsed:.1f}s)"
                finally:
                    timer.cancel()
                    timer.join()
                    dll.bf_token_free(token)
            finally:
                assert redirect(local_machine, None) == 0 and redirect(current_user, None) == 0
        erase_test_hive(hive)
    print("Windows DLL located both Steam installations via the machine registry without a user Steam key.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
