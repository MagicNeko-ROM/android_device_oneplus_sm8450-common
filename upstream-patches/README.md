# upstream-patches —— 需要打在上游仓库上的本地改动

这两个仓库**刻意不做 fork**（与上游的净差异只有百来行，不值得养一个仓库）。
但改动本身是必需的 —— 尤其是 display 那一份，**没有它指纹就不工作**。
所以改成 patch 存在这里：重建源码树后打上即可，既不丢改动，也不扩大与上游的差异。

## 0001-display-sm8450-udfps-hbm-and-sdmext.patch

**目标仓库**：`hardware/qcom-caf/sm8450/display`
**上游基线**：`LineageOS/android_hardware_qcom_display` 的 `lineage-23.2-caf-sm8450`
（本 patch 的 diff 基线是提交 `222878b`）
**净差异**：14 个文件，+153 / -14

内容分三块：

1. **打通 UDFPS 的 hbm_enable 链路**（`OPLUS_FINGERPRINT_MASK`）
   设备树里 `soong_config_set_bool(qtidisplay,oplus_udfps,true)` 一直是设的，
   但 `Android.bp` 没有对应的 `soong_config_variables`，那段代码被**静默编译掉**。
   补上变量与 cflags，并让 `HWDeviceDRM::SetupAtomic()` 扫描图层名、按需置
   `OPLUS_OFP_PROPERTY_*` 位，经 DRM 连接器属性 `hbm_enable` 下发给内核。
   没有这一步：`pressed_icon_status` 永不进 `ON_WR_PTR`，`waitUiready` 超时，
   指纹录入永远是 `errno=15001`（= 10108 FP_ERR_FINGERUP_TOO_FAST）。

2. **层名匹配只认关键字**，不照抄 sm8550 那套字面量。
   sm8550 的 `"SurfaceView[UdfpsControllerOverlay](BLAST)"` 是 Android 14 时代的
   名字；本树 A16 实测 buffer 名是
   `VRI[SurfaceView[UdfpsControllerOverlay]]#N(BLAST Consumer)N`，照抄根本匹配不上。

3. **与跨代预编译 blob 共存的三个要害**
   - `display_base`：没有 color manager 时 `SetColorTransform` 返回 `kErrorNone`。
     本机 `libsnapdragoncolor-manager.so` 与源码不同代、加载即 SIGSEGV，所以
     `color_manager.cpp` 刻意跳过 STC。若此处如实返回 `kErrorNotSupported`，
     composer 会把 `color_tranform_failed_` 永久置位，
     `PreValidateDisplay()` 每帧 `MarkLayersForClientComposition()` ——
     **整个显示栈被打回 100% GPU 合成**。
   - `comp_manager`：`IsDisplayHWAvailable()` 不去戳 blob 虚表，直接 `return true`。
     该虚槽在 `resource_interface.h` 是接口最后一位，跨代 blob 的虚表比我们短一格，
     调用即 `pc=0`。它唯一用途是 `enable_null_display_`，而本机永远有面板。
   - `hw_device_drm`：探针收窄为「掩码跳变时才打」，避免每帧刷屏。

**应用方式**（在源码树根目录）：
```
cd hardware/qcom-caf/sm8450/display
git apply -p1 <path-to>/0001-display-sm8450-udfps-hbm-and-sdmext.patch
```

**验证判据**（刷入后，一条都不靠猜）：
```
adb shell dumpsys SurfaceFlinger | grep usesDeviceComposition    # 应为 true
adb logcat -d | grep "ofp-mask"                                  # 按压时应 0x1 <-> 0x3 跳变
adb shell dmesg | grep HBM_ENABLE                                # 应出现 HBM_ENABLE:3
adb shell 'cat /sys/kernel/oplus_display/fp_state'
```

## 0002-vendor-lineage-depmod-and-sched-param.patch

**目标仓库**：`vendor/lineage`
**上游基线**：`crdroidandroid/android_vendor_lineage` 的 `16.0`
**净差异**：2 个文件，+33 / -3

- `build/tasks/kernel.mk`：depmod 的 unknown symbol 与 `BOOT_KERNEL_MODULES`
  缺失检查改为受 `BOARD_KERNEL_MODULES_LOAD_ALLOW_MISSING` 控制。
  设备树清单里用的是老模块名、而 gki-modules 已改名，老名字不存在会让
  depmod 找不到符号、依赖链失败。
- `tools/clean_headers.sh`：处理 sched_param 头冲突。

**应用方式**（在源码树根目录）：
```
cd vendor/lineage
git apply -p1 <path-to>/0002-vendor-lineage-depmod-and-sched-param.patch
```

## 0003-kernel-sm8450-ksm-fragment.patch

**目标仓库**：`kernel/oneplus/sm8450`
**上游基线**：`lineage-ovaltine-dev/android_kernel_oneplus_sm8450`（diff 基线 `cfcbf0579b5f`）
**净差异**：1 个文件（新增），+10

- 新增 `arch/arm64/configs/vendor/oplus/ksm.config`，内容就只有一行 `CONFIG_KSM=y`。
  KSM 在 `gki_defconfig` 与各 vendor fragment 里都没出现，`make gki_defconfig`
  会让它落到内核默认值 `n`（产物 `.config` 里是 `# CONFIG_KSM is not set`），
  于是 `/sys/kernel/mm/ksm` 整个目录不存在、运行时根本无法启用。
  设备树的 `TARGET_KERNEL_CONFIG` 已把它追加到列表末尾覆盖默认值。

**应用方式**（在源码树根目录）：
```
cd kernel/oneplus/sm8450
git apply -p1 <path-to>/0003-kernel-sm8450-ksm-fragment.patch
```

**配套改动**（都在设备树里，随本仓库提交，不需要 patch）：

- `BoardConfigCommon.mk`：`TARGET_KERNEL_CONFIG` 追加 `vendor/oplus/ksm.config`
- `init/init.kernel.post_boot-cape.sh`：新增 `configure_memory_extension()`，
  按物理内存自适应启用：
  - zram = `min(RAM x 50%, 6GB)`，下限 1GB，算法 lz4（16G 机型 → 6144MB）
  - KSM：内存 ≤6GB 扫得勤（200 页 / 20ms），>6GB 温和（100 页 / 50ms），并开启零页合并

  本机 `chip_family=0x82` 走 cape 分支，而原厂 cape 脚本里**没有 zram 段**
  （只有 taro 版有 `configure_zram_parameters`），这正是 zram 一直没启用的原因。
- `sepolicy/ksm.te` + `sepolicy/genfs_contexts`：给 `/sys/kernel/mm/ksm`
  打专属 `sysfs_ksm` 标签，并授权 `vendor_qti_init_shell` 写入。
  默认标签是通用 `sysfs`，而该域对通用 sysfs 只有读权限 —— 不加这条，
  脚本写 `pages_to_scan` / `use_zero_pages` / `run` 会被 SELinux 静默拦下。

**验证判据**（刷入后）：
```
adb shell ls -Z /sys/kernel/mm/ksm/run   # 应为 u:object_r:sysfs_ksm:s0
adb shell cat /sys/kernel/mm/ksm/run     # 应为 1
adb shell cat /proc/swaps                # 应挂着 /dev/block/zram0（本机 6144MB）
```

> **刷机注意**：改 SELinux policy 后**必须连 `odm` 一起刷** —— 运行时加载的是
> `/odm/etc/selinux/precompiled_sepolicy`，它不校验 vendor 的哈希，
> 只刷 vendor 不会生效（2026-10-11 实测踩过这个坑）。

## 维护约定

改这两个仓库时，**改完就把 patch 重新导一遍**（覆盖本目录下的同名文件），
否则这里会慢慢和实际树脱节：

```
git -C hardware/qcom-caf/sm8450/display diff <上游基线>..HEAD -- . ':(exclude)*.before-*' \
  > device/oneplus/sm8450-common/upstream-patches/0001-display-sm8450-udfps-hbm-and-sdmext.patch
git -C vendor/lineage diff <上游基线>..HEAD -- . ':(exclude)*.before-*' \
  > device/oneplus/sm8450-common/upstream-patches/0002-vendor-lineage-depmod-and-sched-param.patch
```

> 注：display 仓库里曾有误提交的备份文件
> `sdm/libs/core/comp_manager.cpp.before-t17-hwavail`（954 行），已于 2026-10-10 清理。
> 导出命令仍保留 `:(exclude)*.before-*`，以免将来再被顺手提交的东西混进 patch。

---

## 一键应用（幂等）

重建源码树、或 `repo sync` 之后，跑一次即可：

```
bash device/oneplus/sm8450-common/upstream-patches/apply.sh
```

- 会自己往上找到源码树根（认 `build/envsetup.sh`）；
- **幂等**：已应用就跳过，不会重复打；
- 上游代码若变了导致两边都对不上，它会明确报出来并让你人工核对，不会硬打；
- 只看不动文件：`apply.sh --check`。

这台机器的实测状态：

```
$ bash device/oneplus/sm8450-common/upstream-patches/apply.sh --check
```
```
