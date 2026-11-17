using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Bonfire;

internal sealed class ServiceError(string key, params string[] values) : Exception(key) {
    public string[] Values { get; } = values;
}

internal static class Native {
    private const string Library = "BonfireCore";
    [DllImport(Library)] static extern IntPtr bf_request([MarshalAs(UnmanagedType.LPUTF8Str)] string request, IntPtr token);
    [DllImport(Library)] static extern void bf_free(IntPtr ptr);
    [DllImport(Library)] static extern IntPtr bf_token_new();
    [DllImport(Library)] static extern void bf_token_free(IntPtr ptr);
    [DllImport(Library)] static extern void bf_cancel(IntPtr token);

    public static JsonNode Call(object input, CancellationToken cancellation = default) {
        cancellation.ThrowIfCancellationRequested();
        var token = bf_token_new();
        if (token == IntPtr.Zero) throw new OutOfMemoryException();
        try {
            using var registration = cancellation.Register(() => bf_cancel(token));
            var pointer = bf_request(JsonSerializer.Serialize(input), token);
            if (pointer == IntPtr.Zero) throw new OutOfMemoryException();
            try {
                cancellation.ThrowIfCancellationRequested();
                var response = JsonNode.Parse(Marshal.PtrToStringUTF8(pointer)!)!;
                if (response["error"] is JsonNode error)
                    throw new ServiceError(error.ToString(), response["args"]!.AsArray().Select(x => x!.ToString()).ToArray());
                return response["value"]!;
            } finally { bf_free(pointer); }
        } finally { bf_token_free(token); }
    }
}

internal sealed class Preferences {
    const string Key = @"Software\Bonfire";
    public string Language { get; set; } = "system";
    public string Folder { get; set; } = "";
    public HashSet<string> Hidden { get; set; } = [];
    public List<string> PackageFolders { get; set; } = [];
    public bool AutoCheck { get; set; } = true;
    public bool AutoDownload { get; set; } = true;
    public bool AutoInstall { get; set; }
    public string Channel { get; set; } = ReleaseUpdates.Version.Contains('-') ? "Beta" : "Stable";
    public DateTimeOffset? LastCheck { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public string Destination => string.IsNullOrWhiteSpace(Folder) ? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) : Folder;
    public static Preferences Load() {
        using var key = Registry.CurrentUser.OpenSubKey(Key);
        if (key?.GetValue("Preferences") is string json) {
            try { return JsonSerializer.Deserialize<Preferences>(json) ?? new(); }
            catch (JsonException) { }
        }
        return new();
    }
    public void Save() {
        try { using var key = Registry.CurrentUser.CreateSubKey(Key); key.SetValue("Preferences",JsonSerializer.Serialize(this)); }
        catch (Exception) { throw new ServiceError("PrefsError"); }
    }
    public void Remember(string folder) {
        if (!PackageFolders.Contains(folder,StringComparer.OrdinalIgnoreCase)) { PackageFolders.Add(folder); Save(); }
    }
}

internal sealed class Strings {
    readonly ResourceManager manager = new();
    readonly ResourceMap map;
    ResourceContext context;
    public CultureInfo Culture { get; private set; } = CultureInfo.InvariantCulture;
    public Strings(string language) {
        map = manager.MainResourceMap.GetSubtree("Resources");
        context = manager.CreateResourceContext();
        Set(language);
    }
    public void Set(string language) {
        var system = Windows.System.UserProfile.GlobalizationPreferences.Languages.FirstOrDefault() ?? "en";
        var tag = language == "system" ? system : language;
        var chosen = tag.StartsWith("zh",StringComparison.OrdinalIgnoreCase) ? "zh-Hans" : "en";
        // MRT Core unpackaged apps require a concrete language tag.
        Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride = chosen;
        context = manager.CreateResourceContext();
        context.QualifierValues["Language"] = chosen;
        Culture = CultureInfo.GetCultureInfo(chosen);
    }
    public string Get(string key, params object[] args) {
        var value = map.GetValue(key,context).ValueAsString;
        return args.Length == 0 ? value : string.Format(Culture,value,args);
    }
}
