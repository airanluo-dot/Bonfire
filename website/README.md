# Bonfire 官网

静态页面位于 `website/_source/`，构建产物位于 `website/dist/`。读取的接口与页面位于同一站点，使用相对地址以支持 GitHub Pages 的仓库子路径。

## 构建

在仓库根目录使用 Node.js 22+、Python 3 和 Git 运行以下命令。离线构建使用已保存的发行快照，需要本地具有对应的发行标签。

```sh
node website/tools/site.mjs build
```

正式发布构建使用 GitHub CLI 读取公开 Releases，验证后生成全部 JSON 和页面。CI 通过只读的 `GH_TOKEN` 调用 API，检出代码时使用 `fetch-depth: 0` 取得发行标签。也可以单独运行 `refresh` 更新快照。

```sh
node website/tools/site.mjs release-build
```

在 Windows 审核生成的站点：

```powershell
py -3 -m http.server 8080 --bind 127.0.0.1 --directory website/dist
```

打开 `http://127.0.0.1:8080/`。生产构建与部署由 `.github/workflows/deploy-website.yml` 管理。

## 数据来源

构建时分页读取 GitHub Releases，忽略草稿，按 Bonfire 版本顺序选择最新公开版。Windows 与 Mac 共用一个发行标签。每份发行资产都需要符合预期的下载地址、文件名、大小与 SHA-256。程序从 GitHub 下载官方校验清单，比对清单本身和四份资产的 GitHub 摘要。验证失败会中止发布。

构建从最新公开发行标签的 Git 树中读取原生适配器注册表、名称、包扩展名、图标和兼容说明。标签内的 VERSION 必须匹配该公开发行版。提前开发的新适配器因此会随对应版本发布进入官网。游戏目录与工作台截图均按图片内容生成资源地址，使更新后的图标能够正确刷新。

| 产物（相对于网站根目录） | 用途 |
| --- | --- |
| `release-data.json` | 下载区的 `current`、`currentVersion` 和 `latest` 指向最高公开版本。另有按版本排序的 `releases`、最新正式版 `stable` 和最新测试版 `beta`。 |
| `api/v1/releases.json`、`api/macos/v1/releases.json` | Windows 与 Mac 各自的发行记录，每条记录的 `assets` 提供安装版与便携版。 |
| `api/v1/{stable,beta}.json`、`api/macos/v1/{stable,beta}.json` | 所选平台与频道下的最新可用版本。Beta 频道也接受后续正式版。没有正式版时，稳定频道的 `release` 为 null。 |
| `api/v1/latest-change.json` | 最新公开版的标题、摘要、发布日期和官方发布页。 |
| `games.json`、`assets/games/` | 该发行版的 `version` 与 `games` 游戏目录。图标、已核对的游戏版本、兼容说明和存档格式供游戏列表与操作示例共用。 |

发行记录含 `tag`、`version`、`name`、`channel`、`publishedAt`、`htmlUrl`、`summary`、`checksums` 和 `platforms`。每个平台的 `installer` 与 `portable` 均含 `name`、`url`、字节数 `size` 和十六进制摘要 `sha256`。浏览器从接口读取这些字段，切换平台即可显示对应文件。桌面应用继续使用自身的 GitHub 更新源。
