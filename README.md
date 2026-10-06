# mi14_net_booster v3.2 · 小米 14 移动网络优化（硬件能力对齐版）

KernelSU / Magisk 模块 · 适用小米 14（houji / pineapple / SM8650 + SDR753）

> 作者：[bingjiling92](https://github.com/bingjiling92)
> 许可：MIT（详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）
> 适配：小米 14 / Android 16 / 澎湃OS 3 / KernelSU

---

## ⚠️ 免责声明

个人原创作品，与 Qualcomm / Xiaomi / KernelSU / Magisk 官方无任何关联或授权。
本模块会修改网络接口参数（发送队列深度，可选 MTU / NAPI 批量），按“现状”提供，
无任何担保。刷入即视为接受。商标归各自所有者。

---

## 本版做了什么：先确认硬件能优化什么，再动手

v3.1 会写入 7 个 `persist.vendor.radio.*` 属性当作“基带/RIL 层优化”。在本机做过以下核查后，
判定它们**没有任何消费方**，v3.2 起默认不再写入：

| 核查范围 | 结果 |
|---|---|
| 全部 build.prop（system / vendor / odm / system_ext / product） | 7 个名字均无登记 |
| property_contexts（plat / vendor / odm） | 均无登记 |
| 129 个 RIL·QMI 厂商二进制（qcrilNrd、android.hardware.radio*.so、libqcril*、lib*ril* 等） | 字符串零命中 |
| 40 个框架 jar | 字符串零命中 |

> 说明：`prop` 名字不在 build.prop 里并不能单独证明它无效（例如真实存在的
> `persist.vendor.radio.multisim.config` 也不在 build.prop 里），所以判据取“二进制与框架里有没有消费方”。
> 即便如此，本模块也从未回读校验过这些属性的效果，因此 v3.2 采取保守策略：默认跳过，
> 需要的人可设 `RIL_PROPS=force`。

### 本机实测「可优化」清单

| 项目 | 硬件证据 | v3.2 行为 |
|---|---|---|
| 发送队列深度 `tx_queue_len` | 每接口 31 个 tx 队列，节点可写；实测 data0-2=500、**data3=1000（v3.1 漏掉）** | ✅ 默认开，动态覆盖**全部** `rmnet_data*`，改前存原值 |
| MTU | 节点可写；系统按 PDN 协商（实测 data1/2=**1432**、data3=1500）；开机聚合默认值可达 **9216** | ⚠️ 默认**不干预**。可选 `clamp`/`weak`，且**只降不升** |
| NAPI/GRO 批量 | `gro_flush_timeout` / `napi_defer_hard_irqs` 可写（实测 0/0），netfix 不碰 | ⚪ 新增，默认关 |
| 数据面守护 | `mDataConnectionState` 可解析、`svc data` 可用；实测 `InterfaceName` 字段已不再输出 | ✅ 三级回退识别承载 + 温和恢复 |
| 温度观测 | 102 个有效温区；分组命中 MODEM=4 RF=4 SOC=5 PEAK=15 GPU=8 BAT=1 PA=4 | ✅ 只观测 + 迟滞判定（不再写任何 RIL 属性） |
| RPS / XPS | 存在（实测 rps_cpus=7d/ff） | ❌ 归 `netfix_allinone` 管辖，本模块不碰 |
| TCP / DNS / iptables | — | ❌ 归 `netfix_allinone` 管辖 |

### v3.1 → v3.2 修复清单

1. 删除 7 个无消费方的基带属性写入（含一次性清理旧版留在属性存储里的值）。
2. 温控不再写 RIL 分片 —— 顺带去掉 v3.1 中 **SoC 与 Modem 共用 `LAST_SLICE` 变量**的覆盖漏洞：
   旧版 SoC 处于 HOT 时只在“状态变化那一刻”写 65536，之后 Modem 一翻转就把保护放宽回去。
3. 队列深度改为**动态发现**全部承载接口。v3.1 只遍历 data0/1/2，而本机实际承载是 **data3**
   （实测 v3.2 修好后 data3 由 1000 → 500）。
4. MTU 默认不干预：v3.1 一律压到 1400，既低于载波协商值 **1432**（白丢吞吐），
   也会被框架在每次建 PDN 时复位（日志里就有 `rmnet_data3: 1500->1500` 的证据）；
   而且它与 netfix 的 MSS clamp 功能重复。
5. 每轮只 `dumpsys` 一次并缓存复用（v3.1 每轮约 5MB 文本：2 次 dumpsys wifi + 4 次 telephony.registry）。
6. 数据守护日志顺序修正：不再先打印“状态=DOWN 连续第 1/3 次”再判断“数据开关关闭”。
7. 迟滞 5℃ → 8℃（实测 v3.1 在 8.4 小时内温区状态翻转 157 次，平均 3 分钟一次）。
8. SoC 采样新增 `PEAK(cpu-*-*-*)` 观测：本机实测峰值 95℃ 时，旧口径的 SOC 组只有 89℃。
9. 版本号、日志横幅统一为 v3.2；`module.prop` 里那个非法的 `updateJson=1` 已去掉。

---

## 安装 / 使用

- 安装后**重启**生效。
- 能力自检报告：`/data/adb/mi14_net_booster/capabilities.txt`
- 随时重跑自检（只读，不写入、不启动守护）：

```sh
su -c 'sh /data/adb/modules/mi14_net_booster/service.sh probe'
```

- 配置：`/data/adb/mi14_net_booster/config`（旧版配置会自动补齐新键，**原有调参保持不变**）
- 承载层原值存档：`/data/adb/mi14_net_booster/orig/`（卸载时按存档精确还原）

### 主要配置项

```ini
TXQ_ENABLE=1          # 发送队列深度总开关
TXQ_TARGET=500        # 目标值
MTU_MODE=off          # off=不碰(默认) / clamp=只夹 >MTU_CAP 的聚合默认值 / weak=弱信号再降到 MTU_NOMINAL
MTU_CAP=1500
MTU_NOMINAL=1400
SINR_WEAK=10
NAPI_ENABLE=0         # NAPI/GRO 批量, 吞吐取向, 默认关
GRO_FLUSH_TIMEOUT=20000
NAPI_DEFER=1
THERM_HYST=8
THERM_ACTION=log      # log=只记录(默认) / defer_recover=过热时暂停数据重连
RIL_PROPS=auto        # auto(默认,跳过未验证项) / force / off
```

---

## 与 netfix_allinone 的分权

双向让权，实测无重叠写入：

| 层次 | 归属 |
|---|---|
| 承载层队列深度 / MTU / NAPI-GRO / 数据面守护 / 温度观测 | **本模块** |
| TCP sysctl / DNS / QoS / RPS·XPS / iptables MSS clamp | **netfix_allinone** |

---

## 卸载

`uninstall.sh` 会：删掉旧版遗留的 7 个属性；按 `orig/` 存档把队列深度、MTU、
NAPI 节点逐一还原（从未动过的不碰）。TCP/RPS/XPS 本模块从未接管，不做改动。
