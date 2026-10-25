# SHODAN Stat Editor — 已归档 / Archived

> **本项目已停止维护（archived）。请改用群友的魔改整合版：**
> **[→ 127MU/SHODAN-Stat-Editor](https://github.com/127MU/SHODAN-Stat-Editor)**
>
> This fork is archived and no longer maintained. Use
> **[127MU/SHODAN-Stat-Editor](https://github.com/127MU/SHODAN-Stat-Editor)** instead.

本仓库是 [SHODAN-HORAI/SHODAN-Stat-Editor](https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor) 的
fork，做过一段时间的魔改与中文整合（见下文「这条线做过的主要改动」）。它的工作已经并入
[127MU/SHODAN-Stat-Editor](https://github.com/127MU/SHODAN-Stat-Editor)，因此这里停止更新。

---

## 为什么转向那边

上游在 4.x 做了一次大重构，群友 **127MU** 在此基础上重新整合，并打包成**单文件桌面版**——双击即用，
不需要自己编 LuaJIT、也不需要摆 DLL：

- **4.1.x 面板**：军械库、状态效果、锁定与制导、喷流、粘附等新数据分区
- **内置 MCP 调试接口**：回环 HTTP，默认关闭，需要时在设置里手动开
- **检查更新**：启动时自己查正式发行版并弹窗提示，不自动覆盖你的文件
- **中文界面 + 中文说明书**；安装/恢复把「启动前别人做的改动」当基线，不再被别的工具挡住
- 五张游戏原始表随包携带，**恢复游戏原始文件**一定回到真实原版

## 现役版本去哪里下

| | |
|---|---|
| 仓库 | https://github.com/127MU/SHODAN-Stat-Editor |
| 发行版 | https://github.com/127MU/SHODAN-Stat-Editor/releases |
| 形态 | 单个 exe（Windows x64），无需 mod loader |

## 这里还留着什么（仅作存档）

本仓库的 [Releases](../../releases) 里是 3.2.x 时期的魔改整合包（`v3.2.0-armory` … `v3.2.32-armory`），
二进制仍然可以下载，但**不再更新、不再修 bug**；4.x 的问题请到 127MU 的仓库反馈。

### 这条线做过的主要改动（存档用）

| 改动 | 说明 |
|---|---|
| 近炸引信 | 面板把「爆炸阈值角」上限从 180 放到 **360**，武器页补上爆炸角行；实测配方：接近度 > 0 且角度 **360°** 才会在飞行中起爆，半径建议大于「初速 / 游戏帧率」（CB-9 爆燃弩：6 m + 360° 生效，3 m + 80° 无效） |
| 记录页消失 bug | 保存过的射弹/爆炸记录会被 `resolve()` 当成武器重新解析、行被清空而永久掉出列表；修法 `if weapon.record then return end` + `MOD.records.rebuild()` |
| 汉化大小写 | 状态与战备名字首字母大写导致查表落空；`translate()` 增加 lower/upper 回退 |
| 随包原版数据 | `offline/originals/` + build 指纹，「恢复游戏原始文件」不再依赖「这文件是不是我们写的」 |
| 借盐哈希校正 | 单块表没有可扰动的浮点时借用邻近浮点数（幅度 < 0.1%）满足校验，安装不再中止 |
| MCP `--game` | 参数一直被丢弃，所有命令都打到真实游戏目录；已修 |
| 数据标注 | 质量 1e6 kg（射弹 #67）与重力 −2.5（#226）越过 100000 的可信度闸门而读不出、写不进；已放宽为 f32 满量程 + signed |

## 许可

[GNU General Public License v3.0](LICENSE)（沿上游）。仓库归档后为只读。

## 致谢

上游 SHODAN Stat Editor、[127MU 的整合版](https://github.com/127MU/SHODAN-Stat-Editor)、HD2Runtime、
[Filediver](https://github.com/xypwn/filediver) 与 shalzuth 的数据转储、[Helldivers 2 wiki](https://helldivers.wiki.gg/)、
Bingus Shared Loader、[LuaJIT](https://luajit.org)、[libsodium](https://libsodium.org)。

SHODAN Stat Editor 与 Arrowhead Game Studios、Sony Interactive Entertainment 无关联，也未获其背书。
