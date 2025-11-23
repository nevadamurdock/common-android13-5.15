#!/bin/bash
SECONDS=0
set -e

# Set kernel environment
android_version="$1"
kernel_version="$2"
sub_level="$3"
os_patch_level="$4"

# Set CONFIG Environment Variable
CONFIG="$android_version-$kernel_version-$sub_level"
export CONFIG="$CONFIG"

# Set Path Environment Variables
ROOT="$(pwd)"
KERNEL_ROOT="$ROOT/$CONFIG"
KERNEL_PATCHES="$ROOT/kernel_patches"
ANYKERNEL3="$ROOT/AnyKernel3"
DEFCONFIG="$KERNEL_ROOT/common/arch/arm64/configs/gki_defconfig"
KERNEL_RESULT="$KERNEL_ROOT/bazel-bin/common/kernel_aarch64"

export ROOT="$ROOT"
export KERNEL_ROOT="$KERNEL_ROOT"
export KERNEL_PATCHES="$KERNEL_PATCHES"
export ANYKERNEL3="$ANYKERNEL3"

# Setup Build Environment
AOSP_MIRROR=https://android.googlesource.com
BRANCH=main-kernel-2025
git clone $AOSP_MIRROR/kernel/prebuilts/build-tools -b $BRANCH --depth 1 kernel-build-tools &
git clone $AOSP_MIRROR/platform/system/tools/mkbootimg -b $BRANCH --depth 1 mkbootimg &
wait

export AVBTOOL="$ROOT/kernel-build-tools/linux-x86/bin/avbtool"
export MKBOOTIMG="$ROOT/mkbootimg/mkbootimg.py"
export UNPACK_BOOTIMG="$ROOT/mkbootimg/unpack_bootimg.py"
export BOOT_SIGN_KEY_PATH="$ROOT/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"
export PATH="$ROOT/kernel-build-tools/linux-x86/bin:$PATH"

mkdir -p ./git-repo
curl https://storage.googleapis.com/git-repo-downloads/repo > ./git-repo/repo
chmod a+rx ./git-repo/repo
export REPO="$ROOT/./git-repo/repo"

# Clone AnyKernel3 and Other Dependencies
git clone https://github.com/kylieeXD/AK3-GKI "$ANYKERNEL3"
git clone https://github.com/kylieeXD/kernel_patches.git "$KERNEL_PATCHES"

# Initialize and Sync Kernel Source
mkdir -p "$KERNEL_ROOT"
cd "$KERNEL_ROOT"

FORMATTED_BRANCH="$android_version-$kernel_version-$os_patch_level"
$REPO init --depth=1 --u https://android.googlesource.com/kernel/manifest -b common-${FORMATTED_BRANCH} --repo-rev=v2.16

REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common ${FORMATTED_BRANCH})
DEFAULT_MANIFEST_PATH=.repo/manifests/default.xml

if grep -q deprecated <<< $REMOTE_BRANCH; then sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" $DEFAULT_MANIFEST_PATH; fi
$REPO --trace sync -c -j$(nproc --all) --no-tags --fail-fast

# Extract Actual Sublevel
cd "$KERNEL_ROOT/common"
if [ -f "Makefile" ]; then
	ACTUAL_SUBLEVEL=$(grep '^SUBLEVEL = ' Makefile | awk '{print $3}')

	if [ -n "$ACTUAL_SUBLEVEL" ]; then
		export ACTUAL_SUBLEVEL="$ACTUAL_SUBLEVEL"
		echo "Extracted ACTUAL_SUBLEVEL=$ACTUAL_SUBLEVEL; no directory changes performed."
	else
		echo "Warning: SUBLEVEL not found in Makefile; continuing with sub_level."
	fi
fi

# Add KernelSU and SuSFS
curl -LSs "https://raw.githubusercontent.com/kylieeXD/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
cp "$KERNEL_PATCHES/next/kernelsu_and_susfs.patch" .
cp "$KERNEL_PATCHES/next/fix-task_mmu.c" .
patch -p1 < kernelsu_and_susfs.patch || patch -p1 < fix-task_mmu.c

echo "CONFIG_KSU=y" >> "$DEFCONFIG"
echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$DEFCONFIG"
echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG"
echo "CONFIG_KPM=y" >> "$DEFCONFIG"

# Add BBG
cd "$KERNEL_ROOT"
wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
echo "CONFIG_BBG=y" >> common/arch/arm64/configs/gki_defconfig
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/lockdown/lockdown,baseband_guard/ } }' common/security/Kconfig

# Fix WiFi and Bluetooth on Samsung 6.6 GKI devices
SYMBOL_LIST=$KERNEL_ROOT/common/android/abi_gki_aarch64_galaxy
echo "kdp_set_cred_non_rcu" >> $SYMBOL_LIST
echo "kdp_usecount_dec_and_test" >> $SYMBOL_LIST
echo "kdp_usecount_inc" >> $SYMBOL_LIST

cd "$KERNEL_ROOT/common"
PATCH="$KERNEL_PATCHES/samsung/min_kdp/add-min_kdp-symbols.patch"
if patch -p1 --dry-run < "$PATCH"; then patch -p1 --no-backup-if-mismatch < $PATCH; fi

cd drivers
cp "$KERNEL_PATCHES/samsung/min_kdp/min_kdp.c" min_kdp.c
echo "obj-y += min_kdp.o" >> Makefile

# Set Kernel Configuration Variables
cd "$KERNEL_ROOT"
export DEFCONFIG="$DEFCONFIG"
sed -i 's/check_defconfig//' ./common/build.config.gki

# Configure Mountify Support
echo "CONFIG_TMPFS_XATTR=y" >> "$DEFCONFIG"
echo "CONFIG_TMPFS_POSIX_ACL=y" >> "$DEFCONFIG"

# Configure Networking
echo "CONFIG_IP_NF_TARGET_TTL=y" >> "$DEFCONFIG"
echo "CONFIG_IP6_NF_TARGET_HL=y" >> "$DEFCONFIG"
echo "CONFIG_IP6_NF_MATCH_HL=y" >> "$DEFCONFIG"

# Configure TCP Congestion Control
echo "CONFIG_TCP_CONG_ADVANCED=y" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
echo "CONFIG_NET_SCH_FQ=y" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_BIC=n" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_WESTWOOD=n" >> "$DEFCONFIG"
echo "CONFIG_TCP_CONG_HTCP=n" >> "$DEFCONFIG"

# Configure IPSet Support
echo "CONFIG_IP_SET=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_MAX=65534" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_BITMAP_IP=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_BITMAP_IPMAC=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_BITMAP_PORT=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IP=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IPMARK=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IPPORT=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IPPORTIP=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IPPORTNET=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_IPMAC=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_MAC=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_NETPORTNET=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_NET=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_NETNET=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_NETPORT=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_HASH_NETIFACE=y" >> "$DEFCONFIG"
echo "CONFIG_IP_SET_LIST_SET=y" >> "$DEFCONFIG"

# Change Kernel Name
sed -i '$s|.*|echo "${KERNELVERSION}${config_localversion}"|' common/scripts/setlocalversion
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-kylieeXD"/' "$DEFCONFIG"
echo "CONFIG_LOCALVERSION_AUTO=n" >> "$DEFCONFIG"

UTS_VERSION="#1 SMP PREEMPT $(date -u +%a\ %b\ %d\ %H:%M:%S\ UTC\ %Y)"
perl -pi -e "s|UTS_VERSION=\".*\"|UTS_VERSION=\"${UTS_VERSION}\"|" ./common/scripts/mkcompile_h

sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl
rm -rf ./common/android/abi_gki_protected_exports_*
perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' ./common/BUILD.bazel

# Set file name
FILE_NAME="kernel-$kernel_version-$ACTUAL_SUBLEVEL-$android_version-$os_patch_level"

# Build
set -e && set -x
tools/bazel build --config=fast --lto=thin //common:kernel_aarch64_dist || exit 1

# Add KPM
cd "$KERNEL_RESULT"
wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.2/patch_linux || exit 1
chmod +x patch_linux || exit 1
./patch_linux || exit 1

rm -rf "$KERNEL_RESULT/Image"
mv "$KERNEL_RESULT/oImage" "$KERNEL_RESULT/Image"

# Prepare AnyKernel3
cp "$KERNEL_RESULT/Image" "$ANYKERNEL3/kernels/Image" || exit 1
cd "$ANYKERNEL3" && zip -r9 "$FILE_NAME" *
cp "$ANYKERNEL3/$FILE_NAME" "$6"

# Upload kernel
RESPONSE=$(curl -s -F "file=@$FILE_NAME" "https://store1.gofile.io/contents/uploadfile" \
|| curl -s -F "file=@$FILE_NAME" "https://store2.gofile.io/contents/uploadfile")
DOWNLOAD_LINK=$(echo "$RESPONSE" | grep -oP '"downloadPage":"\K[^"]+')
echo -e "\nDownload link: $DOWNLOAD_LINK\n"

# Done bang
echo -e "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s) !\n"
cd "$ROOT"
