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

#apk软件源改国内镜像(SJTU上海交大, snapshots滚动版; 刷机后apk install走国内不卡)
#VERSION_REPO 是编译变量, 写进 /etc/apk/repositories.d/distfeeds.list
#坑: 依赖链 CONFIG_IMAGEOPT -> CONFIG_VERSIONOPT -> CONFIG_VERSION_REPO, 三级都要=y
#    VERSION_REPO 在 image-config.in 里被 "if VERSIONOPT" 包裹, 而 VERSIONOPT 又是 "if IMAGEOPT" 的 menuconfig(default n)
#    少开任何一个, kconfig(olddefconfig) 都会把下级的 REPO 丢弃, 源静默不生效(25ebdcf/d1ea589/2f8abc2 三批都因此白改)
echo 'CONFIG_IMAGEOPT=y' >> ./.config
echo 'CONFIG_VERSIONOPT=y' >> ./.config
echo 'CONFIG_VERSION_REPO="https://mirrors.sjtug.sjtu.edu.cn/immortalwrt/snapshots"' >> ./.config

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
