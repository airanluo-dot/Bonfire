using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Xml;
using System.Xml.Linq;

namespace Bonfire;

internal sealed class UpdateTransportError(string key, bool fallback = false, DateTimeOffset? retryAfter = null) : Exception(key) {
    public bool CanFallback { get; } = fallback;
    public DateTimeOffset? RetryAfter { get; } = retryAfter;
}

internal sealed class ReleaseTransport(HttpClient http, Func<object,CancellationToken,JsonNode> native) {
    const string Repository = "https://github.com/airanluo-dot/Bonfire/releases";
    const string TagPath = "/airanluo-dot/Bonfire/releases/tag/";
    const int FeedLimit = 8 * 1024 * 1024;

    public static HttpClient CreateClient(string version) {
        var handler = new HttpClientHandler {
            AllowAutoRedirect = true, MaxAutomaticRedirections = 8,
            AutomaticDecompression = DecompressionMethods.All
        };
        var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Bonfire/" + version);
        return client;
    }

    static bool SecureHost(Uri? uri, string host) =>
        uri != null && uri.IsAbsoluteUri && uri.Scheme == "https" && uri.IsDefaultPort &&
        uri.UserInfo.Length == 0 && uri.Host.Equals(host, StringComparison.OrdinalIgnoreCase);

    static bool AssetHost(Uri? uri) => SecureHost(uri, "github.com") ||
        (uri != null && uri.IsAbsoluteUri && uri.Host.EndsWith(".githubusercontent.com", StringComparison.OrdinalIgnoreCase)
            && SecureHost(uri, uri.Host));

    static string? Tag(Uri? uri) {
        if (!SecureHost(uri, "github.com") || uri!.Query.Length != 0 || uri.Fragment.Length != 0 ||
            !uri.AbsolutePath.StartsWith(TagPath, StringComparison.Ordinal)) return null;
        var tag = uri.AbsolutePath[TagPath.Length..];
        return tag.Length == 0 || tag.IndexOfAny(['/', '%']) >= 0 ? null : tag;
    }

    static DateTimeOffset? RetryTime(HttpResponseMessage response) {
        var delay = response.Headers.RetryAfter;
        if (delay?.Date is DateTimeOffset date) return date;
        if (delay?.Delta is TimeSpan duration && duration < TimeSpan.FromDays(365)) return DateTimeOffset.UtcNow + duration;
        if (response.Headers.TryGetValues("X-RateLimit-Reset", out var values) &&
            long.TryParse(values.FirstOrDefault(), out var seconds) && seconds >= 0 && seconds <= 253402300799)
            return DateTimeOffset.FromUnixTimeSeconds(seconds);
        return null;
    }

    static async Task<string> Text(HttpContent content, int limit, CancellationToken token) {
        if (content.Headers.ContentLength > limit) throw new ServiceError("UpdateInvalidFeed");
        using var body = new MemoryStream();
        using var stream = await content.ReadAsStreamAsync(token);
        var buffer = new byte[16384];
        int count;
        while ((count = await stream.ReadAsync(buffer, token)) != 0) {
            if (body.Length + count > limit) throw new ServiceError("UpdateInvalidFeed");
            body.Write(buffer, 0, count);
        }
        return Encoding.UTF8.GetString(body.GetBuffer(), 0, checked((int)body.Length));
    }

    async Task<HttpResponseMessage> Open(string url, HttpMethod method, Func<Uri?,bool> allowed, CancellationToken token) {
        using var request = new HttpRequestMessage(method, url);
        var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        try {
            if (!allowed(response.RequestMessage?.RequestUri)) throw new ServiceError("UpdateIntegrity");
            if (response.IsSuccessStatusCode) return response;
            var code = (int)response.StatusCode;
            bool throttled = code == 429 || (code == 403 && (response.Headers.RetryAfter != null ||
                (response.Headers.TryGetValues("X-RateLimit-Remaining", out var remaining) && remaining.Contains("0"))));
            if (!throttled && code == 403) {
                // A secondary limit can arrive in a compressed/chunked response
                // without a Retry-After header and with primary quota remaining.
                using var body = await response.Content.ReadAsStreamAsync(token);
                var prefix = new byte[8192];
                int count = await body.ReadAtLeastAsync(prefix, prefix.Length, throwOnEndOfStream:false, cancellationToken:token);
                throttled = Encoding.UTF8.GetString(prefix,0,count).Contains("rate limit", StringComparison.OrdinalIgnoreCase);
            }
            if (throttled) throw new UpdateTransportError("UpdateRateLimited", true, RetryTime(response));
            if (code == 404 && url.StartsWith(Repository + "/download/", StringComparison.Ordinal))
                throw new ServiceError("UpdateMissing");
            throw new UpdateTransportError("UpdateNetwork", code >= 500 || code == 408);
        } catch {
            response.Dispose();
            throw;
        }
    }

    static async Task<T> Timed<T>(Func<CancellationToken, Task<T>> action, TimeSpan timeout, CancellationToken token) {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(timeout);
        try { return await action(deadline.Token); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new UpdateTransportError("UpdateTimeout", true); }
        catch (HttpRequestException e) {
            throw new UpdateTransportError(e.HttpRequestError == HttpRequestError.SecureConnectionError ? "UpdateTls" : "UpdateNetwork", true);
        }
        catch (HttpIOException) { throw new UpdateTransportError("UpdateNetwork", true); }
    }

    Task<string> GetText(string url, int limit, Func<Uri?,bool> allowed, CancellationToken token) =>
        Timed(async t => {
            using var response = await Open(url, HttpMethod.Get, allowed, t);
            try { return await Text(response.Content, limit, t); }
            catch (IOException) { throw new UpdateTransportError("UpdateNetwork", true); }
        }, TimeSpan.FromSeconds(25), token);

    public async Task<JsonNode> Select(string version, string channel, string kind, CancellationToken token) {
        try {
            var feed = native(new {op="updateFeed"}, token).ToString();
            var releases = new JsonArray();
            for (int page = 1; ; page++) {
                var raw = await GetText(feed + "?per_page=100&page=" + page, FeedLimit, u => SecureHost(u,"api.github.com"), token);
                JsonArray batch;
                try { batch = JsonNode.Parse(raw) as JsonArray ?? throw new ServiceError("UpdateInvalidFeed"); }
                catch (JsonException) { throw new ServiceError("UpdateInvalidFeed"); }
                foreach (var entry in batch) releases.Add(entry?.DeepClone());
                if (batch.Count < 100) break;
            }
            return native(new {op="selectUpdate", current=version, channel, kind, releases}, token);
        } catch (UpdateTransportError primary) when (primary.CanFallback) {
            try { return await SelectWeb(version, channel, kind, token); }
            catch (UpdateTransportError) when (primary.Message == "UpdateRateLimited") { throw primary; }
        }
    }

    static string[] AtomTags(string xml) {
        XNamespace atom = "http://www.w3.org/2005/Atom";
        try {
            using var input = new StringReader(xml);
            using var reader = XmlReader.Create(input, new XmlReaderSettings {
                DtdProcessing=DtdProcessing.Prohibit, XmlResolver=null, MaxCharactersInDocument=FeedLimit
            });
            var root = XDocument.Load(reader).Root;
            if (root?.Name != atom + "feed") throw new ServiceError("UpdateInvalidFeed");
            return root.Elements(atom+"entry").Select(entry => {
                var link = entry.Elements(atom+"link").FirstOrDefault(l => ((string?)l.Attribute("rel") ?? "alternate") == "alternate");
                if (!Uri.TryCreate((string?)link?.Attribute("href"), UriKind.Absolute, out var uri) || Tag(uri) is not string tag)
                    throw new ServiceError("UpdateInvalidFeed");
                return tag;
            }).ToArray();
        } catch (XmlException) { throw new ServiceError("UpdateInvalidFeed"); }
    }

    async Task<JsonNode> SelectWeb(string version, string channel, string kind, CancellationToken token) {
        string[] tags;
        if (channel == "Beta") {
            tags = AtomTags(await GetText(Repository+".atom", FeedLimit, u => SecureHost(u,"github.com"), token));
        } else {
            tags = await Timed(async t => {
                using var latest = await Open(Repository+"/latest", HttpMethod.Head, u => SecureHost(u,"github.com"), t);
                var final = latest.RequestMessage!.RequestUri!;
                if (final.AbsoluteUri == Repository) return Array.Empty<string>();
                return Tag(final) is string tag ? new[]{tag} : throw new ServiceError("UpdateInvalidFeed");
            }, TimeSpan.FromSeconds(25), token);
        }

        bool missingAsset = false;
        for (;;) {
            var candidate = native(new {op="webUpdate", current=version, channel, kind, tags}, token);
            if (candidate["url"] == null) {
                if (missingAsset) throw new ServiceError("UpdateMissing");
                return candidate;
            }
            try {
                var sums = await GetText(candidate["checksumsUrl"]!.ToString(), 64*1024, AssetHost, token);
                var size = await Timed(async t => {
                    using var asset = await Open(candidate["url"]!.ToString(), HttpMethod.Head, AssetHost, t);
                    return asset.Content.Headers.ContentLength ?? throw new ServiceError("UpdateIntegrity");
                }, TimeSpan.FromSeconds(25), token);
                return native(new {op="webUpdate", current=version, channel, kind, tags, checksums=sums, size}, token);
            } catch (ServiceError e) when (e.Message == "UpdateMissing") {
                var incomplete = candidate["tag"]!.ToString();
                tags = tags.Where(tag => tag != incomplete).ToArray();
                missingAsset = true;
            }
        }
    }

    public Task CopyAsset(JsonNode plan, Stream destination, Action<long> progress, CancellationToken token) =>
        Timed(async t => {
            using var response = await Open(plan["url"]!.ToString(), HttpMethod.Get, AssetHost, t);
            var expected = plan["size"]!.GetValue<long>();
            if (response.Content.Headers.ContentLength is long length && length != expected) throw new ServiceError("UpdateIntegrity");
            await using var stream = await response.Content.ReadAsStreamAsync(t);
            var buffer = new byte[81920];
            long received = 0;
            int count;
            while ((count = await stream.ReadAsync(buffer,t)) > 0) {
                received += count;
                if (received > expected) throw new ServiceError("UpdateIntegrity");
                await destination.WriteAsync(buffer.AsMemory(0,count),t);
                progress(received);
            }
            if (received != expected) throw new ServiceError("UpdateIntegrity");
            return true;
        }, TimeSpan.FromMinutes(8), token);
}
