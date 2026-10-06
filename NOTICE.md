# NOTICE

本仓库是一个**非商业的存档 / 互操作研究项目**，用于在本机运行已停止运营的《扩散性百万亚瑟王》国服客户端。

## 一、代码部分的许可

- 上游工程 `kakusansei-ma-ch-main/` 由社区开发，采用
  **PolyForm Noncommercial License 1.0.0**（全文见 `kakusansei-ma-ch-main/LICENSE`）——
  **禁止任何商业用途**。本仓库在其之上做的增量（`scripts/`、服务端新增代码、本文档）
  同样受该许可约束：可以非商业地使用、修改与分发，**不得商用**。
- 上游自带的 `kakusansei-ma-ch-main/NOTICE` 与本文件不冲突；该文件声明"不含游戏素材"，
  那是**上游**的情况，与本仓库不同（见下）。

## 二、游戏素材（重要差异）

**与上游不同，本仓库确实包含从原版客户端提取或派生的文件。**
它们**不属于**本项目，版权归原权利人所有，**随仓库提供不构成任何授权**：

| 路径 | 内容 |
| --- | --- |
| `runtime/lib/librooneyj-rarenull.so` | 原版客户端的原生库（在本地打上判空与立绘重定向补丁） |
| `base/140330/…/files/save/database/master_*` | 从客户端资源包提取的 6 个主数据表（card / boss / item / combo / scol / cardcategory） |
| `runtime/resource-set/master/master.json` | 服务端启动所需的主数据快照 |
| `runtime/layouts/` | 客户端界面布局样例（回归测试读取） |
| `runtime/web/*.json`、`internal/master/limitover_stats_gen.go` | 由社区资料整理的卡牌数值（界限突破满破表、技能发动率等） |

这些文件**仅为本地运行与存档研究所必需**而随仓库提供。

**原版 APK（`com.square_enix.million_cn-*.apk`）与资源包（`com.square_enix.million_cn-*.zip`）
未包含在本仓库中**，需使用者自行从原客户端备份获取——见 `README.md` 的安装章节。

## 三、免责声明

本项目与原出版商（SQUARE ENIX）**无任何关联**，亦未获其认可、赞助或授权。
游戏名称、角色名、美术、音频及其他游戏资产的权利均归其各自权利人所有。
请勿将本项目用于任何商业用途。
