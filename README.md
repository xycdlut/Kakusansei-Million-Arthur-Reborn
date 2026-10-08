# 扩散性百万亚瑟王 · 本地复原运行环境

在 Windows + 安卓模拟器上，用**自建服务端**把已停服的《扩散性百万亚瑟王》国服客户端跑起来，用于局域网怀旧游玩与协议研究。

仓库内只有**服务端源码、运行脚本、配置与运行所需资源**；客户端 APK 与游戏素材不入库，需由使用者从自己的备份导入。

> 许可与声明见 `kakusansei-ma-ch-main/LICENSE`（PolyForm Noncommercial 1.0.0）与 `NOTICE`：  
> 游戏名称、角色、美术、音频等权利归原权利人所有，本项目仅提供协议兼容服务端，非商业用途。

---

## 一、参考了哪些项目

| 项目 / 来源                                        | 作用                                                                                                                                   |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| **kakusansei-ma-ch**（`kakusansei-ma-ch-main/`） | 本项目所基于的上游工程：《扩散性百万亚瑟王》客户端的 Go 协议兼容服务端，提供世界列表、游戏 API、SQLite 玩家存档与资源 CDN。采用 **PolyForm Noncommercial 1.0.0**（见 `kakusansei-ma-ch-main/LICENSE`）。本发布版只保留它编译出的服务端二进制与许可文件，**源码请见上游**。**本项目在其上做的增量见第七节**                   |
| **KSSMA-Re-main**（扩散性百万亚瑟王重建项目）                | 协议考古与逆向文档的主要参考：战斗/探索/妖精的报文结构、原生解析器符号与字段表、客户端重打包与旧域名映射方案、资源缺口的处理经验（缺贴图会触发 `GetObjectClass(null)` 类崩溃）。客户端原生库的空指针加固思路（`nullguard`）也源于此 |
| **Internet Archive · gacha-archive**           | 原始客户端 APK 与游戏资源 ZIP 的获取来源（见参考项目 readme 中记录的 SHA-256）                                                                                 |
| 日服 mobile wiki 的「経験値・フレンド数一覧」                  | 玩家等级经验曲线中 Lv17–26 的逐条依据（见 `internal/game/level_exp.go` 文件头注释）                                                                        |
| ma3ds.wiki.fc2.com 的 3DS 候选表                   | 等级曲线其余区间的近似来源（可延伸到 Lv200）；与手游版本不同，视为近似                                                                                               |

客户端资源解密所用的密钥（`A1dPUcrvur2CRQyl`）来自参考项目的恢复成果，见 `internal/wire/wire.go` 与 `cmd/kakusen-imgtool/main.go` 注释。

> **许可与声明**：上游 `kakusansei-ma-ch` 采用 **PolyForm Noncommercial License 1.0.0**，本项目及其增量同样**仅限非商业使用**。本仓库包含从原版客户端提取/派生的文件（原生库补丁、主数据表等），版权归原权利人所有，随仓库提供不构成授权；原版 APK 与资源 ZIP 未包含在内。详见 [`NOTICE.md`](NOTICE.md)。

---

## 二、运行环境要求

**宿主（Windows）**

- Windows 10/11，PowerShell 5.1（仓库内脚本均为 ASCII-only 以适配它）
- **Go 1.25**（`server/go.mod` 声明）——仅在需要**编译**服务端时必需；只运行现成二进制可不要。工具链须放在仓库内 `toolchain/go/go/`（见 §3.4）
- 模拟器自带 `adb`
- **Python 3 + openssl**（Git for Windows 自带）——一键安装第 4 步重打包 APK 需要；缺了也能装，只是退回原版客户端（强化时播放属性变化演出）。`patch-client-apk.py` 只用标准库，不需要装任何包
- 端口占用：游戏服务 **`:50005`**（客户端硬编码）、管理后台 **`127.0.0.1:26031`**

**模拟器（客户端）**

- 支持 **armeabi（32 位 ARM）** 的安卓实例 —— 这是硬要求，客户端是 ARMv7 原生库
- 实测环境：**雷电模拟器**（实例 0 已连接为 `emulator-5554`，Android 5.1.1 / SDK 22，abilist 含 `armeabi`）；多开实例依次为 5557、5559…
- 客户端版本：国服 **140330**
- 不要随意改动模拟器的分辨率 / density（会影响布局与点击）

**不入库、需自备的原始素材**（版权原因，仓库不分发）

- 客户端 APK：`com.square_enix.million_cn-1.0.0.100.0712.M330.apk`
- 资源包：`com.square_enix.million_cn-140330.zip`
- 放进**仓库根目录或 `base/`** 都可以，`install-all.ps1` 两处都会找；解包出的 `files/save` 同时用于服务端资源集与设备资源

**服务端二进制已随仓库提供**（`kakusansei-ma-ch-main/server/dist/kakusan-server.exe`），  
所以全新环境**不需要安装 Go**；只有要改服务端代码时才需要 Go 工具链重新编译。  
构建用的 Go 工具链（`toolchain/`）**不入库**，需自备 —— 见 §3.4。**一键安装不受影响**：  
`install-all.ps1` 全程走 `-NoBuild`，不触发任何编译。

---

## 三、安装与运行步骤

> **本仓库是「运行发布版」**：只包含**新玩家安装与运行所必需**的文件 —— 服务端二进制、资源集元数据、客户端原生库补丁、重打包所需的布局与自签密钥、一键安装脚本。**不含**服务端源码（`internal/`、`cmd/`）、回归测试、`build.ps1` / `go-env.ps1` / `gen-resource.ps1` 等开发脚本，也**不含任何原始游戏资源**（那些由你自己的资源 ZIP 解压得到）。
>
> 所以下面 **§3.3（生成资源集）与 §3.4（构建服务端）属于开发流程**，只有在拿到完整源码时才用得上。**安装游玩请直接看 §3.0**。

### 0. 全新环境：一键安装（推荐先试这个）

手头只有三样东西——**原版 APK**、**资源 ZIP**、**装好的雷电模拟器**，其余什么都没有时：

1. 把 APK 与 ZIP 放进仓库根目录（或 `base/`，脚本两处都会找）
   ```text
   <你 clone 出来的目录>/
   ├─ com.square_enix.million_cn-1.0.0.100.0712.M330.apk
   └─ com.square_enix.million_cn-140330.zip
   ```
2. 双击或在 PowerShell 里执行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\install-all.ps1
   ```

脚本按顺序做 9 件事，每步都会打印进度：

| 步     | 动作                                                           | 说明                                                                                                                            |
| ----- | ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| 1     | 定位 APK / ZIP / adb / ldconsole / python / openssl，检查**雷电实例** | **只认雷电**：先用 `ldconsole` 确认实例在跑，再只接受该实例的 adb serial，同机上其他模拟器（MuMu / 夜神 / 蓝叠）一律忽略；**雷电装在哪都能找到、盘符数量不限**（见下）；素材不在根目录时用 `-Apk` / `-Zip` 指定；会校验实例含 `armeabi` |
| 2     | 解压资源 ZIP 到 `base\140330`                                     | 约 490 MB，已解压过则跳过                                                                                                              |
| 3     | 把客户端资源复制进 `runtime\resource-set`                             | 服务端要用的那一份，已存在则跳过                                                                                                              |
| **4** | **重打包 APK**：换掉 7350 演出布局 + 自签重签名                             | 见下方说明；缺 Python 3 / openssl 时**降级装原版并醒目警告**，`-SkipApkPatch` 可主动跳过                                                              |
| 5     | `adb install` 客户端 APK                                        | **先卸载旧版本**：自签包签名不同，无法覆盖安装                                                                                                     |
| 6     | 把整棵资源树推到设备                                                   | 约 6900 个文件、500 MB，最慢的一步                                                                                                       |
| 7     | 给客户端打原生库补丁                                                   | 见下方说明；`-SkipLibPatch` 可跳过                                                                                                     |
| 8     | 启动服务端                                                        | 自动探测本机 LAN IPv4，监听 `:50005`                                                                                                   |
| 9     | 启动客户端                                                        | 走 `start-game-ld.ps1`：hosts 劫持、代理、master_card 锁定                                                                              |

常用开关：

```powershell
-SkipClient      # 只装服务端，客户端步骤全跳
-NoLaunch        # 只准备环境，不启动游戏
-Apk / -Zip      # 素材不在默认位置时指定
-Python <path>   # 重打包 APK 用的 Python 3；不在 PATH 上时指定
-SkipApkPatch    # 不重打包，直接装原版（强化时会播 7350 演出）
-LdIndex <n>     # 指定用哪个雷电实例；默认自动检测正在运行的那个
-LdConsole <path> # 雷电装在非常规位置时手工指定 ldconsole.exe（文件或所在文件夹）
-Adb <path>      # 同理指定 adb.exe；任意 adb 都能用（装包/推文件它都行）
-NoLaunchLd      # 不要自动启动雷电（默认：没有实例在跑时会自动拉起）
-Serial          # 默认取该雷电实例的 serial，一般不用填
-Pause           # 出错时停住，方便看信息
```

> **只驱动雷电。** 脚本不采用 `adb devices` 的「第一个在线设备」——那块 adb server 是所有模拟器共用的，  
> 选错就会把 500 MB 客户端装到 MuMu / 夜神 / 蓝叠上，之后推送与启动步骤会以看似「客户端 bug」的方式失败。  
> 脚本改为先问 `ldconsole list2` 哪些雷电实例在跑，再按「实例 i 的 adb 端口 = 5555+2i」推出合法 serial  
> （`127.0.0.1:5555` 或 `emulator-5554`），只在这个白名单里选设备；雷电没运行就直接报错停下。
>
> **实例号是每次运行实时检测的**，不会写死 `0` —— 今天开的是 #0、明天是 #2 都不影响：脚本自动挑  
> 那个正在运行的实例，多个实例同时在跑时会打印用的是哪个并提示可用 `-LdIndex <n>` 指定。  
> **一个实例都没在跑时会自动拉起**（`ldconsole launch`），不需要先手工打开模拟器；想让它只报错不动手就加  
> `-NoLaunchLd`。`start-game-ld.ps1` 同样默认自动检测（`-Index -1`），没有实例时拉起第一个。  
> 冷启动可能要一分钟，脚本每 15 秒打印一次「still booting」，最长等 180 秒。
>
> **雷电装在哪里都能找到，盘符数量不限。** 安装路径是任意的——任何盘符、任意层级，目录名通常还含中文——
> 所以脚本**不写死任何路径**，按可靠性依次尝试：
> ① 正在运行的 `dnplayer.exe` 自己所在的目录（最准，雷电开着时必中）；
> ② 雷电的卸载注册表项（`…\Uninstall\dnplayer` 的 `UninstallString`，雷电没开也能用）；
> ③ 逐卷有界搜索（深度 5，会打印进度，通常最后才走到）。
>
> 卷是**运行时枚举**的（`[System.IO.DriveInfo]::GetDrives()`），不是盘符列表——单 C 盘的机器和十个盘的机器
> 都不用改代码。扫描顺序：固定盘 → 可移动盘/虚拟盘（`subst`、VHD 映射的盘会报成 `Unknown`，一并纳入）→
> **没有盘符的卷**（走 `\\?\Volume{…}\`，小于 2 GB 的跳过，那是 EFI/恢复分区）→ **挂载到文件夹的卷**
> （`Get-ChildItem -Recurse` 不会进入挂载点，靠 `Win32_MountPoint` 补上）。
> **网络盘刻意跳过**：映射盘掉线时会卡住好几分钟，而且雷电也没法从网络盘运行。
>
> 三条路全落空时脚本会**直接问你要「包含 ldconsole.exe 的那个文件夹」**；无人值守场景可以加
> `-LdConsole <path>` / `-Adb <path>` 显式指定。这套定位逻辑集中在 `scripts/find-ldplayer.ps1`，
> 四五个脚本共用一份，不再各写一份盘符列表。

**为什么资源必须推送，不能让客户端自己下？**  
客户端把 500 MB 资源放在 `/sdcard/Android/data/<pkg>/files/save/`，**从不向服务端拉取**——实测整个会话的请求日志里 `/contents/` 命中数为 **0**；而服务端用 `--suppress-revisions` 启动，客户端自带的 pack 下载器也不会去补。所以**不推资源就没有卡面、没有语音**。

**关于第 4 步的 APK 补丁**（`scripts/patch-client-apk.py`）：  
强化合成本来有两段演出 —— 7350 的「球体动画 + **属性变化覆盖层**」（成長率% / LV·HP·ATK 旧→新 / 界限突破 / `TOUCH SCREEN`），以及 7400 的卡牌详情结果页。第 4 步把 7350 里的进场行为从 `c_buildup` 换成引擎自带的 `skip`，**只去掉覆盖层、保留结果页**。（这也是当初选客户端方案而不是服务端方案的理由：服务端把 `nextScene` 改到 7300 会连结果页一起没有。）

为什么必须动 APK：客户端把 `bundle/<name>.xml` 解析到**自己的包内**，丢到 `/sdcard/Android/data/<pkg>/files/bundle/`、`/sdcard/bundle/`、`/data/data/<pkg>/files/bundle/` 三处都无效（实测）。

代价是**必须换签名**：原包是 `GAMEPLUS` 私钥签的（拿不到），脚本用 `runtime/keys/kakusen-mod.pem|crt` 里的自签 RSA-2048 重新签（首次运行会自动生成）。所以第 5 步**必须先卸载再装**，`adb install -r` 一定被拒。

依赖只有两样：**Python 3**（`patch-client-apk.py` 只用标准库）和 **openssl**（Git for Windows 自带）。两者缺一时**不会中断安装**：脚本改为装原版 APK，并醒目警告「强化时会播放属性变化覆盖层」，同时说明补上什么再重跑。产物缓存在 `apk/kakusen-client-patched.apk`，下次运行直接复用（删掉即可强制重建）。

**关于第 7 步的库补丁**（`runtime/lib/librooneyj-rarenull.so`）：  
装完原版 APK，客户端原生库还是原版的，而它有两处缺陷会**直接崩溃**——`ResourceManagerEx::getMasterBoss` 在 boss 表空槽时不判空、`_AnmExpAppFairy::setRareFairy` 取立绘时对空对象不判空。补丁库同时修掉这两处，并让觉醒妖精显示觉醒形态立绘。脚本用 `su` 覆盖 `/data/app/<pkg>-*/lib/arm/librooneyj.so`，改前会在设备 `/data/local/tmp/librooneyj.so.orig` 留一份回滚点。

> ⚠️ 需要模拟器已 **root**（雷电默认开启）。若客户端 APK 是 `extractNativeLibs=false`（库不从 APK 解包），脚本会检测到并跳过这一步——那种情况下需要改用重打包的 APK。

**验证到什么程度**：语法与 ASCII 校验通过；第 4 步的重打包在干净环境实跑，产物 md5 与原库的已知良好构建**一字不差**（`f8a5002da91f10b88220ea783319a359`，798 条目、`-- verify --` 全绿）；第 1 步的雷电白名单 / 实时检测 / 自动拉起均已实测（同机挂着 MuMu 时正确忽略它，只驱动雷电实例）。**雷电定位**在四个盘符（C/D/E/F）+ 一个 `subst` 造出的临时盘符上实测：装在 E: 盘深层目录（老写法永远扫不到）能被逐卷搜索命中，进程路径与注册表项都能独立定位到真实安装。客户端安装、资源推送、服务端启动三步各自实机跑通。**一次不中断的完整端到端**尚未跑完——第 6 步推送约 6900 个文件要十几分钟。出错时脚本会停在现场（`-NoPause` 可关掉）。

---

以下分步说明适合**了解细节**或**只做其中一步**时参考。

### 1. 准备原始文件

把未解压的资源 ZIP 和 APK 放入仓库根或 `base/`。校验值见参考项目 `readme.md`。

### 2. 安装客户端到模拟器

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-client.ps1 -Adb "<你的雷电安装目录>\dnplayer2\adb.exe"
```

（`-Serial` 默认 `emulator-5554`；`-Adb` 必填，因为模拟器安装路径往往含非 ASCII 字符、脚本本身需保持 ASCII-only。）

默认走 **loopback**（`adb reverse`），服务端需用 `--base-url http://127.0.0.1:...`；  
走 LAN 模式则要在 Windows 防火墙放行端口（需管理员）。

### 3. 生成资源集

以设备备份中的 `.../files/save` 为输入，解码 `database` 主数据、读取 `appdata/save_version`、复制 `download` 资源树：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\gen-resource.ps1 -Source "F:\path\to\files\save"
```

产出 `runtime/resource-set/`：`resource-set.json`、`master/master.json`、`content.json` 与 CDN 资源树。

### 4. 构建服务端（改了 Go 代码才需要）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

产出三个程序到 `kakusansei-ma-ch-main/server/dist/`：`kakusan-server.exe`（主服务）、`kakusan-resource.exe`、`kakusan-probe.exe`。

**工具链从哪来**：`build.ps1` 会先加载 `scripts/go-env.ps1`，后者把仓库内的  
`toolchain/go/go/` 设为 `GOROOT`、把 `toolchain/gopath`、`toolchain/gocache` 设为  
`GOPATH`/`GOCACHE`（外加 `GOPROXY=https://goproxy.cn`），因此**不需要系统装 Go、  
也不用配环境变量**。但 `toolchain/` 目录本身**不入库**（`.gitignore` 里的 `/toolchain/`，  
约 264 MB），要从别处补上：

- 从旧的开发目录整体复制 `toolchain/go/` 过来；或
- 到 go.dev 下载 Windows 版 Go 1.25，解压成 `toolchain/go/go/`（即  
  `toolchain/go/go/bin/go.exe` 必须存在）

缺失时的报错是 `Go toolchain not found: <仓库>\toolchain\go\go\bin\go.exe` ——  
如果那台机器上用的是指向别处的软链接，断链也会报同一条，注意看链接目标是否存在。

> 只想**安装 + 游玩**的话这一步完全用不到：`install-all.ps1` 第 7 步调的是  
> `restart-server.ps1 -NoBuild`，而 `restart-server.ps1` 只在没传 `-NoBuild` 时才调  
> `build.ps1`。整条安装链不碰 `toolchain/`。

### 5. 启动服务端

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\restart-server.ps1
```

该脚本以固定参数脱离会话启动 `kakusan-server.exe`（游戏 `:50005`、后台 `127.0.0.1:26031`，含 `--suppress-revisions --skip-tutorial`，并在 `base/140330/.../save/database` 存在时自动加 `--raw-master`）。  
加 `-NoBuild` 可跳过编译，`-LaunchGame` 会顺便重启客户端。

需要看日志时用前台模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-server.ps1 -Resources .\runtime\resource-set -BaseURL "http://192.168.1.3:50005" -Listen ":50005"
```


### 6. 启动游戏（推荐一键脚本）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-game-ld.ps1
```

启动脚本会自动完成：定位模拟器与 adb、校验 armeabi、**hosts 劫持 + 代理**、锁定 `master_card` 与 `appdata`、拉起游戏并确认进入前台。  
常用开关：`-HostAddr <ip>`（自动探测失败时手动指定）、`-FixSave`、`-NoLaunch`（只预检不启动）、`-Admin`（顺手打开后台）、`-Pause`。

> 游戏真正的入口 Activity 是 `com.test.enter.LogoActivity`（不是崩溃日志里常见的 `RooneyJActivity`）。

### 7. 后台管理

浏览器打开 <http://127.0.0.1:26031/>，可编辑配置、查看玩家与资源。改完点「应用」即时生效（服务端进程不需要重启，除非改了 Go 代码）。

---

## 四、游戏内各系统

配置集中在 `runtime/resource-set/content.json`，也可在后台「游戏配置」下修改。

### 探索与秘境（`areas`）

- 12 个区域，每区有若干楼层（`floors`），楼层带 `cost`（AP）、`progress`、`exp`、`gold`
- 区域可配置 `fairy_level`（该区妖精基础等级）、`min_level`（进入等级门槛）、背景与 BGM
- 前进消耗 **AP**，AP 按 `progression.ap_interval` 秒恢复 1 点
- 前进中按 `fairy.encounter_pct` 概率遇到妖精；走到该区 BOSS 楼层触发守护者战
- 通关条件与楼层进度由服务端记录（存档 SQLite）

### 妖精（`fairy`）

- 发现妖精后可选择自己讨伐或向好友求助；讨伐消耗 **BC**（`progression.bc_interval` 恢复）
- **普通妖精**：等级 = 区域 `fairy_level` + 0~2 随机；HP = 主数据表血 ×(1+(Lv-1)×每级成长%)
- **觉醒妖精**：击杀普通妖精后按 `rare_pct` 概率刷出。它是**一只新妖精**，从 **Lv1** 开始；**把上一只觉醒妖精打死**，下一只同名的才 +1 级（按 boss 分别记录，不同名互不继承）。HP 另含 ×3 系数
- 觉醒妖精出现动画会展示其**觉醒形态立绘**（`boss_full<master_card_id>`，即 5000+image）；只有约 79 只有专属觉醒立绘，其余显示原图
- 奖励：金币 = BC × `gold_per_bc`；经验 = BC × `exp_per_bc_pct`%，clamp 在 `exp_min`~`exp_max`；**无论胜败都给**（被妖精击倒不算战败、不扣东西）。击杀额外给绊点、按 `reward_card_pct` 掉卡
- 妖精有存活时限，超时逃走（`exploration/fairy_lose`）

### 守护者（秘境 BOSS）

- 每区特定楼层是 `is_boss` 层，BOSS 为 `boss_id` 指定的 master boss
- **血量直接用主数据表血**（不再按等级缩放），因此后台看到的数值与战斗内一致
- 守护者卡面若指向不存在的卡，会自动回落到 `card_image_id`（避免客户端崩溃）

### 战斗（`battle`）

- 卡组 **12 槽 = 4 行 × 3 列**，**每回合出一行**（从左到右），8 回合正好每行轮到两次（原版上限）
- **原版技能判定**：每行一次最多一张卡发动技能，从左到右轮流判定
- 技能数值取自主数据文本；无数值的技能用 `fuzzy_skill_pct` 兜底，发动率默认查逐卡表（`flat_skill_rate` 可强制统一）
- EX 槽每回合 +`ex_gauge_per_turn`，满 100 自动放必杀
- 我方伤害可整体缩放：`battle.damage_pct`（100 = 不变，200 = 双倍；只作用于我方卡，含必杀）
- 敌方妖精每回合伤害 = 其最大 HP × `fairy_atk_pct`%
- 战斗在任一方血量归零时结束；打满 8 回合双方都活着也会结束

### 卡牌

- **获得**：扭蛋、妖精掉落、活动/剧情奖励；`starter.decks` 按国家（1/2/3）给出初始卡组
- **强化**：消耗素材卡提升等级；`compound.material_exp` 定义各素材卡提供的经验值
- **界限突破（LimitOver）**：提升等级上限，属性按 `master/limitover_stats_gen.go` 的表推进；不同稀有度有上限
- **交换**：`card/exchange`
- **卡组编辑**：`cardselect/savedeckcard`，12 槽按行摆放影响出牌顺序

### 扭蛋（`gachas`）

- 3 个卡池，按 `currency`（`friendship` 友情点 / 水晶等）与 `price`、`bulk` 定价
- `weights` 决定稀有度权重，`holo_pct` 决定全息（闪卡）几率

### 活动（`events`）

`content.json` 里可选的 `events` 块，一条就是一期限时活动。它**只做描述**，点到的东西都由既有机制服务：

| 部件         | 载体                     | 说明                                            |
| ---------- | ---------------------- | --------------------------------------------- |
| 活动卡池       | `gachas[]`（活动自带）       | 与全局卡池同一套抽取代码，只在活动期间出现                          |
| 活动秘境       | `area`（活动自带）           | 秘境本体 + 每层 `clear_rewards`                     |
| 活动妖精与掉落    | `fairies[]`            | 按 `boss_id` 索引，同一只妖精在不同活动可以掉不同的东西              |
| 收集品达标奖励    | `token_ladder`         | 攒够 `need` 自动进奖励箱，填了 `cycle` 就整张表一轮一轮走          |
| 结算排名奖励     | `rank_rewards[]`       | 按收集品数量排名发档位奖，后台点「结算」发放，每角色一次                   |

- **没有兑换所**：奖励是攒够就发，不是拿收集品换的
- **秘境两种形状**：`endless: true` 是无尽刷素材的场馆（不累加进度、不解锁下一层、没有守护者层）；不填则是分层一本道，走通一层解锁下一层并发该层的通关奖励
- **活动倍卡**（`bonus_cards`）：被点名的卡**只加攻击、不加血量**——倍卡是「这张卡打得更疼」，不是「更耐打」；战斗里玩家的血量就是卡组各卡血量之和，血量一起加成等于额外发了生命值。加成只在 `CardView.Stats()` 一处计算，卡面 / 卡组页 / 战斗读的都是它，所以**面板上看到多少、打出来就是多少**。`rate_pct` 是加成百分比（50 = 1.5 倍）
- **掉落表**：`card_id` 是本体卡（`0` = 取 boss 表的 `master_card_id`），`drop_pct` 是它在本次抽取里的权重。本体卡 + 副卡 + 活动 `drop_pool` 单次加权抽，**击杀必掉且只掉一张**。掉表没点名、但秘境刷得出的妖精走默认规则（本体卡 + 全局掉率 + 本期收集品），不会出现「打完什么都不发」
- **收集品**：`token_mode: formula` 按伤害算 —— 普妖 = 等级 ×10× 伤害占比，觉醒 = (1000+等级×40)× 伤害占比，向上取整到 10、**最低 10**，并且**每次攻击都结算**（不是击杀才发）。伤害按妖精剩余血量与血量上限双重截断，**超杀不算**，所以尾刀最少
- **回放历史活动**：活动都按真实的 2013 日期存着，所以今天没有一期是开着的。给该活动加 `force_open: true` 就能忽略所有日期窗口重新开起来，改回 `false` 即关闭
- 已复刻：**2013 炎夏の狂欢 · 激爽夏日秘境**（14 层沙滩秘境 + 11 连水晶卡池 + 礼盒收集品阶梯 + 10 档排名奖励），依据官方活动公告整理

> ⚠️ **秘境 id 就是战斗背景的选择器**：客户端拿服务端回的 `back_id`（就是秘境 id）去取 `save/download/rest/battle_ef_bgNN`。这份资源集里 **00–12、15–17 有，13 和 14 是空洞** —— 编号 13 的秘境照常进、照常遇妖，**一开战整个进程 SIGABRT**（`JNI GetObjectClass: java_object == null`）。活动秘境因此排在 **15** 号；要再加活动，先 `ls rest/ | grep battle_ef_bg` 确认目标编号有背景，**别顺着往下推**。填错会在**服务端启动时**被自检拦住并点名。
>
> ⚠️ **`bg` / `bgm` 必须填真实存在的资源名**：`bg` 取 `image/adv/` 下的名字（现有秘境统一用 `adv_bg14`），`bgm` 取 `sound/` 下的名字（如 `bgm_sarch1`，实际文件是 `bgm_sarch1.ogg`）。填错了服务端照常启动，进秘境那一刻客户端才崩，且 tombstone 不会告诉你是哪个文件。

### 商店（`shop`）

- 售卖道具（如 AP/BC 回复药），货币 `cp`；`menu/buyproduct`、`menu/goodlist`

### 好友（`friend`）

- 申请 / 批准 / 拒绝 / 删除 / **点赞（like_user）**
- 友情点是扭蛋货币之一，上限见 `progression`

### 其他系统

| 系统                       | 说明                                                      |
| ------------------------ | ------------------------------------------------------- |
| 剧情（`story` / `scenario`） | 按章节推进，主线章节来自 `master_scol`；剧本文件 `scsc_<section><phase>` |
| 道具（`item`）               | `item/havelist`、`item/use`                              |
| 排行（`ranking`）            | 玩家排行相关接口                                                |
| 圆桌（`roundtable`）         | 圆桌相关                                                    |
| 评论（`comment`）            | 玩家留言 / 打招呼语                                             |
| 城镇事件（`town_event`）       | `menu/gettownevent`                                     |
| 登录奖励（`login_bonus`）      | 7 天循环奖励                                                 |
| 公告（`notices`）            | 登录时推送                                                   |
| 图鉴 / 收集                  | `menu/cardcollection`                                   |
| 战斗记录                     | `menu/battlehistory`                                    |

---

## 五、后台管理（127.0.0.1:26031）

| 分组   | 页签                             | 内容         |
| ---- | ------------------------------ | ---------- |
| 运营   | 总览、卡池管理                        | 运行状态、扭蛋卡池  |
| 游戏配置 | 区域秘境、商店、起始配置、成长规则、妖精与战斗、公告与主菜单 | 绝大部分玩法数值   |
| 活动   | 活动蛋池、活动秘境、活动奖励                  | 一期活动拆成三页，都写同一个 `events[]` 条目 |
| 数据   | 玩家管理、虚拟好友、主数据资源、资源集、日志与备份      | 存档与资源查看/维护 |

活动三页：**活动蛋池**管本期自带的卡池，**活动秘境**管本期自带的秘境（楼层名与通关奖励、每只妖精掉哪张卡与掉率、收集品规则、活动倍卡），**活动奖励**管收集品是哪个道具、攒够多少自动送什么、结算排名发什么。「活动信息」（ID / 名称 / 开放关闭时间 / 强制开启）三页共用同一份数据，在哪页改都一样。

常用旋钮：

- **妖精与战斗 → 每级属性成长 %**：妖精 HP = 表血 ×(1+(Lv-1)×该值/100)
- **妖精与战斗 → 我方卡片伤害 %**：只缩放我方输出，用来调难度
- **妖精与战斗 → 觉醒妖精出现动画**：关掉可规避客户端演出崩溃（排障用）
- **区域秘境 → 妖精基础等级**：实际等级 = 此值 + 0~2 随机

> ⚠️ 后台保存是**整份对象回写**：如果某个页面打开得很早，之后别人（或别处）改了配置，再点保存会用旧值覆盖新值。发现配置"自己变回去"时，先刷新页面再改。

---

## 六、已知坑（血泪）

1. **不要删除 `game.sqlite-wal` / `-shm` / `-journal`**。存档是 SQLite WAL 模式，未落盘的进度（含后台改动）就在里面，删了会丢数据
2. **客户端从不向服务端抓资源**：补资源（如缺失的立绘）必须 `adb push` 到设备本地目录
3. **改了 Go 代码要重新 build + 重启服务端**；只改 `content.json`（含后台）不必重启
4. **模拟器必须支持 armeabi**，否则装上的客户端跑不了
5. 客户端原生库带补丁：`runtime/lib/librooneyj-rarenull.so`（空指针加固 + 觉醒形态立绘）。替换前先备份，回滚点是设备上的 `/data/local/tmp/librooneyj.so.orig`
6. 推送库/资源后 **务必 md5 三方对照**（设备目标 / 设备临时 / 本地产物），只看 "push 成功" 不算数
7. 本机有系统代理时，curl 访问 `127.0.0.1` 要加 `--noproxy '*'`，否则会拿到 502/000 误判服务没起来

---

## 七、本项目相对上游（`kakusansei-ma-ch`）做的增量

上游 `kakusansei-ma-ch-main/` 是一个**协议骨架**。它自己的 README 写着：

> 故事战斗和部分场景数据仍依赖真实客户端流程校正；**登录、教程、主菜单、探索、战斗与 CDN 尚未在模拟器或真机完成端到端确认**。

本项目在它之上做的工作分五类。

### 7.1 把链路真正跑通（上游标注「未确认」的部分）

| 工作                 | 说明                                                                              |
| ------------------ | ------------------------------------------------------------------------------- |
| 设备侧接入              | hosts 劫持两个硬编码域名 **＋** 全局 `http_proxy`——**两者缺一不可**，只写 hosts 客户端会一言不发、服务端一条请求都收不到 |
| 端口固定 `:50005`      | 客户端硬编码，改不了                                                                      |
| 资源必须推送             | 实测客户端**从不向服务端抓资源**（整场会话 `/contents/` 命中 **0**），500 MB 资源得靠 `adb push`           |
| `master_card` 锁    | 不锁则卡牌一览 / 回收站在 `_Card::getCountryId` 处 `SIGSEGV (fault addr 0x8)`               |
| `save_appdata` 只读锁 | 不锁则客户端每次启动把它清零，**游戏无声**                                                         |
| WAL 保全             | 重启服务端不删 `game.sqlite-wal`，否则未落盘进度（含后台改动）回档                                      |

### 7.2 玩法补齐与实机校正

| 模块         | 增量                                                                                  |
| ---------- | ----------------------------------------------------------------------------------- |
| 战斗         | 回合预算 3 → 8；**致命一击不截断**出手行；死亡判定移到回合末；伤害上报原始值                                         |
| 战斗调参       | 后台「我方卡片伤害 %」倍率（只缩放我方输出，用来调难度）                                                       |
| 守护者 / BOSS | 血量改读主数据表，与战斗内显示统一，消灭重复公式                                                            |
| 技能         | 模糊技能引擎（`runtime/web/fuzzy-skill-values.json`）、逐卡发动率（`skill-rates.json`）、原版技能判定顺序    |
| SUPER      | 驱动量                                                                                 |
| 界限突破       | 完整实装（数值由 `internal/master/limitover_stats_gen.go` 生成）                               |
| 妖精         | 觉醒妖精：等级**按 boss 分别计数**、HP = 表血 ×(1+(Lv−1)×成长%)×3、`<rare_fairy>` 演出；妖精战**未击杀也给钱与经验** |
| 探索         | 「攻击回合数越多」家族插值分母按原版改为 8                                                              |
| 剧情         | `story` 流程                                                                          |
| 卡牌         | 禁用卡表（`internal/master/banned_cards.go`）                                             |
| 活动系统       | `events[]`：自带卡池与秘境、逐妖精掉落表、收集品达标（可循环）与结算排名、活动倍卡（只加攻击）、`force_open` 回放历史活动 |
| 妖精结算       | 收集品按「这一刀实际打掉的血」计（超杀截断，尾刀最少）；觉醒妖精击杀也带 `<fairy>`，否则结算页读不到节点、什么都不显示         |

### 7.3 客户端缺陷修复（必须动 APK / `.so`）

| 缺陷            | 处理                                                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 原生库空指针 + 觉醒立绘 | 补丁库 `runtime/lib/librooneyj-rarenull.so`：21 处判空加固 ／ 4 处 `getCardImageId` → `getMasterCardId` 重定向，让 79 只觉醒 BOSS 显示觉醒形态立绘                          |
| 强化 7350 演出    | 重打包 APK，把 `layout_buildup_animation.xml` 的 `resultcard` 由 `c_buildup` 换成引擎自带的 `skip`（**保留 7400 结果页**）。`scripts/patch-client-apk.py` 自签重打包，无需 JDK |
| 缺贴图崩溃         | 服务端启动时检测客户端美术缺口并告警（`internal/game/clientart.go`）                                                                                                 |
| 界面叠字          | 坐标映射修复（详见开发期文档 `docs/叠字修复-坐标映射与最终方案.md`）                                                                                                         |

### 7.4 后台管理控制台（上游只有只读状态页）

上游的 `127.0.0.1:26031` 只提供状态页；本项目扩成可写的运营后台——卡池 / 区域秘境 / 商店 / 起始配置 / 成长规则 / 妖精与战斗 / 公告与主菜单 / 玩家管理 / 虚拟好友 / 主数据资源 / 日志与备份。

其中**玩家等级编辑**会按等级差**发放或回收能力值点**：升级逐级发点，降级则逐级收回，收回顺序沿用原版解除好友的规则（先扣未分配点，再从中上限较高的一侧扣）。

### 7.5 工程化

| 项     | 说明                                                                                                                             |
| ----- | ------------------------------------------------------------------------------------------------------------------------------ |
| 一键安装  | `scripts/install-all.ps1`（9 步）＋可双击的 `install-all.bat`：定位素材 → 解压资源 → 暂存服务端资源集 → 重打包 APK → 安装客户端 → 推送资源树 → 原生库补丁 → 启动服务端 → 启动客户端 |
| 只驱动雷电 | 以 `ldconsole` 白名单过滤设备（同机的 MuMu / 夜神 / 蓝叠一律忽略）；实例号**每次运行实时检测**，一个都没跑就自动拉起；**雷电找不找得到与盘符无关**：进程路径 → 卸载注册表项 → 逐卷搜索，全部集中在 `scripts/find-ldplayer.ps1` |
| 资源集生成 | `gen-resource.ps1`（从设备备份的 `files/save` 重建 `resource-set/`）                                                                     |
| 回归测试  | 仓库含 41 个测试文件、约 6300 行测试代码，覆盖战斗 / 技能 / 妖精 / 界限突破 / 后台等增量行为                                                                      |

**当前规模**：服务端 Go 代码约 14300 行（不含测试），测试约 6300 行。
