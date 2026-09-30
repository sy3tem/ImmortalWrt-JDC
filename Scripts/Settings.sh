#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

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

#apk软件源用官方 downloads.immortalwrt.org(snapshots滚动版, 走Cloudflare CDN)
#VERSION_REPO 是编译变量, 写进 /etc/apk/repositories.d/distfeeds.list
#坑1: 依赖链 CONFIG_IMAGEOPT -> CONFIG_VERSIONOPT -> CONFIG_VERSION_REPO, 三级都要=y
#    VERSION_REPO 在 image-config.in 里被 "if VERSIONOPT" 包裹, 而 VERSIONOPT 又是 "if IMAGEOPT" 的 menuconfig(default n)
#    少开任何一个, kconfig(olddefconfig) 都会把下级的 REPO 丢弃, 源静默不生效(25ebdcf/d1ea589/2f8abc2 三批都因此白改)
#坑2(R28S 9-28踩过, 别用SJTU): SJTU把 packages.adb 302重定向到浙大镜像(mirrors.zju.edu.cn),
#    浙大仅~2KB/s巨慢, apk update/iStore装包卡死; 实测官方源直连无重定向最快(11~35KB/s), 故用官方源
echo 'CONFIG_IMAGEOPT=y' >> ./.config
echo 'CONFIG_VERSIONOPT=y' >> ./.config
echo 'CONFIG_VERSION_REPO="https://downloads.immortalwrt.org/snapshots"' >> ./.config

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


#注：FULL 版代理核心已由 sing-box(homeproxy) 换成 xray-core(passwall)，
#原先"固定 sing-box 到 1.14.1"的段落已移除——保留它会误改 passwall 自带的 sing-box Makefile。

#===============================================================================
#IPTV组播三要素固化(移植自 R28S 实测 HTTP200 通流方案, commit 7e1e97c/15fd134)
#  ①组播路由 224.0.0.0/4 指向 IPTV接口 —— 不加则IGMP加组走默认路由从上网口发出,运营商IPTV专网收不到
#    (rtp2httpd的--upstream-interface只影响单播SO_BINDTODEVICE,对纯组播IGMP无效,内核按路由表选出口)
#  ②独立 iptv 防火墙 zone(masq=0) —— 大坑: fw4的wan zone链iifname只含上网口,组播从IPTV口进来规则全落空
#    必须建独立zone按接口匹配放行; 不开masq让组播不碰fullcone NAT(比按224/4 IP段放行更通用,组播地址不固定)
#  ③IGMP v2 固化 force_igmp_version=2 —— 运营商IPTV一般只吃v2
#固化用 uci-defaults + hotplug.d/iface 双保险: uci-defaults只在首次开机跑一次,
#  若开机后才建iptv接口会漏, hotplug在每次ifup iptv时补建(建zone逻辑hotplug里也要有,R28S 15fd134的教训)
#自适应: 不预设拓扑, 监听名为 iptv 的接口(DHCP/静态/PPPoE双拨/VLAN均可), 建起后自动配齐三要素
#===============================================================================

#--- uci-defaults 首启兜底(仅当iptv接口已存在时建zone) ---
mkdir -p ./package/base-files/files/etc/uci-defaults
cat <<'EOF' > ./package/base-files/files/etc/uci-defaults/97-iptv-multicast
#!/bin/sh
#IPTV组播三要素固化(uci-defaults首启兜底): 仅当iptv接口已存在且zone未建时执行
#接口后建的场景由hotplug.d/iface/97-iptv-multicast兜底

#仅当 network.iptv 接口存在才处理(否则留给hotplug)
uci -q get network.iptv >/dev/null || exit 0

#②独立iptv防火墙zone(幂等: 已建则跳过)
if ! uci -q get firewall.iptv >/dev/null; then
	uci set firewall.iptv=zone
	uci set firewall.iptv.name='iptv'
	uci set firewall.iptv.network='iptv'
	uci set firewall.iptv.input='ACCEPT'
	uci set firewall.iptv.output='ACCEPT'
	uci set firewall.iptv.forward='DROP'
	uci set firewall.iptv.masq='0'
	uci set firewall.iptv.mtu_fix='0'
	uci commit firewall
fi

#③IGMP v2固化(sysctl持久化, 运行时由hotplug按接口补)
if ! grep -q 'force_igmp_version' /etc/sysctl.conf 2>/dev/null; then
	echo 'net.ipv4.conf.default.force_igmp_version=2' >> /etc/sysctl.conf
fi

#①组播路由(静态路由指向iptv接口, 持久化; 运行时hotplug也会补)
if ! uci -q show network | grep -q "224.0.0.0/4"; then
	uci add network route >/dev/null
	uci set network.@route[-1].interface='iptv'
	uci set network.@route[-1].target='224.0.0.0/4'
	uci commit network
fi

exit 0
EOF

#--- hotplug.d/iface 每次ifup iptv时补建(双保险, 接口后建/动态重建场景) ---
mkdir -p ./package/base-files/files/etc/hotplug.d/iface
cat <<'EOF' > ./package/base-files/files/etc/hotplug.d/iface/97-iptv-multicast
#!/bin/sh
#IPTV组播三要素 hotplug兜底: 每次 ifup iptv 时补建 zone+组播路由+IGMPv2(无论接口何时建/重连都自动就绪)
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "iptv" ] || exit 0

#接口实际设备名(pppoe-iptv/eth0.45/br-iptv等), 取不到则用接口名
DEV=$(ubus call network.interface.iptv status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
[ -z "$DEV" ] && DEV="$INTERFACE"

#②建防火墙zone(若缺)并重载
if ! uci -q get firewall.iptv >/dev/null; then
	uci set firewall.iptv=zone
	uci set firewall.iptv.name='iptv'
	uci set firewall.iptv.network='iptv'
	uci set firewall.iptv.input='ACCEPT'
	uci set firewall.iptv.output='ACCEPT'
	uci set firewall.iptv.forward='DROP'
	uci set firewall.iptv.masq='0'
	uci set firewall.iptv.mtu_fix='0'
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
fi

#①组播路由指向IPTV接口设备(224/4 + 239/8, replace幂等)
ip route replace 224.0.0.0/4 dev "$DEV" 2>/dev/null
ip route replace 239.0.0.0/8 dev "$DEV" 2>/dev/null

#③IGMP v2(运行时)
echo 2 > /proc/sys/net/ipv4/conf/"$DEV"/force_igmp_version 2>/dev/null

exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/97-iptv-multicast ./package/base-files/files/etc/hotplug.d/iface/97-iptv-multicast
echo "IPTV multicast 3-element (route+zone+IGMPv2) uci-defaults+hotplug injected!"

#===============================================================================
#rtp2httpd UDP接收缓冲调大(30Mbps高清/4K频道卡顿优化, R28S实测: 默认512KB偏小)
#  UCI option udp_rcvbuf_size 对应 -B/--udp-rcvbuf-size, 调到4MB(内核rmem_max默认4MB上限内)
#  用 uci-defaults 在 rtp2httpd 配置生成后调大(幂等: 已设置则跳过)
#===============================================================================
cat <<'EOF' > ./package/base-files/files/etc/uci-defaults/98-rtp2httpd-buffer
#!/bin/sh
#rtp2httpd UDP接收缓冲调大到4MB(默认512KB对30Mbps高清频道偏小)
if uci -q get rtp2httpd.main >/dev/null 2>&1; then
	CUR=$(uci -q get rtp2httpd.main.udp_rcvbuf_size 2>/dev/null)
	if [ -z "$CUR" ]; then
		uci set rtp2httpd.main.udp_rcvbuf_size='4194304'
		uci commit rtp2httpd
	fi
fi
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/98-rtp2httpd-buffer
echo "rtp2httpd udp_rcvbuf_size=4MB injected!"

#===============================================================================
#/opt 大分区(eMMC剩余空间) —— 移植 R28S 方案(9-28真机验证), 替代9-25放弃的旧opt-mount
#  用户思路(极简): 判断eMMC最后一个分区是否已是数据分区 → 已建就直接挂, 没建就在末尾建一个再挂
#  与R28S差异适配(JDC亚瑟/雅典娜, IPQ60xx):
#    ①根分区是 loop0(f2fs loop文件), 要 losetup -a 反推真实宿主分区(如 /dev/mmcblk0p18) —— 9-24验证可用
#    ②分区表是 GPT(京东云u-boot分好p1~p18), p18后约110G空闲, 新建即 p19
#    ③★必须运行时uci关 anon_mount(9-25失败真因): fstab默认anon_mount=1会把新分区p19抢先挂到
#      /mnt/mmcblk0p19(比init.d S99早), 导致/opt挂不上; 预写fstab文件会被sysupgrade升级还原,
#      只能在init.d启动时 uci set 运行时改(每次开机强制执行,升级覆盖不掉) —— R28S 4b710bf已验证
#  两段式(同R28S): 运行中系统盘新建分区后内核拒读分区表(Resource busy)须reboot一次才识别,
#    故用 init.d(每次启动跑+幂等) 而非 uci-defaults(只首启一次):
#      第1次启动: 建分区→reboot; 第2次启动: mkfs.ext4→挂/opt; 之后每次启动跳过
#===============================================================================
mkdir -p ./package/base-files/files/etc/init.d ./package/base-files/files/etc/rc.d
cat <<'EOF' > ./package/base-files/files/etc/init.d/jdc-opt-partition
#!/bin/sh /etc/rc.common
#JDC: 把eMMC剩余空间做成大分区挂/opt (移植R28S方案, 9-28真机验证; 替代9-25放弃的旧opt-mount)
#逻辑(用户定的极简版): 看eMMC最后一个分区是不是数据分区 → 已建就直接挂, 没建就在末尾建一个再挂
START=99

log() { logger -t jdc-opt "$1"; }

#挂载 + 运行时关anon_mount(9-25失败真因) + 写fstab(供参考,主要靠自己挂载)
_do_mount() {
	local PART="$1" UUID="$2"
	mkdir -p /opt
	#★运行时关匿名挂载: 防block-mount早期把本分区又挂到/mnt/mmcblk0p19(预写fstab会被sysupgrade还原)
	uci set fstab.@global[0].anon_mount='0'
	uci set fstab.@global[0].anon_swap='0'
	#清掉其它自动挂载项, 只保留/opt
	while uci -q del fstab.@mount[-1]; do true; done
	uci add fstab mount
	uci set fstab.@mount[-1].target="/opt"
	uci set fstab.@mount[-1].uuid="$UUID"
	uci set fstab.@mount[-1].enabled="1"
	uci commit fstab
	#卸载/mnt下的占用 + 删残留空目录(用/proc/mounts判断挂载点, 不依赖额外包)
	local m
	for m in /mnt/mmcblk0p18 /mnt/mmcblk0p19 /mnt/mmcblk1p18 /mnt/mmcblk1p19; do
		umount "$m" 2>/dev/null
		awk -v t="$m" '$2==t{f=1}END{exit !f}' /proc/mounts 2>/dev/null || rmdir "$m" 2>/dev/null
	done
	mount -t ext4 -o noatime "UUID=$UUID" /opt 2>&1 | logger -t jdc-opt || \
		mount "$PART" /opt 2>&1 | logger -t jdc-opt
	log "$PART ($UUID) mounted at /opt"
}

start() {
	for c in sfdisk mkfs.ext4 blkid lsblk losetup uci; do
		command -v "$c" >/dev/null 2>&1 || { log "missing $c, skip"; return 0; }
	done

	#已挂载则跳过(幂等; /opt/docker是bind不算)
	awk '$2=="/opt"{f=1}END{exit !f}' /proc/mounts 2>/dev/null && return 0

	#①找真实根分区: / 是 overlayfs, 根常在 /dev/loop0(f2fs loop) → losetup反推宿主分区
	#   losetup -a 形如: /dev/loop0: [0016]:9 (/mmcblk0p18), offset xxx
	local ROMPART DISK
	ROMPART=$(lsblk -nr -o PATH,MOUNTPOINT 2>/dev/null | awk '$2=="/rom"{print $1; exit}')
	case "$ROMPART" in
	/dev/loop*)
		ROMPART=$(losetup -a 2>/dev/null | grep -oE '\([^()]+\)' | head -1 | tr -d '()')
		ROMPART="/dev/$(basename "$ROMPART" 2>/dev/null)"
		;;
	esac
	#兜底: / 直接是块设备
	[ -b "$ROMPART" ] || ROMPART=$(awk '$2=="/" && $1 ~ /^\/dev\/mmcblk/ {print $1; exit}' /proc/mounts)
	case "$ROMPART" in
	/dev/mmcblk*p*) DISK="${ROMPART%p*}" ;;
	*) DISK="" ; for d in /dev/mmcblk0 /dev/mmcblk1; do [ -b "${d}p18" ] && { DISK="$d"; break; }; done ;;
	esac
	[ -b "$DISK" ] || { log "system disk not found, skip"; return 0; }

	#②取eMMC最后一个分区(用户核心判断): 已是数据分区就直接挂, 否则末尾建一个
	local LASTPART LASTNUM NEWPART FS UUID
	LASTPART=$(lsblk -nr -o PATH "$DISK" 2>/dev/null | grep -E "p[0-9]+$" | sort -V | tail -1)
	LASTNUM=$(echo "$LASTPART" | grep -oE 'p[0-9]+$' | tr -d 'p')
	[ -n "$LASTNUM" ] || { log "no partition on $DISK, skip"; return 0; }
	NEWPART="${DISK}p$((LASTNUM + 1))"

	#最后一个分区已是ext4数据分区(非根/非boot, 即上次建的) → 直接挂载
	if [ "$LASTPART" != "$ROMPART" ]; then
		FS=$(blkid -o value -s TYPE "$LASTPART" 2>/dev/null)
		if [ "$FS" = "ext4" ]; then
			UUID=$(blkid -o value -s UUID "$LASTPART" 2>/dev/null)
			[ -n "$UUID" ] && { _do_mount "$LASTPART" "$UUID"; return 0; }
		fi
	fi

	#否则在末尾新建数据分区(选最大空闲块起始扇区, GPT安全append不重建整表)
	local MAXSTART
	MAXSTART=$(sfdisk -F "$DISK" 2>/dev/null | awk '/^ *[0-9]+ +[0-9]+ +[0-9]+/{print $1, $3}' | sort -k2 -n | tail -1 | awk '{print $1}')
	[ -n "$MAXSTART" ] || { log "no free space on $DISK, skip"; return 0; }
	log "create $NEWPART from sector $MAXSTART (largest free space)"
	echo "${MAXSTART},,L," | sfdisk -a --force --no-reread "$DISK" 2>&1 | logger -t jdc-opt
	sync
	#内核未识别新分区(磁盘在用) → reboot让内核重读
	if [ ! -b "$NEWPART" ]; then
		log "partition table written, reboot to recognize $NEWPART"
		sleep 2
		reboot
		return 0
	fi
	#格式化(reboot后新分区已出现)
	log "mkfs.ext4 on $NEWPART"
	mkfs.ext4 -F "$NEWPART" 2>&1 | logger -t jdc-opt
	sync
	UUID=$(blkid -o value -s UUID "$NEWPART" 2>/dev/null)
	[ -n "$UUID" ] && _do_mount "$NEWPART" "$UUID"
	return 0
}
EOF
chmod +x ./package/base-files/files/etc/init.d/jdc-opt-partition
ln -sf ../init.d/jdc-opt-partition ./package/base-files/files/etc/rc.d/S99jdc-opt-partition
echo "JDC /opt big-partition init.d service injected!"
