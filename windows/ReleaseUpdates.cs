using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Bonfire;

internal sealed class ReleaseUpdates(Preferences prefs, Func<bool> canInstall, Action closeApp,
                                     ReleaseTransport? source = null, WindowsUpdateHost? platform = null) {
    internal static readonly string Version = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
    static readonly ReleaseTransport officialSource = new(ReleaseTransport.CreateClient(Version), Native.Call);
    readonly ReleaseTransport transport = source ?? officialSource;

    readonly WindowsUpdateHost host = platform ?? new WindowsUpdateHost();
    public bool Installed => host.Installed;
    public event Action? Changed;
    public string Status { get; private set; } = "UpdateIdle";
    public bool Busy { get; private set; }
    public bool Installing { get; private set; }
    public int? DownloadPercent { get; private set; }
    public DateTimeOffset? RetryAfter { get; private set; }
    public JsonNode? Candidate { get; private set; }
    public string? LocalFile { get; private set; }
    public string CandidateVersion => Candidate?["version"]?.ToString() ?? "";

    CancellationTokenSource? operation;
    Task active = Task.CompletedTask;

    public Task Stop() {
        if (!Installing) operation?.Cancel();
        return active;
    }
    public void Reset() {
        if (Installing) return;
        operation?.Cancel();
        operation = null;
        Busy = false;
        Candidate = null;
        LocalFile = null;
        RetryAfter = null;
        DownloadPercent = null;
        Set("UpdateIdle");
    }
    void Set(string status) { Status = status; Changed?.Invoke(); }

    Task Execute(Func<CancellationToken,Task> action, string errorKey) {
        if (Busy || Installing) return active;
        var source = new CancellationTokenSource();
        var previous = active;
        operation = source;
        RetryAfter = null;
        Busy = true;
        return active = Run();

        async Task Run() {
            // Publish the task before notifying controls which may cancel or close
            // the window. Finish cleanup of a cancelled channel before starting.
            await Task.Yield();
            try {
                await previous;
                var token = source.Token;
                token.ThrowIfCancellationRequested();
                await action(token);
            } catch (OperationCanceledException) when (source.IsCancellationRequested) {
                if (operation == source) Set("UpdateCancelled");
            } catch (UpdateTransportError error) {
                if (operation == source) { RetryAfter = error.RetryAfter; Set(error.Message); }
            } catch (ServiceError error) {
                if (operation == source) Set(error.Message);
            } catch (Exception error) {
                if (operation == source) Set(FileError(error, errorKey));
            } finally {
                if (operation == source) {
                    Busy = false;
                    operation = null;
                    DownloadPercent = null;
                    Changed?.Invoke();
                    if (Installing) closeApp();
                }
                source.Dispose();
            }
        }
    }

    static string FileError(Exception error, string fallback) {
        if (error is UnauthorizedAccessException) return "UpdatePermission";
        var code = error is Win32Exception win ? win.NativeErrorCode : error.HResult & 0xffff;
        return code switch {
            39 or 112 => "UpdateDiskFull",
            5 or 19 => "UpdatePermission",
            32 or 33 => "UpdateFileBusy",
            _ => fallback
        };
    }

    public Task Check() => Execute(async token => {
        Set("UpdateChecking");
        var plan = await transport.Select(Version, prefs.Channel, Installed ? "Windows-x64-Setup.exe" : "Windows-x64-Portable.zip", token);
        token.ThrowIfCancellationRequested();
        prefs.LastCheck = DateTimeOffset.UtcNow;
        prefs.Save();
        if (plan["url"] == null) { Candidate = null; LocalFile = null; Set("UpdateCurrent"); return; }
        if (Candidate?["hash"]?.ToString() != plan["hash"]!.ToString()) LocalFile = null;
        Candidate = plan;
        Set("UpdateAvailable");
        if (prefs.AutoDownload) await DownloadCore(token,true);
    }, "UpdateNetwork");

    static async Task<bool> Matches(Stream stream, JsonNode plan, CancellationToken token) {
        stream.Position = 0;
        if (stream.Length != plan["size"]!.GetValue<long>()) return false;
        var hash = await SHA256.HashDataAsync(stream,token);
        return Convert.ToHexStringLower(hash) == plan["hash"]!.ToString();
    }

    // Reuse a verified download, leave unrelated files in place, and resolve a
    // race with another downloader without replacing its output.
    internal static async Task<string?> Place(string folder, JsonNode plan, string? partial, CancellationToken token) {
        var name = plan["name"]!.ToString();
        for (int number = 0; number < 1000; number++) {
            token.ThrowIfCancellationRequested();
            var candidate = number == 0 ? name : $"{Path.GetFileNameWithoutExtension(name)} ({number}){Path.GetExtension(name)}";
            var path = Path.Combine(folder,candidate);
            if (File.Exists(path)) {
                if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) continue;
                try {
                    await using var file = File.OpenRead(path);
                    if (await Matches(file,plan,token)) return path;
                } catch (FileNotFoundException) { /* A concurrent cleanup freed this name. */ }
                if (File.Exists(path)) continue;
            }
            if (Directory.Exists(path)) continue;
            if (partial == null) return null;
            try { File.Move(partial,path,false); return path; }
            catch (IOException) when (File.Exists(path) || Directory.Exists(path)) {
                // Verify what won the race before allocating a second name.
                if (File.Exists(path) && !File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) {
                    await using var winner = File.OpenRead(path);
                    if (await Matches(winner,plan,token)) return path;
                }
            }
        }
        throw new ServiceError("UpdateCollision");
    }

    public Task Download() => Execute(t => DownloadCore(t,false), "UpdateDownloadFailed");
    async Task DownloadCore(CancellationToken token, bool automatic) {
        var plan = Candidate;
        if (plan == null) return;
        try {
            var folder = host.Downloads();
            Directory.CreateDirectory(folder);
            LocalFile = null;
            Set("UpdateVerifying");
            var existing = await Place(folder,plan,null,token);
            if (existing == null) {
                DownloadPercent = 0;
                Set("UpdateDownloading");
                string partial = Path.Combine(folder,".bonfire-"+Guid.NewGuid().ToString("N")+".partial");
                long expected = plan["size"]!.GetValue<long>();
                var fileStream = new FileStream(partial,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None,81920,true);
                try {
                    await using (var output = fileStream) {
                        await transport.CopyAsset(plan, output, received => {
                            token.ThrowIfCancellationRequested();
                            int percent = (int)(received * 100 / expected);
                            if (DownloadPercent != percent) { DownloadPercent = percent; Changed?.Invoke(); }
                        }, token);
                        token.ThrowIfCancellationRequested();
                        DownloadPercent = null;
                        Set("UpdateVerifying");
                        if (!await Matches(output,plan,token)) throw new ServiceError("UpdateIntegrity");
                    }
                    existing = await Place(folder,plan,partial,token);
                } finally {
                    File.Delete(partial);
                }
            }
            token.ThrowIfCancellationRequested();
            LocalFile = existing;
            Set(Installed ? "UpdateReady" : "UpdatePortableReady");
        } catch (IOException error) { throw new ServiceError(FileError(error,"UpdateDownloadFailed")); }
        catch (UnauthorizedAccessException) { throw new ServiceError("UpdatePermission"); }
        if (automatic && prefs.AutoInstall && Installed) {
            if (canInstall()) await InstallCore(token);
            else Set("UpdateWait");
        }
    }

    public Task Install() => Execute(InstallCore, "UpdateInstallFailed");
    public Task ApplyAutomaticIfReady() => prefs.AutoInstall && Installed && LocalFile != null && !Busy && !Installing && canInstall() ? Install() : Task.CompletedTask;
    async Task InstallCore(CancellationToken token) {
        var file = LocalFile;
        var plan = Candidate;
        if (file == null || plan == null) return;
        if (!plan["name"]!.ToString().EndsWith("-Windows-x64-Setup.exe",StringComparison.Ordinal)) { Reveal(); return; }
        if (!canInstall()) { Set("UpdateWait"); return; }
        Set("UpdateVerifying");
        try {
            using var locked = new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read);
            if (!await Matches(locked,plan,token)) { LocalFile = null; throw new ServiceError("UpdateIntegrity"); }
            token.ThrowIfCancellationRequested();
            if (!canInstall()) { Set("UpdateWait"); return; }
            if (!host.IsCurrentInstallation(Version)) { Set("UpdateTargetChanged"); return; }
            host.StartInstaller(file);
            Installing = true;
            Set("UpdateInstalling");
        } catch (IOException e) when (e is FileNotFoundException or DirectoryNotFoundException) {
            LocalFile = null; throw new ServiceError("UpdateDownloadedMissing");
        } catch (Win32Exception e) { throw new ServiceError(FileError(e,"UpdateInstallFailed")); }
    }

    public void Reveal() {
        if (LocalFile == null) return;
        if (!File.Exists(LocalFile)) { LocalFile = null; Set("UpdateDownloadedMissing"); return; }
        try {
            using var explorer = Process.Start(new ProcessStartInfo("explorer.exe","/select,\""+LocalFile+"\""){UseShellExecute=false});
        } catch (Win32Exception e) { Set(FileError(e,"UpdateDownloadFailed")); }
    }
}
