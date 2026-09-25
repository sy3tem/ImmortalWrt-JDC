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

#修改默认root密码为 password (默认为空, 写 /etc/shadow, MD5crypt 哈希)
echo 'root:$1$4C5K7.$KQSzgarR6TWvov9ZTlKPS0:0:0:99999:7:::' > ./package/base-files/files/etc/shadow
echo "default root password set to 'password'!"

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
#按以下顺序识别, 逐级回退:
#1)/opt 已挂载 -> 跳过
#2)fstab 里已配置 -> 交给系统按配置挂载
#3)存在标签为 opt 的分区 -> 直接挂载
#4)根分区所在磁盘上最后一个未挂载的分区 -> 有文件系统就挂, 没文件系统先格式化再挂
#5)以上都没有 -> 在磁盘剩余空间新建分区后挂载
#最终结果写入 /etc/config/fstab, 之后开机自动挂载

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

dev_mounted() {
	awk -v d="$1" '$1==d {f=1} END {exit !f}' /proc/mounts
}

root_dev() {
	#/proc/mounts 里 / 的源常是 overlayfs:/overlay 而非块设备
	#真实根分区可能是: ①/rom 挂的块设备(纯squashfs方案) ②/dev/loop0(f2fs loop文件) -> 需 losetup 反推宿主分区
	local romdev loopback
	#① 优先: /rom 挂载的块设备(如 /dev/mmcblk0p18 直接挂 /rom)
	romdev=$(awk '$2=="/rom" && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts)
	case "$romdev" in
		/dev/loop*) romdev="" ;;  #loop 还要往下反推
		/dev/*) echo "$romdev"; return ;;
	esac
	#② loop 设备: losetup 反推宿主分区
	#   losetup -a 形如: /dev/loop0: [0016]:9 (/mmcblk0p18), offset xxx  -> 宿主是 /dev/mmcblk0p18
	if [ -e /dev/loop0 ]; then
		loopback=$(losetup -a 2>/dev/null | grep -oE '\([^()]+\)' | head -1 | tr -d '()')
		#取括号里名字的 basename(mmcblk0p18), 拼 /dev/ 前缀
		romdev="/dev/$(basename "$loopback" 2>/dev/null)"
		[ -n "$loopback" ] && [ -e "$romdev" ] && { echo "$romdev"; return; }
	fi
	#③ 兜底: / 直接是块设备
	awk '$2=="/" && $1 ~ /^\/dev\// {print $1; exit}' /proc/mounts
}

disk_of() {
	#/dev/mmcblk0p5 -> /dev/mmcblk0 ; /dev/sda5 -> /dev/sda
	echo "$1" | sed -E 's#p?[0-9]+$##'
}

fs_type() {
	blkid -s TYPE -o value "$1" 2>/dev/null
}

list_parts() {
	lsblk -nro NAME,TYPE "$1" 2>/dev/null | awk '$2=="part" {print "/dev/"$1}'
}

save_fstab() {
	local dev fstype uuid
	dev="$1"
	fstype="$2"
	uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null)
	uci -q delete fstab.opt
	uci set fstab.opt=mount
	if [ -n "$uuid" ]; then
		uci set fstab.opt.uuid="$uuid"
	else
		uci set fstab.opt.device="$dev"
	fi
	uci set fstab.opt.target="$TARGET"
	uci set fstab.opt.fstype="$fstype"
	uci set fstab.opt.options=noatime
	uci set fstab.opt.enabled=1
	uci commit fstab
}

mount_dev() {
	local dev fstype
	dev="$1"
	fstype="$2"
	mount -t "$fstype" -o noatime "$dev" "$TARGET" || return 1
	save_fstab "$dev" "$fstype"
	return 0
}

start() {
	mkdir -p "$TARGET"

	#1)已经挂载
	if is_mounted "$TARGET"; then
		log "$TARGET 已挂载, 跳过"
		return 0
	fi

	#2)交给系统按已有配置挂载
	if [ -x /sbin/block ]; then
		/sbin/block mount >/dev/null 2>&1
		if is_mounted "$TARGET"; then
			log "已按 fstab 配置挂载到 $TARGET"
			return 0
		fi
	fi

	local rdev disk dev fstype cand part

	rdev=$(root_dev)
	case "$rdev" in
		/dev/*) ;;
		*) log "根分区不是块设备($rdev), 跳过"; return 1 ;;
	esac
	disk=$(disk_of "$rdev")

	#3)标签为 opt 的分区
	dev=$(blkid 2>/dev/null | awk -F: -v l="LABEL=\"$LABEL\"" 'index($0, l) {print $1; exit}')
	if [ -n "$dev" ] && [ -e "$dev" ] && ! dev_mounted "$dev"; then
		fstype=$(fs_type "$dev")
		[ -n "$fstype" ] || fstype="ext4"
		if mount_dev "$dev" "$fstype"; then
			log "挂载标签为 $LABEL 的分区 $dev 到 $TARGET"
			return 0
		fi
	fi

	#4)磁盘上已存在但未挂载的最后一个分区
	cand=""
	for part in $(list_parts "$disk"); do
		[ "$part" = "$rdev" ] && continue
		dev_mounted "$part" && continue
		cand="$part"
	done
	if [ -n "$cand" ] && [ -e "$cand" ]; then
		fstype=$(fs_type "$cand")
		if [ -n "$fstype" ]; then
			if mount_dev "$cand" "$fstype"; then
				log "分区 $cand 已存在($fstype), 直接挂载到 $TARGET"
				return 0
			fi
		else
			if mkfs.ext4 -F -L "$LABEL" "$cand" >/dev/null 2>&1 && mount_dev "$cand" "ext4"; then
				log "分区 $cand 已存在但未格式化, 已格式化并挂载到 $TARGET"
				return 0
			fi
		fi
	fi

	#5)没有可用分区, 在磁盘末尾新建
	log "没有可用分区, 尝试在 $disk 上新建"
	if ! printf ',,\n' | sfdisk --append "$disk" >/dev/null 2>&1; then
		log "$disk 没有可用剩余空间, 放弃"
		return 1
	fi
	partx -a "$disk" >/dev/null 2>&1
	blockdev --rereadpt "$disk" >/dev/null 2>&1
	sleep 2

	cand=""
	for part in $(list_parts "$disk"); do
		[ "$part" = "$rdev" ] && continue
		dev_mounted "$part" && continue
		cand="$part"
	done
	[ -n "$cand" ] && [ -e "$cand" ] || { log "新建分区后找不到设备, 放弃"; return 1; }
	if [ "$cand" = "$rdev" ] || dev_mounted "$cand"; then
		log "$cand 正在使用中, 放弃"
		return 1
	fi
	mkfs.ext4 -F -L "$LABEL" "$cand" >/dev/null 2>&1 || { log "格式化 $cand 失败"; return 1; }
	if mount_dev "$cand" "ext4"; then
		log "已新建分区 $cand 并挂载到 $TARGET"
		return 0
	fi

	log "挂载失败"
	return 1
}

stop() {
	umount "$TARGET" 2>/dev/null
}
OPTMOUNT
chmod +x ./package/base-files/files/etc/init.d/opt-mount
ln -sf ../init.d/opt-mount ./package/base-files/files/etc/rc.d/S99opt-mount
echo "opt auto mount script injected!"

#注：FULL 版代理核心已由 sing-box(homeproxy) 换成 xray-core(passwall)，
#原先"固定 sing-box 到 1.14.1"的段落已移除——保留它会误改 passwall 自带的 sing-box Makefile。
