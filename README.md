# Bonfire

Bonfire 是原生 Windows 和 Mac 单机游戏存档传送工具。每款游戏使用独立的存档包，同一份包可在 Windows x64 和 Apple Silicon 上接收。

本分支的开发版本为 **0.1.0 Beta 3**。公开发行包见 [Releases](https://github.com/airanluo-dot/Bonfire/releases)。

## 支持的游戏

| 游戏 | 本次核对的发行版 | 存档包 |
| --- | --- | --- |
| 兽劳动 Jurodo | 1.3.0 | `.jurosave` |
| 家有大猫 Nekojishi | Steam 1.06s，含成人补丁和《天气晴》扩展的识别。[Steam](https://store.steampowered.com/app/570840/) | `.nekosave` |
| Adastra | 17。[作者发行页](https://echoproject.itch.io/adastra) | `.adastrasave` |
| Interea | 0.4。[作者发行页](https://echoproject.itch.io/interea) | `.intereasave` |
| Khemia | 0.4 重制版。[作者发行页](https://echoproject.itch.io/khemia) | `.khemiasave` |
| 犹记繁花 第一部 | Part I 下载版 0.17.9。[作者发行页](https://jerichowo.itch.io/remember-the-flowers) | `.rtfsave` |
| 出发！去落雪镇 | 主线 0.5.0.2。[作者发行页](https://yuxiu.itch.io/gotosnowtown) · [双端更新清单](https://api.kittyclub.cc/update.json?app=GoToSnowTown) | `.snowtownsave` |
| 未烬之约 Emberbound | 体验版 1.8 与 1.9.2，接收时检查已知番外资源。[工作室双端下载页](https://www.flufforestudio.com/games/emberbound/?lang=zh-CN) | `.embersave` |

### 补丁和跨设备读档

Bonfire 会一起传送 Ren’Py 的手动、自动、快速和游戏自定义槽位，以及保存画廊、解锁记录和偏好的 `persistent`。它按游戏的存档目录标识定位当前用户的数据。如果游戏同时使用安装目录的 `game/saves`，同名槽取修改时间较新的副本。接收会同步当前安装使用的两处存档。独立 Mac 应用把存档写在用户目录。

接收《家有大猫》时，Bonfire 会检查包中已识别的剧情及回溯位置是否引用成人补丁或《天气晴》。《未烬之约》会检查晟阳番外，《出发！去落雪镇》会检查已知的公开版独有剧情。发现目标缺少存档所需脚本时，预览会显示原因并暂停替换。补齐对应内容后重新选择目标或存档包即可。来源仅装有可选内容、存档没有引用相关剧情的《家有大猫》包可以接收。

同一发行版的 Adastra、Interea 和 Khemia 已核对过本机汉化包，译文和字体沿用原版存档。《兽劳动》把补丁相关开关保存在槽位中，传送时随原档保留。接收设备使用其已安装的语言包和游戏资源。跨剧情重制版或尚未核对的第三方模组，仍取决于游戏自身对旧存档的兼容。

带签名的 Ren’Py 存档会保留原始签名。换机后，游戏可能要求确认来源。若全局解锁未出现，在游戏中载入来自自己设备的槽位并确认信任，退出后再次接收同一个包。只有全局数据时，可先在来源设备新存一个槽位后重新提取。

## 使用

- **游戏工作台**是启动页。在「APP资源库」选择游戏，进入「提取」或「接收」。提取页自动寻找安装和存档，接收页先预览所选存档包，再点击「替换存档」。两个页面均展示一份完整游戏进度和游戏时长。具有多个存档槽时，时长取最近保存的槽位，并标明槽号。
- **存档管理器**从同一个资源库选择游戏，按生成时间从新到旧列出默认保存位置，以及此前成功提取或接收过存档包的目录。可以临时选择其他文件夹。时间线读取这些目录中的实际文件。文件改名后，新格式仍能识别生成时间。原工具的 v1 包从原始文件名恢复本地时间，无法恢复的排在最后。
- **设置**直接打开。可以选择跟随系统、简体中文或 English，更改默认保存位置，或勾选两个资源库中显示的游戏。首次启动显示所有已注册游戏，默认保存到系统桌面。
- 从侧栏重新进入任一游戏栏目或使用「更换游戏」都会返回当前栏目的资源库，并清除先前选中的接收目标。

传送前请退出游戏。发现多个安装时需选定目标。接收只替换模块识别的存档文件，完成后逐文件核验。普通写入错误会用内存中的原内容撤回部分修改。强制终止或断电可中断多文件替换，恢复后可以重新接收同一个包。

Bonfire 使用 Windows 当前用户注册表或 macOS 用户偏好保存配置及时间线所需的文件夹路径。存档功能直接读写用户选择的文件。自动更新仅在下载时使用临时文件，校验成功后把更新包保存在系统“下载”目录。Mac 安装更新时使用同卷临时目录，操作结束后清理。

## 适配新的游戏

1. 在 `adapters/<id>/` 放入 `<id>.cpp`、正方形 `icon.png` 和 `localization/en.json`、`localization/zh-Hans.json`。两个语言表都提供 `Game_<id>` 和模块自己的错误文案。名称和图标随应用分发。稳定 ID 以小写字母开头，只包含小写字母、数字和下划线。
2. 实现 `GameAdapter` 并提供返回静态只读实例的 `transfer::<id>()` 工厂。参考 `adapters/jurodo/`。平台间的游戏目录和数据格式差异由各模块处理。
3. 在 `adapters/catalog.def` 中注册一行 `BONFIRE_GAME(<id>)`。两个平台构建时由同一清单注册适配器并编入资源库。设置保存被隐藏的 ID，以便新适配的游戏默认可见。
4. 验证双方真实游戏安装的定位。使用隔离目录测试首次存档、双向传送、其他游戏的包、损坏数据、重复接收及写入失败。测试专用的第二个适配器位于 `tests/fixture.hpp`。

| 接口 | 职责 |
| --- | --- |
| `GameInfo` | 稳定 ID、专属 8 字节包标识、扩展名、可执行文件和定位线索 |
| `identify`、`installation` | 识别安装、规范化数据根目录和安装位置 |
| `saveDirectory`、`inventory` | 定位存档并返回结构化进度、游戏时长和对应的槽位 |
| `acceptsEntry`、`validate` | 定义包内白名单并验证完整性，预览时只读 |
| `capture`、`install` | 在游戏磁盘布局与通用条目之间转换，负责受控写入和失败恢复 |

## 原生应用和共享层

`windows/` 使用 WinUI 3、NavigationView、SelectorBar 与系统文件选择器。`macos/` 使用 AppKit、NSSplitViewController、统一工具栏、NSSegmentedControl 与 NSOpenPanel。两个工作台都调用 `app/runtime.cpp` 中的应用服务。服务按游戏 ID 查找适配器，负责进度读取、包预览、提取、替换和时间线查询。接收时重新检查预览过的包摘要。页面切换取消旧扫描并丢弃过期结果。

`core/discovery.cpp` 根据模块的识别规则扫描安装位置。`core/transfer.cpp` 在传送前复核游戏身份和运行状态，加锁并核对读写结果。`core/save_files.cpp` 提供平面存档目录替换及写入错误时的内存撤回。模块可自行实现不同结构的安装逻辑。

`core/package.cpp` 使用小端编码。v2 文件包含游戏标识、32 位格式版本、64 位 Unix 生成时间（毫秒）、32 位条目数、条目和末尾 SHA-256。每项保存 32 位名称长度、32 位数据长度、ASCII 逻辑名及原始数据。每包最多 256 项。《兽劳动》每项上限 16 MiB、总数据上限 64 MiB。Ren’Py 每项上限 64 MiB、总数据上限 256 MiB。读取器保留对 v1 的支持。原先仅实现 v1 的客户端无法打开新写出的 v2 文件。

## 双语开发约定

通用界面文案维护在 `localization/`，游戏名称和专属文案维护在游戏自己的目录。共享层返回稳定标识、参数和数值。界面使用对应语言资源完成排版，可通过 `{0}`、`{1}` 调整语序，日期使用系统日期格式器。游戏包内已有的名称、文件名和路径按原文呈现。

两端构建都先运行 `tools/resources.py`。它检查两个语言表的键集、重复键、空翻译、位置参数和游戏名称，生成 Windows MRT Core 的 RESW 以及 Mac 的 Localizable.strings 和 InfoPlist.strings。新增界面文案从源语言表修改，生成文件仅参与构建。

## 构建和测试

- **Windows 11 x64** 需要 Visual Studio x64 C++ 桌面工具、Windows SDK、.NET 10 SDK 和 Python 3。运行 `windows\build.cmd`。完整程序在 `build-win\publish\`，双击 `Bonfire.exe`。发布时分发整个目录。
- **Apple Silicon** 需要 Xcode 命令行工具和 Python 3。运行 `sh macos/build.sh` 生成 `build-mac/Bonfire.app`。在装有 Xcode 27 的 Mac 上使用其 SDK 构建。脚本做本地 ad hoc 签名并调用 codesign 严格校验。公开发行的 Developer ID 签名、公证需要发布者凭据。
- 两个构建脚本均可传入输出目录。在 Windows 的 x64 Native Tools 命令行中运行 `py -3 tests/run.py`，在 Mac 上运行 `python3 tests/run.py`。测试自动创建并清理临时游戏目录，检查完整往返、独立适配器、文件占用、v1 兼容、时间线排序与预览内容绑定。

第三方代码许可见 `vendor/NOTICES.txt`。各游戏图标取自对应发行版，用于在 Bonfire 中识别游戏。

Bonfire 的 Logo 以 `branding/Bonfire.svg` 为唯一设计基准。更新 Logo 时，从这份矢量原稿导出并同步替换 `branding/app.ico` 和 `branding/AppIcon.icns`。Windows 应用、安装器和快捷方式共用 ICO，macOS 应用使用 ICNS。构建时直接复制对应平台的图标，保留全部尺寸和透明通道。

版本号来自 `VERSION`。Windows 使用 Inno Setup 6.7.4 和 `windows/package.ps1`，Mac 使用 `sh macos/package.sh <Bonfire.app> <输出目录>`。构建工作流会在 Windows x64 和 macOS 27 Apple Silicon 上执行存档测试，并安装生成的包进行核对。

## 自动更新

设置提供自动检查、自动下载、自动安装、稳定版与 Beta 通道、上次检查时间和手动检查按钮。首次启动开启检查和下载，自动安装默认关闭，测试版本默认选择 Beta 通道。自动检查在启动时进行。

版本筛选在共享 C++ 层实现。稳定版只接收正式发布，Beta 接收正式版及测试版。比较顺序为主版本、次版本、修订号、测试序号，同数字版本的正式版排在测试版之后。草稿、相同版本和旧版本被过滤。两端从 Bonfire 官方 GitHub Releases API 读取已发布附件，核对对应平台的文件名、大小、来源和 SHA-256 后才允许安装。没有合适附件或完整校验信息时会显示错误。

Windows 安装版调用已校验的每用户安装器并重新启动。Windows 便携版按 DropSpace 的行为下载 ZIP 后由用户解压替换。Mac 原生更新器检查新应用的 bundle ID、版本与签名，再以同卷原子交换替换可写位置中的应用。只读位置或系统转置位置会显示手动处理提示。存档传送进行时延迟安装。

本预发布尚无 Windows Authenticode 签名、Apple Developer ID 签名和公证。Mac 应用使用 ad hoc 签名。系统首次运行时可能要求用户在安全设置中确认来源。校验结果可通过 GitHub 附件的 digest 与 SHA256SUMS.txt 核对。
