"use strict";

const byId = (id) => document.getElementById(id);
const stepButtons = [...document.querySelectorAll("[data-step]")];
const platformButtons = [...document.querySelectorAll("[data-platform]")];
let activeGame;
let activeStep = 0;
let platform = /Mac/.test(navigator.platform) ? "macos" : "windows";
let releases;
let releaseError = false;

async function fetchData(file) {
  const response = await fetch(file, { cache: "no-cache" });
  if (!response.ok) throw new Error(file + " " + response.status);
  return response.json();
}

function showStep(index) {
  activeStep = index;
  const game = activeGame ? "《" + activeGame.name + "》" : "游戏";
  const steps = [
    ["在 Windows 上提取", "先退出游戏，在工作台选择" + game + "，打开「提取」，把进度保存为一个文件。"],
    ["把文件带到 Mac", "把这份存档包拷到 U 盘，或用你常用的方式发到另一台电脑。原来的文件也可以作为备份保留。"],
    ["在 Mac 上接收", "退出目标游戏，在工作台选择" + game + "，打开「接收」并查看包内进度。确认后点击「替换存档」，再打开游戏继续。"]
  ];
  stepButtons.forEach((button, i) => button.setAttribute("aria-pressed", String(i === index)));
  byId("step-title").textContent = steps[index][0];
  byId("step-copy").textContent = steps[index][1];
}

function selectGame(game) {
  activeGame = game;
  for (const button of byId("game-list").children) {
    button.setAttribute("aria-pressed", String(button.dataset.game === game.id));
  }
  byId("game-detail").hidden = false;
  byId("detail-icon").src = byId("example-icon").src = game.icon;
  byId("detail-name").textContent = byId("example-game").textContent = game.name;
  byId("detail-edition").textContent = game.edition ? "已核对的游戏版本 · " + game.edition : "";
  byId("detail-note").textContent = game.note || "";
  byId("detail-extension").textContent = byId("example-extension").textContent = game.extension;
  byId("demo-label").textContent = "以《" + game.name + "》为例";
  showStep(activeStep);
}

async function loadGames() {
  const { games } = await fetchData("games.json");
  if (!games.length) throw new Error("Empty catalog");
  const fragment = document.createDocumentFragment();
  for (const game of games) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "game-card";
    button.dataset.game = game.id;
    button.setAttribute("aria-controls", "game-detail");
    const img = document.createElement("img");
    img.src = game.icon;
    img.alt = "";
    img.width = img.height = 48;
    const text = document.createElement("span");
    const name = document.createElement("strong");
    name.textContent = game.name;
    const format = document.createElement("small");
    format.textContent = game.extension;
    text.append(name, format);
    button.append(img, text);
    button.addEventListener("click", () => selectGame(game));
    fragment.append(button);
  }
  byId("game-list").append(fragment);
  selectGame(games.find((game) => game.id === "adastra") || games[0]);
}

function downloadLink(asset, title, primary) {
  const link = document.createElement("a");
  link.className = "button " + (primary ? "primary" : "secondary");
  link.href = asset.url;
  const size = new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 }).format(asset.size / 1048576);
  link.textContent = title + " · " + size + " MiB ↓";
  link.title = asset.name;
  return link;
}

function showPlatform(nextPlatform) {
  platform = nextPlatform;
  const windows = platform === "windows";
  platformButtons.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.platform === platform)));
  byId("platform-name").textContent = windows ? "Windows x64" : "Mac · Apple 芯片";
  const current = releases?.current;
  const packages = current?.platforms[platform];
  byId("package-links").replaceChildren();
  byId("download-hint").replaceChildren();
  byId("release-info").textContent = "";
  if (!packages) {
    if (releaseError || releases) byId("release-info").textContent = "请到 GitHub 发布页查看可用下载。";
    return;
  }
  byId("release-info").textContent = current.name.replace(/^Bonfire\s+/i, "") + "　·　" +
    new Intl.DateTimeFormat("zh-CN", { year: "numeric", month: "long", day: "numeric", timeZone: "Asia/Shanghai" }).format(new Date(current.publishedAt));
  byId("package-links").append(downloadLink(packages.installer, "下载安装包", true), downloadLink(packages.portable, "下载便携包", false));
  const notes = document.createElement("a");
  notes.href = current.htmlUrl;
  notes.textContent = "版本说明 ↗";
  const checksums = document.createElement("a");
  checksums.href = current.checksums.url;
  checksums.textContent = "SHA-256 校验清单 ↗";
  byId("download-hint").append(notes, "　·　", checksums);
}

stepButtons.forEach((button, index) => button.addEventListener("click", () => showStep(index)));
platformButtons.forEach((button) => button.addEventListener("click", () => showPlatform(button.dataset.platform)));
byId("use-example").addEventListener("click", () => showStep(0));
showPlatform(platform);
loadGames().catch(() => {
  const fallback = document.createElement("a");
  fallback.href = "https://github.com/airanluo-dot/Bonfire#支持的游戏";
  fallback.textContent = "查看项目中的游戏目录 ↗";
  byId("game-list").replaceChildren(fallback);
});
fetchData("release-data.json").then((data) => {
  releases = data;
}).catch(() => {
  releaseError = true;
}).finally(() => showPlatform(platform));
