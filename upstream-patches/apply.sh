#!/bin/bash
# 汐 2026-10-10
# 把 upstream-patches/ 里的改动应用到源码树上（幂等：已应用则跳过）
#
# 用法（在源码树根目录，或任意位置，脚本自己找根）：
#     bash device/oneplus/sm8450-common/upstream-patches/apply.sh
#     bash device/oneplus/sm8450-common/upstream-patches/apply.sh --check   # 只看会不会成，不动文件
#
# 为什么要这样：这几个仓库刻意不做 fork（与上游净差异只有百来行），
# 但改动本身是必需的 —— display 那一份没有的话指纹就不工作。
# 用 patch 存在设备树里，repo sync 后跑一次本脚本即可复原，不扩大与上游的差异。

set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ---- 找源码树根：往上找到带 build/envsetup.sh 的那层 ----
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SELF"
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/build/envsetup.sh" ]; do
  ROOT="$(dirname "$ROOT")"
done
if [ ! -f "$ROOT/build/envsetup.sh" ]; then
  echo "!! 找不到源码树根（往上没有 build/envsetup.sh）"
  exit 1
fi
echo "源码树根: $ROOT"
[ "$CHECK_ONLY" = "1" ] && echo "模式: --check（只看，不改文件）"
echo

ok(){   printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){   printf '  \033[31m✗\033[0m %s\n' "$*"; }
skip(){ printf '  \033[36m=\033[0m %s\n' "$*"; }

failed=0

apply_one() {
  local repo_rel="$1" patch_name="$2" desc="$3"
  local repo="$ROOT/$repo_rel"
  local patch="$SELF/$patch_name"

  echo "== $repo_rel"
  echo "   $desc"

  if [ ! -d "$repo/.git" ]; then
    no "仓库不存在（源码树里没有这个项目？）"
    failed=1; echo; return
  fi
  if [ ! -f "$patch" ]; then
    no "找不到 patch：$patch_name"
    failed=1; echo; return
  fi

  cd "$repo" || { no "进不去 $repo"; failed=1; echo; return; }

  if git apply --check -p1 "$patch" >/dev/null 2>&1; then
    if [ "$CHECK_ONLY" = "1" ]; then
      ok "可以应用（--check 模式，未落盘）"
    else
      git apply -p1 "$patch" && ok "已应用" || { no "应用失败"; failed=1; }
    fi
  elif git apply --check --reverse -p1 "$patch" >/dev/null 2>&1; then
    skip "已是应用状态，跳过"
  else
    no "既不能应用、也不是已应用 —— 上游代码可能变了，需要人工核对"
    echo "      （可先看：git -C $repo_rel apply --check -v -p1 $patch）"
    failed=1
  fi
  echo
}

apply_one "hardware/qcom-caf/sm8450/display" \
          "0001-display-sm8450-udfps-hbm-and-sdmext.patch" \
          "显示 HAL：UDFPS hbm_enable 链路 + 与跨代 libsdmextension 共存（指纹必需）"

apply_one "vendor/lineage" \
          "0002-vendor-lineage-depmod-and-sched-param.patch" \
          "构建系统：depmod unknown symbol 可按需容忍 + sched_param 头冲突"

# 2026-10-11：KSM 按主人指令关闭 —— 本补丁停用（patch 文件与 ksm.config 均保留；
#            恢复时把下面三行取消注释，并把 BoardConfigCommon.mk 的引用加回）。
# apply_one "kernel/oneplus/sm8450" \
#           "0003-kernel-sm8450-ksm-fragment.patch" \
#           "内核配置：打开 CONFIG_KSM（内存同页合并，配合设备树的自适应 zram）"

if [ "$failed" = "0" ]; then
  printf '\033[32m全部就绪\033[0m\n'
else
  printf '\033[31m有项目没处理成功，见上面 ✗\033[0m\n'
  exit 1
fi
