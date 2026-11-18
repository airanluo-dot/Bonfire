"""Use the same native release selector on both platforms."""
import json
import subprocess

def check(executable):
    kind = "Windows-x64-Setup.exe"
    def release(version, asset_kind=kind):
        tag = "v" + version
        name = "Bonfire-" + version + "-" + asset_kind
        return dict(tag_name=tag, draft=False, prerelease="-" in version, assets=[dict(name=name, state="uploaded",
            size=64, digest="sha256:" + "a" * 64,
            browser_download_url="https://github.com/airanluo-dot/Bonfire/releases/download/" + tag + "/" + name)])
    def select(releases, channel="Beta", current="0.1.0-beta.1", asset_kind=kind):
        command = dict(op="selectUpdate", current=current, channel=channel, kind=asset_kind, releases=releases)
        result = subprocess.run([executable], input=json.dumps(command).encode(), capture_output=True, check=True)
        return json.loads(result.stdout)
    stages = [release(v) for v in ["0.1.0-beta.2", "0.1.0-beta.10", "0.1.0", "0.2.0-beta.1"]]
    assert select(stages)["version"] == "0.2.0-beta.1"
    assert select(stages, "Stable")["version"] == "0.1.0"
    assert select(stages[:2])["version"] == "0.1.0-beta.10"
    assert select(stages[:2], "Stable") == {}
    assert select([release("0.1.0-beta.1")]) == {}
    assert select([release("0.1.0")], current="0.1.0") == {}
    draft = release("1.0.0"); draft["draft"] = True
    assert select([draft]) == {}
    malformed = release("0.2.0"); malformed["assets"][0]["digest"] = "sha256:invalid"
    assert select([malformed])["error"] == "UpdateIntegrity"
    external = release("0.2.0"); external["assets"][0]["browser_download_url"] = "https://example.com/payload.exe"
    assert select([external])["error"] == "UpdateIntegrity"
    missing = release("0.2.0"); missing["assets"] = []
    assert select([missing])["error"] == "UpdateMissing"
    # The newest tag may publish only one platform, or the platform's upload
    # may still be underway. Find the newest usable asset across every page.
    for target in (kind, "Windows-x64-Portable.zip", "macOS-arm64-Portable.zip"):
        available = release("0.2.0", target)
        pending = release("0.3.0", target)
        pending["assets"][0]["state"] = "starter"
        older_page = [release("0.0.1")] * 100 + [available]
        assert select([pending, *older_page], asset_kind=target)["version"] == "0.2.0"
        detached = release("0.4.0", "sha256-checksums.txt")
        assert select([available, detached], asset_kind=target)["version"] == "0.2.0"
        assert select([pending, detached], asset_kind=target)["error"] == "UpdateMissing"
    for field, value in (("digest", None), ("size", 42.5), ("size", -1),
                         ("size", 512 * 1024**2 + 1), ("size", 2**64-1),
                         ("browser_download_url", "https://example.com/file")):
        damaged = release("0.3.0")
        damaged["assets"][0][field] = value
        assert select([release("0.2.0"), damaged])["error"] == "UpdateIntegrity", (field, value)
    duplicated = release("1.0.0")
    duplicated["assets"] *= 2
    assert select([duplicated])["error"] == "UpdateIntegrity"
    for invalid_feed in (None, {"message": "API rate limit exceeded"}, [None],
                         [dict(release("0.2.0"), draft=None)],
                         [dict(release("0.2.0"), prerelease="true")],
                         [dict(release("0.2.0"), assets=None)],
                         [dict(release("0.2.0"), assets=[None])]):
        assert select(invalid_feed)["error"] == "UpdateInvalidFeed", invalid_feed
    flag = release("0.2.0"); flag["prerelease"] = True
    assert select([flag], "Stable") == {}
    def web(tags, *, channel="Beta", target=kind, **params):
        command = dict(op="webUpdate", current="0.1.0-beta.1", channel=channel, kind=target, tags=tags, **params)
        result = subprocess.run([executable], input=json.dumps(command).encode(), capture_output=True, check=True)
        return json.loads(result.stdout)

    tags = ["v0.1.0-beta.4", "v0.1.0-beta.2", "v0.1.0-beta.10"]
    assert web(tags)["version"] == "0.1.0-beta.10"
    assert web(tags, channel="Stable") == {}
    assert web(tags + ["v0.1.0"], channel="Stable")["version"] == "0.1.0"
    assert web(["v0.1.0-beta.1", "../v9.0.0", "https://example.com/v9.0.0"]) == {}
    assert web([None])["error"] == "UpdateInvalidFeed"
    assert web({})["error"] == "UpdateInvalidFeed"
    tag = "v0.1.0-beta.2"
    base = "https://github.com/airanluo-dot/Bonfire/releases/download/" + tag + "/"
    for target in (kind, "Windows-x64-Portable.zip", "macOS-arm64-Portable.zip"):
        item = release(tag[1:], target)
        name = item["assets"][0]["name"]
        query = web([tag], target=target)
        assert query == dict(tag=tag, version=tag[1:], name=name, url=base + name, checksumsUrl=base + "SHA256SUMS.txt")
        header = "a" * 64 + "  "
        line = header + name
        other = header + "Bonfire-0.1.0-beta.2-macOS-arm64-Installer.pkg"
        future = header + "Bonfire-0.1.0-beta.2-Windows-arm64-Setup.exe"
        sidecar = header + name + ".sig"
        notes = header + "Bonfire-0.1.0-beta.2-版本说明 zh.txt"
        plan = web([tag], target=target, checksums="\r\n".join((other, future, sidecar, notes, line, "")), size=64)
        assert plan == select([item], asset_kind=target)
        assert web([tag], target=target, checksums=other, size=64)["error"] == "UpdateMissing"
        assert web([tag], target=target, checksums=header + name + ".exe", size=64)["error"] == "UpdateMissing"
        for bad in (line+"\n"+line, line+"\n"+other+"\n"+other, line.replace("Bonfire-", "Else-"),
                    line.replace("beta.2", "beta.3"), line+"\n"+future.replace("beta.2","beta.3"),
                    header+"../"+name, line+"\n"+future.replace("Windows-","../Windows-"),
                    line+"\n"+future.replace("Windows-","Windows\\"),
                    line+"\n"+future+"\n"+future.replace("Windows-","windows-"),
                    line[:-1]+"\x00", "g"+line[1:], "", line+"\ninvalid"):
            assert web([tag], target=target, checksums=bad, size=64)["error"] == "UpdateIntegrity"
        for bad_size in (None, "64", 0, -1, 2.5, 512*1024**2+1, 2**64-1):
            assert web([tag], target=target, checksums=line, size=bad_size)["error"] == "UpdateIntegrity"
        assert web([tag], target=target, checksums=line)["error"] == "UpdateIntegrity"
        assert web([tag], target=target, size=64)["error"] == "UpdateIntegrity"
    stable = header + "Bonfire-0.1.0-" + kind
    assert web(["v0.1.0"], checksums=stable+"\n"+future, size=64)["error"] == "UpdateIntegrity"
    print("Stable/Beta ordering, per-platform assets across pages, malformed feeds, official URLs, web fallback and integrity metadata: OK")
