# 一加12 Pro（SM8650）+ Droidspaces v7 适配记录

本文档记录在一加12 Pro（SM8650，内核 `6.1.141`）上，基于
[cctv18/oppo_oplus_realme_sm8650](https://github.com/cctv18/oppo_oplus_realme_sm8650) 的
OKI 编译脚本，为 **Droidspaces v7** 补齐内核支持、并加入 **BBR** 的完整过程、实测数据与结论。

* 设备：一加12 Pro（`22825`），内核基线 `6.1.141-android14-11-o-gca13bffobf09`
* 容器运行时：[Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS)
* 成品：见 [Releases](../../releases)
* 根方案：KernelSU **LKM** 模式（`init_boot` 内置 `kernelsu.ko`），故内核**不内置 KSU**

---

## 1. 缺口与补法

Droidspaces v7 自检会逐项探测运行中内核的能力。本机原内核缺三项：

| 自检项 | 需要的配置 | 处理 |
|---|---|---|
| Macvlan | `CONFIG_MACVLAN=y` | ✅ 已开（必须 `=y`，写成 `=m` 不会被自动加载） |
| CPU limit | `CONFIG_CFS_BANDWIDTH=y` | ⚠️ 暂缓，见第 4 节 |
| Process limit | `CONFIG_CGROUP_PIDS=y` | ⚠️ 暂缓，见第 4 节 |

另加拥塞控制算法（用户需求）：

```
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BRUTAL=y
CONFIG_TCP_CONG_VEGAS=y
CONFIG_TCP_CONG_NV=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_DEFAULT_TCP_CONG="cubic"      # 默认仍是 cubic
```

> 内核对 cmdline 只有 `cgroup_disable=pressure`，没有 `cgroup_disable=cpu/pids`，
> 因此这两项一旦开启可以正常生效。

原始脚本（上游）的 Droidspaces 步骤只开了 namespace / `SYSVIPC` / `NTSYNC` / `EVP` 等，
**没有** MACVLAN / CFS_BANDWIDTH / CGROUP_PIDS，这就是三项报 ✗ 的原因。本仓库已补齐 MACVLAN 并把另外两项做成可选项（见第 5 节工作流参数）。

---

## 2. 结论先行：Step 1（MACVLAN + BBR）

在 9/24 可用基线之上**只加 MACVLAN 与拥塞控制算法**，得到 Step 1。

**为什么判定它安全**：把新内核的「导出符号 → CRC」表与基线内核逐符号比对：

```
基准(9/24) → Step 1：共同符号 15395，CRC 变化 0 个
  kmalloc_caches      0x0f15b38a -> 0x0f15b38a
  runqueues           0x5fc45fe1 -> 0x5fc45fe1
  register_netdevice  0xb4bdff70 -> 0xb4bdff70
  module_layout       0xea759d7f -> 0xea759d7f
```

对原厂 **1035 个预编译模块**的兼容性与基线完全一致。实机刷入后验证：

```bash
dmesg | grep -iE "disagrees about version|version magic"   # 0 行
cat /proc/sys/kernel/tainted                                # 4612，无 FORCED_MODULE 位
cat /proc/sys/net/ipv4/tcp_available_congestion_control      # reno bbr brutal cubic westwood htcp vegas nv
```

---

## 3. 验证方法：离线比对导出符号 CRC

不需要反复刷机，即可判断「改了内核配置/源码后，原厂模块会不会被拒收」。

**原理**：内核 `CONFIG_MODVERSIONS=y` 时，`__kcrctab` 保存了每个导出符号的 CRC；
预编译模块的 `__versions` 段记录了它期望的 `(符号名, CRC)`。逐个比对即可。

**步骤**

1. 用 [vmlinux-to-elf](https://github.com/marin-m/vmlinux-to-elf) 把裸 `Image` 还原成带符号的 ELF：

   ```bash
   pip install vmlinux-to-elf
   vmlinux-to-elf Image kernel.elf
   ```

2. 从 ELF 的 `__start___ksymtab` / `__start___kcrctab`（及其 `_gpl` 变体）配对读出 `符号 → CRC`。
   两者都按符号名排序，**按下标一一对应**；`__kcrctab` 条目为 4 字节（`CONFIG_MODULE_REL_CRCS=y`）。

3. 解析每个 `.ko` 的 `__versions` 段（每条 64 字节：`unsigned long crc` + `char name[56]`），
   与内核表比对。

4. **校验方法本身**：用基线内核跑一遍，应当只出现极个别已知的不匹配
   （本机为 1 个来自 `system_dlkm` 的 `bluetooth.ko`，且该模块实际未加载）。

> 注意 `symbol-not-found` 不一定是问题：厂商模块之间互相引用（如 `qcom_smem_get`）的符号，
> 不在内核导出表里，由其它模块提供，属正常。

---

## 4. 为什么 CFS_BANDWIDTH / CGROUP_PIDS 暂缓

同一套构建流程下的对照实验（每次都是 `no_ccache=true` 全新编译）：

| 变体 | 配置 | 导出符号 CRC 变化 | 实机结果 |
|---|---|---|---|
| 基准 | — | 0 | 正常 |
| C | + MACVLAN | 0 | 正常（仅作对照） |
| **Step 1** | + MACVLAN + BBR 系列 | **0** | **正常** ✅ |
| A | + MACVLAN + BBR + `CGROUP_PIDS` | 5648 | — |
| B | A + `CFS_BANDWIDTH` | 5648，且调度器符号值进一步变化 | **循环重启** ❌ |

**关键发现**

* `CGROUP_PIDS` 单独就让 **5648 个导出符号** CRC 变化。
* `CFS_BANDWIDTH` 在此之上**真正改变布局**：`runqueues`（`struct rq` 内嵌 `struct cfs_rq`）、
  `activate_task`、`__task_rq_lock`、`sched_setscheduler` 等值都变。
* 原厂第一阶段（`vendor_boot` ramdisk）模块里，`sched-walt.ko` 有 **74/355** 条引用受影响，
  `oplus_bsp_task_overload.ko` **直接引用全局 `runqueues`**，`oplus_bsp_schedinfo.ko` 26 条、
  `oplus_bsp_frame_boost.ko` 16 条、`msm_performance.ko` 7 条。
* 这些模块按旧偏移读写调度器结构 → 早期挂死 → **看门狗硬复位**。
  因为不是 panic，`pstore`/ramoops 不会留记录（`/sys/fs/pstore` 为空、
  `console-ramoops-0` 不存在、PMIC 只有 `HARD_RESET / PS_HOLD`），**现场无法事后取证**。

**绕过 CRC 校验是否可行？**
`kernel/module/version.c` 的 `check_version()` 恒真（`droidspaces_patch/fix_module_crc_check.patch`）
确实能让 984 个 CRC 不匹配的模块加载进来 —— 但那只解决「被拒收」，
解决不了「按错误偏移读写内存」。所以对 `CFS_BANDWIDTH` 无效。

**要全绿的路径**：把受影响的源内模块从同一棵树、同一份配置重编，并重打包进 `vendor_boot`
（必要时连同 `vendor_dlkm` / `system_dlkm`），与 `boot` 一起刷入。

---

## 5. 工作流参数（`fastbuild_6.1.141.yml`）

| 参数 | 说明 |
|---|---|
| `no_ccache` | 强制全新编译。ccache 缓存若来自不同配置的构建，配合 fakestat/faketime 的 `file_stat_matches` sloppiness 可能被错误复用，导致产物符号 CRC 错乱。**改动配置后排障必开** |
| `limit_opts` | `both` / `pids` / `none`：是否开启 `CFS_BANDWIDTH` + `CGROUP_PIDS` |
| `panic_on_hang` | 把软/硬锁死与 hung task 变成 panic，使 ramoops 落盘 → Android init 会复制到 `/data/debugging/last_kmsg.txt`，用于抓挂死日志 |
| `bbr_enable` | `false` / `true` / `default`（`default` 会把 BBR 设为系统默认） |
| `droidspaces_enable` | `false` / `standard` / `extend` |

---

## 6. 启用 BBR

内核已编入但默认仍是 `cubic`。`net.ipv4.tcp_congestion_control` 是**按 netns** 隔离的：

**Android 宿主（全局）**

```bash
su -c 'echo bbr > /proc/sys/net/ipv4/tcp_congestion_control'
su -c 'echo fq  > /proc/sys/net/core/default_qdisc'
```

开机自动：`/data/adb/service.d/99-bbr.sh`（0755），见 [`tools/99-bbr.sh`](../tools/99-bbr.sh)。

**Droidspaces 容器内**

容器有自己的 netns，需单独设置。systemd 容器可放 `/etc/sysctl.d/99-bbr.conf`：

```
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
```

> `tcp_congestion_control` 只控制**发送方向**。BBR 主要改善**上行**与**弱网/丢包**下的吞吐与稳定性，
> **不会提高带宽上限**，对普通下载速度无影响（下行由对端算法决定）。
> Brutal 需要应用侧为每条连接设置带宽参数才生效，**不建议设为默认**。

---

## 7. 已知限制

* **macvlan 在 Wi-Fi 上不可用**：802.11 AP 通常只接受单一 MAC 关联，容器换 MAC 发帧会被丢弃；
  部分驱动直接拒绝创建。Droidspaces 官方文档对这项的说明也是「a container straight on a wired LAN」。
  * 真正可用：USB 有线网卡。本机模块集已包含 `r8152`(RTL8152/8153)、`ax88179_178a`、
    `ax8817x`、`cdc_ether`、`cdc_ncm`、`aqc111`。
  * 不可用：SMSC `LAN75xx/95xx`（未开）、`RNDIS_HOST`（未开）。
  * **USB 无线网卡完全不支持** —— 内核未开 `CONFIG_CFG80211`。
  * 纯 Wi-Fi 场景建议继续用 `--net=nat` + 端口转发。
* 本内核**不内置 KernelSU**，配合 LKM 模式使用（`init_boot` 里的 `kernelsu.ko` 不受刷 `boot` 影响）。

---

## 8. 刷机与回退

刷机包为 AnyKernel3，仅替换 `boot` 分区内核、保留 ramdisk，
不动 `init_boot` / `vendor_boot` / `vendor_dlkm` / `system_dlkm`。

```bash
# 刷前记下槽位（一加12 是 A/B）
fastboot getvar current-slot
```

**回退**：刷 [2026-09-24 基线版](../../releases/tag/OPPO-OPlus-Realme-build-260924190108)，
或用同版本 `boot.img`：

```bash
fastboot flash boot_a boot-baseline.img
```

> 若开机失败，App 类刷机工具（KernelFlasher 等）无法使用，**只能靠 fastboot 刷 `.img`**。
> 注意 `fastboot flash boot`（不带后缀）刷的是当前活动槽，失败重启后槽位可能已切换，
> 建议始终用明确的后缀（`boot_a` / `boot_b`）。

---

## 9. 后续

- [ ] `CGROUP_PIDS` 单独上机验证（配 `panic_on_hang` 抓日志）
- [ ] `CFS_BANDWIDTH` + 重编 `sched-walt` / `oplus_bsp_*` / `msm_performance` 并重打包 `vendor_boot`
- [ ] 将上述重编模块与内核一起做成一次性刷机包
