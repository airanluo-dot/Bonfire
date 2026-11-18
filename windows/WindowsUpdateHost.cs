using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Bonfire;

internal class WindowsUpdateHost {
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(in Guid id, uint flags, IntPtr token, out IntPtr path);
    public virtual string Downloads() {
        var id = new Guid("374DE290-123F-4565-9164-39C4925E467B");
        const uint dontVerify = 0x4000; // The user may have moved or removed their Downloads directory.
        Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(in id,dontVerify,IntPtr.Zero,out var path));
        try { return Marshal.PtrToStringUni(path)!; } finally { Marshal.FreeCoTaskMem(path); }
    }

    public virtual bool Installed {
        get {
            try {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\{0C99D780-D42C-4133-B71A-DBD4A6F25A6F}_is1");
                return key?.GetValue("InstallLocation") is string location && Path.IsPathFullyQualified(location) &&
                    string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(location)),Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory),StringComparison.OrdinalIgnoreCase);
            } catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException) {
                return false;
            }
        }
    }
    public virtual bool IsCurrentInstallation(string version) {
        var exe = Path.Combine(AppContext.BaseDirectory,"Bonfire.exe");
        return Installed && File.Exists(exe) && FileVersionInfo.GetVersionInfo(exe).ProductVersion?.Split('+')[0] == version;
    }
    public virtual void StartInstaller(string file) {
        var start = new ProcessStartInfo(file){UseShellExecute=false};
        foreach (var arg in new[]{"/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/BONFIRERESTART","/DIR="+Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory)})
            start.ArgumentList.Add(arg);
        using var installer = Process.Start(start) ?? throw new ServiceError("UpdateInstallFailed");
    }
}
