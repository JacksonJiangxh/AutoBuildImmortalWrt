#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

# 配置硬件加速：Flow Offloading 流量卸载
# 大幅提升 NAT 转发性能，降低 CPU 占用
uci set firewall.defaults.flow_offloading='1'
uci set firewall.defaults.flow_offloading_hw='1'

# 配置 Full Cone NAT（全锥 NAT）
# 改善 P2P 游戏、视频通话、远程桌面等连接质量
uci set firewall.defaults.fullcone='1'
uci set firewall.defaults.fullcone6='0'

# 启用 SYN Flood 防护
uci set firewall.defaults.syn_flood='1'

# 提交防火墙配置
uci commit firewall

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. 先获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# 2. 根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
# 此处特殊处理个别开发板网口顺序问题
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        # 默认第一个接口为WAN，其余为LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        echo "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
esac

# 3. 配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # 多网口设备配置
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 查找 br-lan 设备 section
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "error：cannot find device 'br-lan'." >>$LOGFILE
    else
        # 删除原有ports
        uci -q delete "network.$section.ports"
        # 添加LAN接口端口
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Updated br-lan ports: $lan_ifnames" >>$LOGFILE
    fi

    # LAN口设置静态IP
    uci set network.lan.proto='static'
    # 多网口设备 支持修改为别的管理后台地址 在Github Action 的UI上自行输入即可 
    uci set network.lan.netmask='255.255.255.0'
    # 设置路由器管理后台地址
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # 用户在UI上设置的路由器后台管理地址
        uci set network.lan.ipaddr=$CUSTOM_IP
        echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "default router ip is 192.168.100.1" >> $LOGFILE
    fi

    # PPPoE设置
    echo "enable_pppoe value: $enable_pppoe" >>$LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE enabled, configuring..." >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE config done." >>$LOGFILE
    else
        echo "PPPoE not enabled." >>$LOGFILE
    fi

    uci commit network
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "fix ttyd show msg: /usb/bin/zsh: not found" >>$LOGFILE
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "fix quickfile nginx config" >>$LOGFILE
fi

# 配置硬件卸载：ethtool GRO 优化
# 对所有物理网卡启用 UDP GRO 转发，提升 UDP 流量性能
# 同时关闭 rx-gro-list 避免兼容性问题
cat > /etc/rc.local <<'EOF'
#!/bin/sh
# 硬件卸载优化配置

# 获取所有物理网卡并应用 ethtool 优化
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ethtool -K "$iface_name" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null
    fi
done

exit 0
EOF
chmod +x /etc/rc.local

# 若安装了dockerd 则配置 Docker
# 1. 关闭 Docker 自动 iptables 注入，避免与 fw4 冲突
# 2. 配置防火墙规则，扩大 docker 涵盖的子网范围 '172.16.0.0/12'
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置..."
    echo "检测到 Docker，正在配置..." >>$LOGFILE

    # 步骤1：配置 Dockerd 全局参数
    # 关闭 Docker 自动 iptables/ip6tables 注入
    # 让防火墙完全由 OpenWrt fw4 管理，避免规则冲突
    if uci -q get dockerd.globals >/dev/null 2>&1; then
        uci set dockerd.globals.iptables='0'
        uci set dockerd.globals.ip6tables='0'
        uci set dockerd.globals.log_level='warn'
        # 默认数据目录，如需迁移到硬盘修改此处即可
        uci set dockerd.globals.data_root='/opt/docker/'
        # 配置 Docker 日志限制，防止日志无限增长占满存储空间
        # 每个容器日志文件最大 10MB，最多保留 5 个日志文件
        # OpenWrt dockerd 通过这些 UCI 选项生成 daemon.json 中的 log-opts
        uci add_list dockerd.globals.log_opt='max-size=10m'
        uci add_list dockerd.globals.log_opt='max-file=5'
        uci commit dockerd
        echo "已配置 Dockerd：关闭 iptables 注入，数据目录 /opt/docker/，日志限制 10MB×5" >>$LOGFILE
    fi

    # 步骤2：移除 Dockerd 默认的 WAN 阻断规则
    # iptables 已关闭，该规则不再生效且可能造成干扰
    if uci -q get dockerd.@firewall[0] >/dev/null 2>&1; then
        uci -q del_list dockerd.@firewall[0].blocked_interfaces='wan'
        uci commit dockerd
    fi

    # 步骤3：配置 Docker 防火墙规则（使用子网模式，更灵活）
    FW_FILE="/etc/config/firewall"

    # 先清理旧的 Docker 相关配置（幂等操作）
    # 删除 docker zone（如果存在）
    if uci -q get firewall.docker >/dev/null 2>&1; then
        uci delete firewall.docker
    fi

    # 删除所有 docker 相关的 forwarding 规则（倒序遍历避免索引问题）
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci -q get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci -q get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done

    # 提交删除操作
    uci commit firewall

    # 追加新的 zone + forwarding 配置（使用子网 172.16.0.0/12 覆盖所有 Docker 网段）
    cat <<'EOF' >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

    echo "Docker 防火墙规则配置完成" >>$LOGFILE

else
    echo "未检测到 Docker，跳过配置。"
fi

exit 0
