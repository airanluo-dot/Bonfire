using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Bonfire;

internal static class Program {
    const string Repo = "https://github.com/airanluo-dot/Bonfire/releases";
    const string Tag = "v0.1.0-beta.2";
    static readonly byte[] Payload = "isolated test update"u8.ToArray();
    static readonly string Hash = Convert.ToHexStringLower(SHA256.HashData(Payload));
    static string Filename(bool installed) => "Bonfire-0.1.0-beta.2-Windows-x64-"+(installed?"Setup.exe":"Portable.zip");
    static string Url(string file) => Repo+"/download/"+Tag+"/"+file;
    static void Expect(bool ok,string label) { if (!ok) throw new Exception(label); }
    static HttpResponseMessage Ok(string content) => new(HttpStatusCode.OK){Content=new StringContent(content)};
    static string Feed(string file) => JsonSerializer.Serialize(new[] { new {
        tag_name=Tag, draft=false, prerelease=true, assets = new[] { new {
            name=file, state="uploaded", size=Payload.Length, digest="sha256:"+Hash, browser_download_url=Url(file)
        }}
    }});
    static string Atom(string tag) => $"""<feed xmlns="http://www.w3.org/2005/Atom"><entry><link rel="alternate" href="{Repo}/tag/{tag}"/></entry></feed>""";

    static async Task WindowsFlow(string folder, bool installed) {
        var file = Filename(installed);
        var host = new Host(folder,installed);
        var prefs = new Preferences();
        bool canInstall = true, closed = false, corrupt = false, stall = false;
        var entered = new TaskCompletionSource();
        int requests = 0;
        using var http = new HttpClient(new Handler(async (request,token) => {
            if (request.RequestUri!.Host == "api.github.com") return Ok(Feed(file));
            Expect(request.RequestUri.AbsoluteUri == Url(file), "asset URI");
            requests++;
            if (stall) { entered.TrySetResult(); await Task.Delay(Timeout.InfiniteTimeSpan,token); }
            return new HttpResponseMessage(HttpStatusCode.OK){Content = new ByteArrayContent(corrupt ? new byte[Payload.Length] : Payload)};
        }));
        var updater = new ReleaseUpdates(prefs,()=>canInstall,()=>closed=true,new ReleaseTransport(http,Native.Call),host);
        await updater.Check();
        Expect(updater.Status=="UpdateAvailable" && prefs.LastCheck!=null,"candidate");
        host.FolderError = new IOException("disk full", unchecked((int)0x80070070));
        await updater.Download();
        Expect(updater.Status=="UpdateDiskFull" && !updater.Busy && updater.Candidate!=null, "disk full is retryable");
        host.FolderError = null;
        Directory.CreateDirectory(folder);
        var unrelated = Path.Combine(folder,file);
        File.WriteAllText(unrelated,"unrelated");
        stall=true;
        var pending=updater.Download();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await updater.Stop();
        await pending;
        Expect(updater.Status=="UpdateCancelled" && !updater.Busy && updater.Candidate!=null &&
            !Directory.EnumerateFiles(folder,"*.partial").Any(),"cancel and clean up");
        stall=false; corrupt=true;
        await updater.Download();
        Expect(updater.Status=="UpdateIntegrity" && updater.LocalFile==null && !Directory.EnumerateFiles(folder,"*.partial").Any(),"hash mismatch");
        corrupt=false;
        await updater.Download();
        string saved = updater.LocalFile!;
        Expect(saved!=unrelated && File.ReadAllText(unrelated)=="unrelated" && File.ReadAllBytes(saved).SequenceEqual(Payload),"side-by-side download");
        int networkCount = requests;
        await updater.Download();
        Expect(updater.LocalFile==saved && requests==networkCount, "reuse verified bytes");
        if (!installed) {
            File.Delete(saved);updater.Reveal();
            Expect(updater.LocalFile==null && updater.Status=="UpdateDownloadedMissing","missing portable download");
            return;
        }
        canInstall=false;await updater.Install();Expect(updater.Status=="UpdateWait" && !closed,"wait while saving");
        canInstall=true;File.WriteAllBytes(saved,new byte[Payload.Length]);
        await updater.Install();Expect(updater.Status=="UpdateIntegrity" && updater.LocalFile==null && host.Launches==0,"reverify immediately before launch");
        await updater.Download();
        host.IsCurrent=false;await updater.Install();Expect(updater.Status=="UpdateTargetChanged" && host.Launches==0,"replaced installation");
        host.IsCurrent=true;
        host.DenyLaunch=true;await updater.Install();Expect(updater.Status=="UpdatePermission" && !closed,"permission failure is retryable");
        host.DenyLaunch=false;await updater.Install();Expect(closed && host.Launches==1 && updater.Installing,"only close after launch");
    }

    static async Task NetworkFailures() {
        foreach (var scenario in new[]{"tls","timeout","invalid","offsite","5xx"}) {
            int count=0;
            using var http=new HttpClient(new Handler((request, token) => {
                count++;
                return scenario switch {
                    "tls" => throw new HttpRequestException(HttpRequestError.SecureConnectionError,"cert"),
                    "timeout" => throw new TaskCanceledException(),
                    "invalid" => Task.FromResult(Ok("<html/>")),
                    "offsite" => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){RequestMessage=new(HttpMethod.Get,"https://example.org/")}),
                    _ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))
                };
            }));
            var transport = new ReleaseTransport(http,Native.Call);
            try { await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default); throw new Exception("failure expected"); }
            catch (Exception e) {
                var expected = scenario switch { "tls"=>"UpdateTls","timeout"=>"UpdateTimeout","invalid"=>"UpdateInvalidFeed","offsite"=>"UpdateIntegrity", _=>"UpdateNetwork" };
                Expect(e.Message==expected && count==(scenario is "offsite" or "invalid" ? 1 : 2),scenario);
            }
        }
    }

    static async Task WebFallback() {
        string file = Filename(false);
        bool brokenHash=false, invalidAtom=false, webOffline=false, missingNewer=false, secondary=false;
        using var http = new HttpClient(new Handler((request,token) => {
            var uri=request.RequestUri!;
            if(uri.Host=="api.github.com") {
                var response = new HttpResponseMessage(HttpStatusCode.Forbidden);
                if (secondary) {
                    response.Content = new StringContent("You have exceeded a secondary rate limit.");
                    return Task.FromResult(response);
                }
                response.Headers.Add("X-RateLimit-Remaining","0");
                response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromMinutes(3));
                return Task.FromResult(response);
            }
            if (webOffline) throw new HttpRequestException("offline");
            if(uri.AbsoluteUri==Repo+".atom") {
                var atom = Atom(Tag);
                if (missingNewer) atom = atom.Replace("</feed>",$"""<entry><link href="{Repo}/tag/v0.1.0-beta.3"/></entry></feed>""");
                return Task.FromResult(Ok(invalidAtom?"<html/>":atom));
            }
            if(uri.AbsoluteUri==Repo+"/latest") return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){RequestMessage=new(HttpMethod.Head,Repo)});
            if(uri.AbsoluteUri==Url("SHA256SUMS.txt")) return Task.FromResult(Ok((brokenHash?"bad":Hash)+"  "+file+"\n"));
            if(uri.AbsoluteUri==Repo+"/download/v0.1.0-beta.3/SHA256SUMS.txt")
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
            Expect(uri.AbsoluteUri==Url(file) && request.Method==HttpMethod.Head,"verified fallback asset HEAD");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new ByteArrayContent(Payload)});
        }));
        var transport=new ReleaseTransport(http, Native.Call);
        var plan=await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default);
        Expect(plan["hash"]!.ToString()==Hash && plan["size"]!.GetValue<int>()==Payload.Length,"complete fallback plan");
        missingNewer=true;
        Expect((await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default))["hash"]!.ToString()==Hash,"skip incomplete tag");
        missingNewer=false;
        secondary=true;
        Expect((await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default))["hash"]!.ToString()==Hash,"secondary rate limit");
        secondary=false;
        Expect((await transport.Select("0.1.0-beta.1","Stable","Windows-x64-Portable.zip",default)).AsObject().Count==0,"no official stable release");
        brokenHash=true;
        try { await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default); throw new Exception("invalid checksum accepted"); }
        catch(ServiceError e) when(e.Message=="UpdateIntegrity") { }
        brokenHash=false; invalidAtom=true;
        try { await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default); throw new Exception("invalid feed accepted"); }
        catch(ServiceError e) when(e.Message=="UpdateInvalidFeed") { }
        webOffline=true;
        try { await transport.Select("0.1.0-beta.1","Beta","Windows-x64-Portable.zip",default); throw new Exception("unavailable feeds accepted"); }
        catch(UpdateTransportError e) when(e.Message=="UpdateRateLimited" && e.RetryAfter!=null) { }
    }

    static async Task Main(string[] args) {
        Native.Executable=args[0];
        if (args.Contains("--live-download")) {
            var host = new Host(Path.Combine(args[1],"official-setup"),true);
            var updater = new ReleaseUpdates(new Preferences(),()=>false,()=>throw new Exception("Unexpected installation"),
                platform:host);
            await updater.Check();
            Expect(updater.Status=="UpdateAvailable", "official setup candidate: "+updater.Status);
            await updater.Download();
            Expect(updater.Status=="UpdateReady", "official setup download: "+updater.Status);
            string path = updater.LocalFile!;
            using (var saved = File.OpenRead(path)) {
                var hash = Convert.ToHexStringLower(await SHA256.HashDataAsync(saved));
                Expect(hash==updater.Candidate!["hash"]!.ToString() && saved.Length==updater.Candidate["size"]!.GetValue<long>(),"official digest and size");
                Console.WriteLine($"Verified {Path.GetFileName(path)}: {saved.Length} bytes, SHA-256 {hash}");
            }
            bool downloadedAgain=false;
            updater.Changed+=()=>downloadedAgain |= updater.Status=="UpdateDownloading";
            await updater.Download();
            Expect(!downloadedAgain && updater.LocalFile==path && updater.Status=="UpdateReady" && host.Launches==0,"cached setup reused without execution");
            Console.WriteLine("Verified cached setup reused without launching an installer.");
            return;
        }
        if (args.Contains("--live")) {
            using var http=ReleaseTransport.CreateClient("0.1.0-beta.2");
            var transport=new ReleaseTransport(http, Native.Call);
            foreach (var channel in new[]{"Stable","Beta"}) foreach(var version in new[]{"0.1.0-beta.1","0.1.0-beta.2"}) {
                var plan=await transport.Select(version,channel,"Windows-x64-Portable.zip",default);
                Console.WriteLine($"Official {channel} channel from {version}: {plan["version"]?.ToString() ?? "current"}");
            }
            return;
        }
        await WebFallback();
        await NetworkFailures();
        await WindowsFlow(Path.Combine(args[1],"portable"),false);
        await WindowsFlow(Path.Combine(args[1],"installed"),true);
        Console.WriteLine("Windows updater: rate limit, Atom fallback, stable channel, SHA-256, cancellation, retry, file conflicts and installer handoff: OK");
    }
}
