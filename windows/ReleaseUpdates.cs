using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Microsoft.Win32;
using System.Runtime.InteropServices;

namespace Bonfire;

internal sealed class ReleaseUpdates(Preferences prefs, Func<bool> canInstall, Action closeApp) {
    internal static readonly string Version = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()!.InformationalVersion.Split('+')[0];
    static readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect=true, MaxAutomaticRedirections=4 }) { Timeout=TimeSpan.FromMinutes(8) };
    static ReleaseUpdates(){http.DefaultRequestHeaders.UserAgent.ParseAdd("Bonfire/"+Version);}

    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(in Guid id, uint flags, IntPtr token, out IntPtr path);
    static string Downloads(){
        var id=new Guid("374DE290-123F-4565-9164-39C4925E467B");
        Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(in id,0,IntPtr.Zero,out var path));
        try{return Marshal.PtrToStringUni(path)!;}finally{Marshal.FreeCoTaskMem(path);}
    }
    public bool Installed {
        get {
            using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\{0C99D780-D42C-4133-B71A-DBD4A6F25A6F}_is1");
            return key?.GetValue("InstallLocation") is string location &&
                string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(location)),Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory),StringComparison.OrdinalIgnoreCase);
        }
    }
    public event Action? Changed;
    public string Status {get;private set;}="UpdateIdle";
    public bool Busy {get;private set;}
    public JsonNode? Candidate {get;private set;}
    public string? LocalFile {get;private set;}
    public string CandidateVersion=>Candidate?["version"]?.ToString()??"";
    CancellationTokenSource generation=new();
    Task active=Task.CompletedTask;
    public async Task Stop(){
        generation.Cancel();
        await active;
    }

    public void Reset(){
        generation.Cancel();generation.Dispose();generation=new();Busy=false;Candidate=null;LocalFile=null;Set("UpdateIdle");
    }
    void Set(string value){Status=value;Changed?.Invoke();}
    Task Execute(Func<CancellationToken,Task> op){
        if(Busy)return active;
        active=ExecuteCore(op);
        return active;
    }
    async Task ExecuteCore(Func<CancellationToken,Task> op){
        var token=generation.Token;Busy=true;
        try{await op(token);}
        catch(OperationCanceledException) when(token.IsCancellationRequested){}
        catch(ServiceError e){if(!token.IsCancellationRequested)Set(e.Message);}
        catch(Exception){if(!token.IsCancellationRequested)Set("UpdateFailed");}
        finally{if(token==generation.Token){Busy=false;Changed?.Invoke();}}
    }

    public Task Check() => Execute(async token=>{
        Set("UpdateChecking");Candidate=null;LocalFile=null;
        var feed=Native.Call(new{op="updateFeed"}).ToString();
        var all=new JsonArray();
        for(int page=1;;page++){
            using var response=await http.GetAsync(feed+"?per_page=100&page="+page,token);
            response.EnsureSuccessStatusCode();
            var data=JsonNode.Parse(await response.Content.ReadAsStringAsync(token))!.AsArray();
            foreach(var release in data)all.Add(release?.DeepClone());
            if(data.Count<100)break;
        }
        token.ThrowIfCancellationRequested();
        var kind=Installed?"Windows-x64-Setup.exe":"Windows-x64-Portable.zip";
        var plan=Native.Call(new{op="selectUpdate",current=Version,channel=prefs.Channel,kind,releases=all},token);
        prefs.LastCheck=DateTimeOffset.UtcNow;prefs.Save();
        if(plan["url"]==null){Set("UpdateCurrent");return;}
        Candidate=plan;Set("UpdateAvailable");
        if(prefs.AutoDownload)await DownloadCore(token,true);
    });

    static async Task<bool> Matches(Stream stream,JsonNode plan,CancellationToken token){
        stream.Position=0;
        if(stream.Length!=plan["size"]!.GetValue<long>())return false;
        var hash=await SHA256.HashDataAsync(stream,token);
        return Convert.ToHexStringLower(hash)==plan["hash"]!.ToString();
    }
    public Task Download()=>Execute(t=>DownloadCore(t,false));
    async Task DownloadCore(CancellationToken token,bool automatic){
        var plan=Candidate;if(plan==null)return;
        Set("UpdateDownloading");
        var folder=Downloads();var name=plan["name"]!.ToString();var file=Path.Combine(folder,name);
        var partial=Path.Combine(folder,".bonfire-"+Guid.NewGuid().ToString("N")+".partial");
        try{
            if(File.Exists(file)){
                using var saved=File.OpenRead(file);
                if(!await Matches(saved,plan,token))throw new ServiceError("UpdateCollision");
            }else{
                using var response=await http.GetAsync(plan["url"]!.ToString(),HttpCompletionOption.ResponseHeadersRead,token);
                response.EnsureSuccessStatusCode();
                var final=response.RequestMessage!.RequestUri!;
                if(final.Scheme!="https" || !(final.Host=="github.com" || final.Host.EndsWith(".githubusercontent.com",StringComparison.OrdinalIgnoreCase)))
                    throw new ServiceError("UpdateIntegrity");
                var expected=plan["size"]!.GetValue<long>();
                await using(var network=await response.Content.ReadAsStreamAsync(token))
                await using(var output=new FileStream(partial,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None,81920,true)){
                    byte[] buffer=new byte[81920];int count;
                    while((count=await network.ReadAsync(buffer,token))>0){
                        if(output.Position+count>expected)throw new ServiceError("UpdateIntegrity");
                        await output.WriteAsync(buffer.AsMemory(0,count),token);
                    }
                    if(!await Matches(output,plan,token))throw new ServiceError("UpdateIntegrity");
                }
                token.ThrowIfCancellationRequested();File.Move(partial,file,false);
            }
            token.ThrowIfCancellationRequested();LocalFile=file;Set(Installed?"UpdateReady":"UpdatePortableReady");
            if(automatic&&prefs.AutoInstall&&Installed&&canInstall())await InstallCore(token);
        }finally{if(File.Exists(partial))File.Delete(partial);}
    }
    public Task Install()=>Execute(InstallCore);
    public Task ApplyAutomaticIfReady()=>prefs.AutoInstall && Installed && LocalFile!=null && !Busy && canInstall() ? Install() : Task.CompletedTask;
    async Task InstallCore(CancellationToken token){
        if(Candidate==null||LocalFile==null)return;
        if(!Installed){Reveal();return;}
        if(!canInstall()){Set("UpdateWait");return;}
        using var locked=new FileStream(LocalFile,FileMode.Open,FileAccess.Read,FileShare.Read);
        if(!await Matches(locked,Candidate,token))throw new ServiceError("UpdateIntegrity");
        token.ThrowIfCancellationRequested();
        if(!canInstall()){Set("UpdateWait");return;}
        var start=new ProcessStartInfo(LocalFile){UseShellExecute=false};
        foreach(var arg in new[]{"/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/BONFIRERESTART","/DIR="+Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory)})start.ArgumentList.Add(arg);
        if(Process.Start(start)==null)throw new ServiceError("UpdateFailed");
        Set("UpdateInstalling");closeApp();
    }
    public void Reveal(){
        if(LocalFile!=null)Process.Start(new ProcessStartInfo("explorer.exe","/select,\""+LocalFile+"\""){UseShellExecute=false});
    }
}
