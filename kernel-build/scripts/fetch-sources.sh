#!/bin/bash
# Clone the three source trees we need: AOSP common kernel, KSU-Next, SUSFS.
# Pinned to specific tags/commits so the build is reproducible.
#
# Output layout:
#   sources/
#     kernel/      -- AOSP common-android15-6.6 at the 6.6.66 tag
#     kernelsu/    -- KernelSU-Next
#     susfs/       -- susfs4ksu patches matching the kernel branch
#
# Re-running this script is safe: it skips trees that are already cloned.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/sources"
mkdir -p "${SRC}"

# -- AOSP common kernel --------------------------------------------------------
# android15-6.6 is the branch matching the user's 6.6.66-android15 kernel.
# The kernel/common project is mirrored on github by groups like aospk; the
# canonical home is android.googlesource.com which is slow to clone.
KERNEL_URL="https://android.googlesource.com/kernel/common"
# Pin to the Feb 2025 release tag that matches the Wild kernel's vintage
# (6.6.66) -- branch HEAD is far ahead (6.6.138) and Android 16's userspace
# apex modules SIGABRT against the newer kernel.
KERNEL_TAG="android15-6.6-2025-02_r19"
KERNEL_DIR="${SRC}/kernel"
if [[ ! -d "${KERNEL_DIR}/.git" ]]; then
    echo "==> Cloning AOSP common kernel @ ${KERNEL_TAG} -- this is ~3 GB"
    git clone --depth 1 --branch "${KERNEL_TAG}" \
        "${KERNEL_URL}" "${KERNEL_DIR}"
else
    # Verify the tag matches; if not, the user changed it -- wipe and re-clone
    cur=$(cd "${KERNEL_DIR}" && git describe --tags --exact-match HEAD 2>/dev/null || echo NONE)
    if [[ "${cur}" != "${KERNEL_TAG}" ]]; then
        echo "==> kernel/ present at ${cur}, need ${KERNEL_TAG}; rewiping"
        rm -rf "${KERNEL_DIR}"
        git clone --depth 1 --branch "${KERNEL_TAG}" \
            "${KERNEL_URL}" "${KERNEL_DIR}"
    else
        echo "==> kernel/ already at ${KERNEL_TAG}"
    fi
fi

# -- KernelSU-Next -------------------------------------------------------------
# Pin to the exact commit Wild Kernels uses. The dev-branch HEAD has aggressive
# syscall hooks (syscall_event_bridge, tp_marker, x86_64/syscall_hook) that
# interact badly with Android 16's mediaswcodec apex -- it SIGABRTs at startup.
# Wild's integration patch DISABLES those hooks, keeping only the setuid hook.
KSU_URL="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_COMMIT="5a4a71874caaad06aa126f761c93391de1d32361"
KSU_DIR="${SRC}/kernelsu"
if [[ ! -d "${KSU_DIR}/.git" ]]; then
    echo "==> Cloning KernelSU-Next (full history, ~30 MB)"
    git clone "${KSU_URL}" "${KSU_DIR}"
fi
(
    cd "${KSU_DIR}"
    cur=$(git rev-parse HEAD 2>/dev/null || echo NONE)
    if [[ "${cur}" != "${KSU_COMMIT}" ]]; then
        echo "==> kernelsu/ at ${cur:0:12}, need ${KSU_COMMIT:0:12}"
        if [[ -f .git/shallow ]]; then
            echo "    (unshallowing to reach historical commit)"
            git fetch --unshallow || git fetch --depth=10000
        else
            git fetch
        fi
        git checkout "${KSU_COMMIT}"
    else
        echo "==> kernelsu/ at ${KSU_COMMIT:0:12}"
    fi
)

# -- SUSFS for KernelSU --------------------------------------------------------
# Pin to the exact SUSFS commit Wild uses for android15-6.6, on the
# gki-android15-6.6 branch.
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android15-6.6"
SUSFS_COMMIT="2df41de789026a6422521606402576507c687435"
SUSFS_DIR="${SRC}/susfs"
if [[ ! -d "${SUSFS_DIR}/.git" ]]; then
    echo "==> Cloning SUSFS ${SUSFS_BRANCH} (full history)"
    git clone --branch "${SUSFS_BRANCH}" "${SUSFS_URL}" "${SUSFS_DIR}"
fi
(
    cd "${SUSFS_DIR}"
    cur=$(git rev-parse HEAD 2>/dev/null || echo NONE)
    if [[ "${cur}" != "${SUSFS_COMMIT}" ]]; then
        echo "==> susfs/ at ${cur:0:12}, need ${SUSFS_COMMIT:0:12}"
        if [[ -f .git/shallow ]]; then
            git fetch --unshallow || git fetch --depth=10000
        else
            git fetch
        fi
        git checkout "${SUSFS_COMMIT}"
    else
        echo "==> susfs/ at ${SUSFS_COMMIT:0:12}"
    fi
)

# -- Wild Kernels patches repo (we just need their KSU<->SUSFS integration
#    patch which disables the broken syscall hooks) ----------------------------
WILD_URL="https://github.com/WildKernels/kernel_patches.git"
WILD_DIR="${SRC}/wild-patches"
if [[ ! -d "${WILD_DIR}/.git" ]]; then
    echo "==> Cloning Wild patches"
    git clone --depth 1 "${WILD_URL}" "${WILD_DIR}"
else
    echo "==> wild-patches/ already present"
fi

echo
echo "==> All sources fetched into ${SRC}"
du -sh "${SRC}"/* 2>/dev/null || true
