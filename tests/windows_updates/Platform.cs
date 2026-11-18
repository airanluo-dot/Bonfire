using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bonfire;

// Test app metadata and preferences. Never write the user's registry or launch an installer.
internal sealed class App { }
internal sealed class Preferences {
    public string Channel = "Beta";
    public bool AutoDownload { get; set; }
    public bool AutoInstall { get; set; }
    public DateTimeOffset? LastCheck;
    public void Save() { }
}
internal sealed class ServiceError(string key) : Exception(key) { }
internal static class Native {
    public static string Executable = "";
    public static JsonNode Call(object request,CancellationToken token = default) {
        token.ThrowIfCancellationRequested();
        using var process = Process.Start(new ProcessStartInfo(Executable) {
            UseShellExecute=false, RedirectStandardInput=true, RedirectStandardOutput=true
        })!;
        process.StandardInput.Write(JsonSerializer.Serialize(request));
        process.StandardInput.Close();
        var result = JsonNode.Parse(process.StandardOutput.ReadToEnd())!;
        process.WaitForExit();
        return result is JsonObject && result["error"] != null ? throw new ServiceError(result["error"]!.ToString()) : result;
    }
}
internal sealed class Host(string folder, bool installed) : WindowsUpdateHost {
    public int Launches;
    public bool DenyLaunch;
    public bool IsCurrent = true;
    public IOException? FolderError;
    public override bool Installed => installed;
    public override string Downloads() => FolderError == null ? folder : throw FolderError;
    public override bool IsCurrentInstallation(string version) => installed && IsCurrent;
    public override void StartInstaller(string file) {
        if (!File.Exists(file)) throw new FileNotFoundException();
        if (DenyLaunch) throw new Win32Exception(5);
        Launches++;
    }
}
internal sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> reply) : HttpMessageHandler {
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token) {
        var response = await reply(request,token);
        response.RequestMessage ??= request;
        return response;
    }
}
