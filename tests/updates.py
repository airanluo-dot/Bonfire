"""Use the same native release selector on both platforms."""
import copy
import json
import subprocess

def check(executable):
    kind = "Windows-x64-Setup.exe"
    def release(version):
        tag = "v" + version
        name = "Bonfire-" + version + "-" + kind
        return dict(tag_name=tag, draft=False, prerelease="-" in version, assets=[dict(name=name, state="uploaded",
            size=64, digest="sha256:" + "a" * 64,
            browser_download_url="https://github.com/airanluo-dot/Bonfire/releases/download/" + tag + "/" + name)])
    def select(releases, channel="Beta", current="0.1.0-beta.1"):
        command = dict(op="selectUpdate", current=current, channel=channel, kind=kind, releases=releases)
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
    flag = release("0.2.0"); flag["prerelease"] = True
    assert select([flag], "Stable") == {}
    print("Stable/Beta channels, beta numeric ordering, stable precedence, drafts, equal/older versions, official URLs and integrity metadata: OK")
