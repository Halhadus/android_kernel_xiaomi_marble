#!/usr/bin/bash

yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
gre='\e[0;32m'

cd ${0%/*}

DEFCONFIG=marble_defconfig
IMAGE=./out/arch/arm64/boot/Image
OUTPUT_DIR=./../Melt_marble_release
GKI_BUILD_TOOLS=/home/pzqqt/build_toolchain/android-kernel/build

# 如果将 `KMI_STRICT_MODE` 设置为 true, 则:
# 1. 使内核 Image 仅导出 KMI 接口 (非 KMI 接口将不会被导出, 这意味着依赖非 KMI 接口的内核模块将加载失败).
# 2. 如果编译生成的内核模块调用了非 KMI 接口, 则打印警告.
# 3. 编译完成后在 /tmp 生成 abi.xml.
KMI_STRICT_MODE=true
# KMI_STRICT_MODE=false

USE_SLIM_LLVM=true
# USE_SLIM_LLVM=false

mkdir -p $OUTPUT_DIR
mkdir -p ${OUTPUT_DIR}/vendor_boot_modules
mkdir -p ${OUTPUT_DIR}/vendor_dlkm_modules
mkdir -p ${OUTPUT_DIR}/alt_kernel_modules

########## Parsing parameters ##########

use_defconfig=$DEFCONFIG
no_mkclean=false
no_ccache=false
no_ldo3=false
with_ksu=false
make_target=

while [ $# != 0 ]; do
	case $1 in
		"--noclean") no_mkclean=true;;
		"--noccache") no_ccache=true;;
		"--no-kmi-strict") KMI_STRICT_MODE=false;;
		"--no-ldo3") no_ldo3=true;;
		"--ksu") with_ksu=true;;
		"--defconfig") {
			shift
			use_defconfig=$1
		};;
		"--") {
			shift
			make_target=$*
			break
		};;
		*) {
			cat <<EOF
Usage: $0 <operate>
operate:
    --noclean               : build without run "make mrproper"
    --noccache              : build without ccache
    --no-kmi-strict         : build without kmi strict mode
    --no-ldo3               : do not enable o3 in the LD and LTO (save time)
    --ksu                   : build with KernelSU support
    --defconfig <defconfig> : use the specified defconfig (default: $DEFCONFIG)
    -- <args>               : parameters passed directly to make
EOF
			exit 1
		};;
	esac
	shift
done

########## Preparation Phase ##########

unstable_build=false

current_branch=$(git branch | grep -E '^\*' | awk '{print $2}') && {
	case $current_branch in
		*unstable*) {
			echo -e "${yellow}Warning: You are building on unstable branch! $white"
			echo -e "${yellow}Warning: So force disable ccache and kmi strict mode! $white"
			unstable_build=true
			no_ccache=true
			KMI_STRICT_MODE=false
		};;
	esac
}

export KBUILD_BUILD_HOST="wsl2"
export KBUILD_BUILD_USER="pzqqt"

# 编译内核模块只能使用 Google clang 12.0.5
CLANG_PATH=/home/pzqqt/build_toolchain/clang-r416183b-12.0.5/bin
# 编译 GKI 则可用使用更先进的 clang
if [ "$make_target" == "Image" ]; then
	if $USE_SLIM_LLVM; then
		echo -e "${gre}Building kernel image with Slim LLVM 20.1.3 $white"
		CLANG_PATH=/home/pzqqt/build_toolchain/llvm-20.1.3-x86_64/bin
	else
#		echo -e "${gre}Building kernel image with Google clang 19.0.1 $white"
#		CLANG_PATH=/home/pzqqt/build_toolchain/clang-r536225-19.0.1/bin
		echo -e "${gre}Building kernel image with Google clang 20.0.0 $white"
		CLANG_PATH=/home/pzqqt/build_toolchain/clang-r547379-20.0.0/bin
	fi
fi

export PATH=${CLANG_PATH}:${PATH}

export LOCALVERSION=-v3.8.1
$unstable_build && export LOCALVERSION="${LOCALVERSION}-unstable"
$with_ksu && {
	while true; do
		kversion_ksu_suffix=$(cat /dev/urandom | tr -dc 'a-zA-Z' | head -c 3)
		echo $kversion_ksu_suffix | grep -qi 'ksu' || break
	done
	export LOCALVERSION="${LOCALVERSION}-${kversion_ksu_suffix}"
	unset kversion_ksu_suffix
}

make_flags="ARCH=arm64 LLVM=1 LLVM_IAS=1 O=out"
make_kcflags="-D__ANDROID_COMMON_KERNEL__ -O3"
make_kbuild_ldflags=
# 编译 GKI 时, 在 LD 和 LTO 阶段启用 3 级优化
[ "$make_target" == "Image" ] && ! $no_ldo3 && make_kbuild_ldflags="-O3 --lto-O3"

$no_ccache && {
	echo -e "${yellow}Warning: ccache is not used! $white"
	make_flags+=" CCACHE="
}

########## Make it ##########

$no_mkclean || make $make_flags KCFLAGS="$make_kcflags" KBUILD_LDFLAGS="$make_kbuild_ldflags" mrproper
make $make_flags KCFLAGS="$make_kcflags" KBUILD_LDFLAGS="$make_kbuild_ldflags" "$use_defconfig"

$with_ksu && {
	./scripts/config --file ./out/.config \
	    -e KSU \
	    -d KSU_DEBUG \
	    -e KSU_MANUAL_HOOK
}
if [ "$(./scripts/config --file ./out/.config -s CFI_FORCE_SKIP_CHECK)" == "y" ]; then
	echo -e "${yellow}Warning: CFI checks is disabled! $white"
fi
# Slim llvm dose not support polly
$USE_SLIM_LLVM && ./scripts/config --file ./out/.config -d LLVM_POLLY

if ${KMI_STRICT_MODE}; then

	_gen_symbol_files_list() {
		(
			ROOT_DIR=.
			KERNEL_DIR=.
			source ./build.config.gki.aarch64 2>/dev/null
			echo $KMI_SYMBOL_LIST $ADDITIONAL_KMI_SYMBOL_LISTS
		)
	}

	TMP_ABI_SYMBOLLIST=/tmp/abi_symbollist
	TMP_ABI_SYMBOLLIST_RAW=/tmp/abi_symbollist.raw
	rm -f "$TMP_ABI_SYMBOLLIST"
	rm -f "$TMP_ABI_SYMBOLLIST_RAW"

	${GKI_BUILD_TOOLS}/copy_symbols.sh "$TMP_ABI_SYMBOLLIST" . $(_gen_symbol_files_list)
	cat "$TMP_ABI_SYMBOLLIST" | ${GKI_BUILD_TOOLS}/abi/flatten_symbol_list > "$TMP_ABI_SYMBOLLIST_RAW"

	./scripts/config --file ./out/.config \
	    -d UNUSED_SYMBOLS -e TRIM_UNUSED_KSYMS  \
	    --set-str UNUSED_KSYMS_WHITELIST "$TMP_ABI_SYMBOLLIST_RAW" \
	    -e UNUSED_KSYMS_WHITELIST_ONLY
fi

t_start=$(date +"%s")

make $make_flags KCFLAGS="$make_kcflags" KBUILD_LDFLAGS="$make_kbuild_ldflags" -j$(nproc --all) $make_target

if [ $? != 0 ]; then
	echo -e "$red << Failed to compile, fix the errors first >>$white"
	exit 1
fi

########## Processing products ##########

if [ -f "$IMAGE" ]; then
	cp -f "$IMAGE" ${OUTPUT_DIR}/$($with_ksu && echo "Image_ksu" || echo "Image")
fi

# 需要在 vendor_dlkm 分区替换的内核模块
vendor_dlkm_need_modules='
drivers/staging/qcacld-3.0/qca6490.ko
drivers/net/wireless/cnss2/cnss2.ko
drivers/iio/adc/qcom-spmi-adc5.ko
drivers/input/touchscreen/goodix_9916r/goodix_core.ko
drivers/input/touchscreen/goodix_berlin_driver/goodix_core_los.ko
drivers/input/touchscreen/xiaomi/xiaomi_touch.ko
drivers/input/touchscreen/xiaomi_los/xiaomi_touch.ko
drivers/input/misc/qcom-hv-haptics.ko
drivers/gpu/msm/msm_kgsl.ko
drivers/leds/leds-qti-flash.ko
drivers/cpuidle/governors/qcom_lpm.ko
drivers/platform/msm/ipa_fmwk/ipa_fmwk.ko
drivers/platform/msm/mhi_dev/mhi_dev_drv.ko
drivers/usb/gadget/function/usb_f_gsi.ko
drivers/pci/controller/pci-msm-drv.ko
drivers/input/fingerprint/goodix_3626/goodix_3626.ko
drivers/input/fingerprint/fpc_1540/fpc1540.ko
drivers/spi/spi-msm-geni.ko
drivers/staging/binder_prio/binder_prio.ko
drivers/soc/qcom/vh_fs/vh_fs.ko
drivers/soc/qcom/sync_fence/qcom_sync_file.ko
drivers/block/zram/zram.ko
mm/zsmalloc.ko
net/wireless/cfg80211.ko
net/mac80211/mac80211.ko
techpack/cvp/msm/msm-cvp.ko
techpack/eva/msm/msm-eva.ko
techpack/mmrm/driver/msm-mmrm.ko
techpack/video/msm_video.ko
techpack/audio/dsp/q6_dlkm.ko
techpack/audio/dsp/adsp_loader_dlkm.ko
techpack/audio/dsp/q6_pdr_dlkm.ko
techpack/audio/dsp/spf_core_dlkm.ko
techpack/audio/dsp/q6_notifier_dlkm.ko
techpack/audio/dsp/audio_prm_dlkm.ko
techpack/audio/dsp/audpkt_ion_dlkm.ko
techpack/audio/ipc/gpr_dlkm.ko
techpack/audio/ipc/audio_pkt_dlkm.ko
techpack/audio/soc/pinctrl_lpi_dlkm.ko
techpack/audio/soc/swr_dlkm.ko
techpack/audio/soc/snd_event_dlkm.ko
techpack/audio/soc/swr_ctrl_dlkm.ko
techpack/audio/asoc/codecs/wcd937x/wcd937x_dlkm.ko
techpack/audio/asoc/codecs/wcd937x/wcd937x_slave_dlkm.ko
techpack/audio/asoc/codecs/wcd938x/wcd938x_dlkm.ko
techpack/audio/asoc/codecs/wcd938x/wcd938x_slave_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_wsa2_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_wsa_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_va_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko
techpack/audio/asoc/codecs/lpass-cdc/lpass_cdc_rx_macro_dlkm.ko
techpack/audio/asoc/codecs/wsa883x/wsa883x_dlkm.ko
techpack/audio/asoc/codecs/wcd_core_dlkm.ko
techpack/audio/asoc/codecs/wcd9xxx_dlkm.ko
techpack/audio/asoc/codecs/wsa881x_dlkm.ko
techpack/audio/asoc/codecs/swr_dmic_dlkm.ko
techpack/audio/asoc/codecs/mbhc_dlkm.ko
techpack/audio/asoc/codecs/hdmi_dlkm.ko
techpack/audio/asoc/codecs/swr_haptics_dlkm.ko
techpack/audio/asoc/codecs/aw882xx/aw882xx_dlkm.ko
techpack/audio/asoc/machine_dlkm.ko
techpack/dataipa/drivers/platform/msm/gsi/gsim.ko
techpack/dataipa/drivers/platform/msm/ipa/ipa_clients/rndisipam.ko
techpack/dataipa/drivers/platform/msm/ipa/ipa_clients/ipa_clientsm.ko
techpack/dataipa/drivers/platform/msm/ipa/ipam.ko
techpack/dataipa/drivers/platform/msm/ipa/ipanetm.ko
techpack/datarmnet/core/rmnet_core.ko
techpack/datarmnet/core/rmnet_ctl.ko
techpack/datarmnet-ext/aps/rmnet_aps.ko
techpack/datarmnet-ext/offload/rmnet_offload.ko
techpack/datarmnet-ext/perf/rmnet_perf.ko
techpack/datarmnet-ext/perf_tether/rmnet_perf_tether.ko
techpack/datarmnet-ext/sch/rmnet_sch.ko
techpack/datarmnet-ext/shs/rmnet_shs.ko
techpack/datarmnet-ext/wlan/rmnet_wlan.ko
'

# 需要在 vendor_boot 分区替换的内核模块
vendor_boot_need_modules='
drivers/soc/qcom/qcom_wdt_core.ko
drivers/rtc/rtc-pm8xxx.ko
'

# 不一定必须替换, 但有时候需要的内核模块
alt_need_modules='
techpack/display/msm/msm_drm.ko
drivers/cpufreq/qcom-cpufreq-hw.ko
drivers/power/reset/qcom-dload-mode.ko
drivers/power/supply/qti_battery_charger.ko
drivers/power/supply/qti_battery_charger_main.ko
drivers/soc/qcom/smcinvoke_mod.ko
drivers/soc/qcom/panel_event_notifier.ko
drivers/misc/qseecom-mod.ko
drivers/thermal/mi_thermal_interface.ko
crypto/lzo.ko
crypto/lzo-rle.ko
'

rm ${OUTPUT_DIR}/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/vendor_boot_modules/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/vendor_dlkm_modules/*.ko 2>/dev/null
rm ${OUTPUT_DIR}/alt_kernel_modules/*.ko 2>/dev/null

for module in $vendor_dlkm_need_modules; do
	[ -f ./out/$module ] || {
		echo -e "${yellow}! ${module} not found! ${white}"
		continue
	}
	module_file_name=$(basename $module)
	case $module_file_name in
		"qca6490.ko")                  module_file_name="qca_cld3_qca6490.ko";;
		# "qti_battery_charger_main.ko") module_file_name="qti_battery_charger.ko";;
	esac
	echo "- Striping $module_file_name ..."
	llvm-strip -S ./out/$module -o ${OUTPUT_DIR}/vendor_dlkm_modules/${module_file_name}
done
for module in $vendor_boot_need_modules; do
	[ -f ./out/$module ] || {
		echo -e "${yellow}! ${module} not found! ${white}"
		continue
	}
	module_file_name=$(basename $module)
	echo "- Striping $module_file_name ..."
	llvm-strip -S ./out/$module -o ${OUTPUT_DIR}/vendor_boot_modules/${module_file_name}
done
for module in $alt_need_modules; do
	[ -f ./out/$module ] || {
		echo -e "${yellow}! ${module} not found! ${white}"
		continue
	}
	module_file_name=$(basename $module)
	echo "- Striping $module_file_name ..."
	llvm-strip -S ./out/$module -o ${OUTPUT_DIR}/alt_kernel_modules/${module_file_name}
done

t_end=$(date +"%s")
t_diff=$(($t_end - $t_start))

echo -e "$gre << Build completed in $(($t_diff / 60)) minutes and $(($t_diff % 60)) seconds >> \n $white"

if ! ${unstable_build}; then
	if [ -f ./KMI_function_symbols_test.py ]; then
		echo "Checking for mismatching function symbol crc values..."
		python3 ./KMI_function_symbols_test.py
	fi

	if $KMI_STRICT_MODE; then
		if [ -f ./out/Module.symvers ]; then
			echo ""
			echo "Comparing the KMI and the symbol lists..."
			if ${GKI_BUILD_TOOLS}/abi/compare_to_symbol_list ./out/Module.symvers ${TMP_ABI_SYMBOLLIST_RAW}; then
				echo "No mismatching items found. Good job!"
			fi
		fi

		if [ "$make_target" == "Image" ]; then
			tmp_abi_xml=/tmp/abi${LOCALVERSION}-$(git rev-parse HEAD | head -c12).xml
			export PATH=${GKI_BUILD_TOOLS}/../prebuilts/kernel-build-tools/linux-x86/bin:$PATH
			echo ""
			echo "Generating ${tmp_abi_xml}..."
			${GKI_BUILD_TOOLS}/abi/dump_abi --linux-tree ./out --vmlinux ./out/vmlinux --out-file "$tmp_abi_xml" --tidy
			# Remove all "line" attributes for easier comparison.
			sed -i "s/\ line='[[:digit:]]\+'\ /\ /g" "$tmp_abi_xml"
#			echo "Generate abi comparison report..."
#			${GKI_BUILD_TOOLS}/abi/diff_abi --baseline ./android/abi_gki_aarch64.xml --new "$tmp_abi_xml" --report /tmp/abi.report --short-report /tmp/abi.report.short --full-report
		fi
	fi
fi
