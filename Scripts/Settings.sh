#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
	#其他调整
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi

#自动挂载剩余空间到/opt
mkdir -p ./package/base-files/files/etc/init.d ./package/base-files/files/etc/rc.d
cat > ./package/base-files/files/etc/init.d/opt-mount <<'OPTMOUNT'
#!/bin/sh /etc/rc.common
#开机自动把磁盘剩余空间挂载到 /opt
#1)已存在标签为 opt 的分区 -> 直接挂载
#2)不存在 -> 在根分区所在磁盘的剩余空间新建分区, 格式化为ext4(标签opt)后挂载
#3)结果写入 /etc/config/fstab, 之后开机自动挂载

START=99
STOP=10

LABEL="opt"
TARGET="/opt"

log() {
	logger -t opt-mount "$1"
	echo "opt-mount: $1"
}

is_mounted() {
	awk -v t="$1" '$2==t {f=1} END {exit !f}' /proc/mounts
}

root_dev() {
	awk '$2=="/" {print $1; exit}' /proc/mounts
}

disk_of() {
	#/dev/mmcblk0p5 -> /dev/mmcblk0 ; /dev/sda5 -> /dev/sda
	echo "$1" | sed -E 's#p?[0-9]+$##'
}

find_by_label() {
	blkid 2>/dev/null | awk -F: -v l="LABEL=\"$LABEL\"" 'index($0, l) {print $1; exit}'
}

start() {
	mkdir -p "$TARGET"

	if is_mounted "$TARGET"; then
		log "$TARGET 已挂载, 跳过"
		return 0
	fi

	local rdev disk dev last uuid
	rdev=$(root_dev)
	case "$rdev" in
		/dev/*) ;;
		*) log "根分区不是块设备($rdev), 跳过"; return 1 ;;
	esac
	disk=$(disk_of "$rdev")

	dev=$(find_by_label)

	if [ -z "$dev" ]; then
		log "未找到标签为 $LABEL 的分区, 尝试在 $disk 上新建"

		#没有剩余空间时 sfdisk 会直接报错退出, 不会破坏已有分区
		if ! printf ',,\n' | sfdisk --append "$disk" >/dev/null 2>&1; then
			log "$disk 没有可用剩余空间, 放弃"
			return 1
		fi

		partx -a "$disk" >/dev/null 2>&1
		blockdev --rereadpt "$disk" >/dev/null 2>&1
		sleep 2

		last=$(lsblk -nro NAME "$disk" 2>/dev/null | tail -n 1)
		[ -n "$last" ] || { log "新建分区后找不到设备, 放弃"; return 1; }
		dev="/dev/$last"

		if [ "$dev" = "$rdev" ] || is_mounted "$dev"; then
			log "$dev 正在使用中, 放弃"
			return 1
		fi

		mkfs.ext4 -F -L "$LABEL" "$dev" >/dev/null 2>&1 || { log "格式化 $dev 失败"; return 1; }
		log "已新建并格式化 $dev"
	else
		log "找到已存在的分区 $dev"
	fi

	mount -o noatime "$dev" "$TARGET" || { log "挂载 $dev 到 $TARGET 失败"; return 1; }

	uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
	if [ -n "$uuid" ]; then
		uci -q delete fstab.opt
		uci set fstab.opt=mount
		uci set fstab.opt.uuid="$uuid"
		uci set fstab.opt.target="$TARGET"
		uci set fstab.opt.fstype=ext4
		uci set fstab.opt.options=noatime
		uci set fstab.opt.enabled=1
		uci commit fstab
	fi

	log "已将 $dev 挂载到 $TARGET"
}

stop() {
	umount "$TARGET" 2>/dev/null
}
OPTMOUNT
chmod +x ./package/base-files/files/etc/init.d/opt-mount
ln -sf ../init.d/opt-mount ./package/base-files/files/etc/rc.d/S99opt-mount
echo "opt auto mount script injected!"
