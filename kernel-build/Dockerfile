# Build environment for AOSP common-android15-6.6 kernel (x86_64) with KSU-Next
# + SUSFS + custom anti-emulator patches. Uses Ubuntu 24.04's native clang-18,
# which matches the AOSP prebuilt clang-r522817's version.
#
# To use:
#   docker build -t kbuild .
#   docker run --rm -v "$PWD":/work -w /work kbuild ./scripts/build-all.sh

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Build deps for the AOSP common-android kernel.
# Ubuntu 24.04 has clang-18 in its main repo. The Android Common Kernel for
# 6.6 builds cleanly with clang-18 (the official prebuilts/clang/host/linux-x86
# tag clang-r522817 IS clang-18.0.x).
#
# When CC=clang LLVM=1 LLVM_IAS=1, the kernel uses clang for compilation,
# integrated assembler, ld.lld for linking, llvm-objcopy etc. We still need
# binutils-x86-64-linux-gnu for a couple of helpers (objtool, etc).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git xz-utils unzip \
        build-essential bc bison flex \
        libssl-dev openssl libelf-dev \
        kmod cpio rsync \
        python3 python3-pip \
        zstd lz4 \
        ccache \
        clang lld llvm llvm-dev \
        gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu \
    && rm -rf /var/lib/apt/lists/* \
    && clang --version \
    && ld.lld --version

# Configure git for in-container operations (patches use git apply)
RUN git config --global user.email "kbuild@local" \
 && git config --global user.name "kbuild" \
 && git config --global init.defaultBranch main \
 && git config --global advice.detachedHead false

# Use ccache to speed up rebuild iterations
ENV CCACHE_DIR=/work/.ccache
ENV PATH="/usr/lib/ccache:${PATH}"

WORKDIR /work
