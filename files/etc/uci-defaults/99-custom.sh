#!/bin/sh
# ============================================================================
# 99-custom.sh - ImmortalWrt 首次启动初始化脚本
# 固件首次启动时由 /etc/uci-defaults/ 自动执行（仅一次）
#
# 设计原则（安全梯度 / 守门员模式）：
#   - 首次启动 WAN 入站默认 ACCEPT（兼容原设计，避免断联无法访问 WebUI）
#   - 用户确认网络正常后，在 LuCI 中将 WAN 入站手动切换为 REJECT
#   - 或设置 LOCKDOWN_AFTER_INIT="yes"，脚本末尾自动切换为守门员模式
#   - 守门员模式下仅放行必要的 ICMPv6 协议报文 + 按需暴露的服务端口
#   - 内网（LAN/Docker）之间完全畅通，不受 WAN 侧策略影响
#   - IPv4 (CGNAT) 仅做出站 NAT，IPv6 公网按需转发
#   - 兼容 OpenClash 等代理分流场景
# ============================================================================

LOGFILE="/etc/config/uci-defaults-log.txt"
echo "===== 99-custom.sh started at $(date) =====" >>$LOGFILE

# ============================================================================
# 第0部分：可自定义参数区
#   用户可按需修改以下变量，无需改动脚本主体逻辑
# ============================================================================
ULA_PREFIX="fd00:dead:beef::/48"       # 本地 ULA 前缀（内网 IPv6 稳定地址）
PD_PREFIX_LEN="60"                      # DHCPv6-PD 请求的前缀长度（/56~/64）
DHCP_START="10"                         # DHCPv4 起始地址
DHCP_LIMIT="200"                        # DHCPv4 地址池数量
DHCP_LEASETIME="12h"                    # DHCP 租期
RA_MODE="server"                        # RA 模式: server(有状态+无状态) / hybrid / relay
RA_MANAGEMENT="1"                       # RA 管理标志: 1=DHCPv6 Stateful, 0=SLAAC Only
WAN_MTU="1500"                          # WAN 口 MTU（PPPoE 时建议 1492）

# 初始化完成后是否自动收紧防火墙（守门员模式）
# yes: 脚本末尾自动将 WAN 入站从 ACCEPT 切换为 REJECT
# no:  保持 WAN 入站 ACCEPT，用户确认网络正常后自行在 LuCI 中切换
#      推荐初次刷机先用 no，确认一切正常后再改为 yes 重新刷或手动切换
LOCKDOWN_AFTER_INIT="no"

# 按需暴露的服务端口列表（格式: "端口/协议 端口/协议 ..."）
# 仅在 LOCKDOWN_AFTER_INIT=yes 时生效
# 示例: EXPOSED_PORTS="443/tcp 8443/tcp 51820/udp"
EXPOSED_PORTS=""

# ============================================================================
# 第1部分：防火墙基础配置
#   初始 WAN 入站 ACCEPT（兼容首次访问），后续按 LOCKDOWN_AFTER_INIT 决定
# ============================================================================
echo ">>> Configuring firewall..." >>$LOGFILE

# --- 1.1 全局默认 ---
uci set firewall.defaults.flow_offloading='1'
uci set firewall.defaults.flow_offloading_hw='1'
uci set firewall.defaults.fullcone='1'
uci set firewall.defaults.fullcone6='0'    # IPv6 不做全锥 NAT（公网地址无需 NAT）
uci set firewall.defaults.syn_flood='1'
# 显式开启 IPv6 支持
uci -q delete firewall.defaults.disable_ipv6
uci set firewall.defaults.disable_ipv6='0'

# --- 1.2 LAN zone（内网完全信任）---
# 查找 LAN zone（通常是 @zone[0]）
lan_zone_idx=""
for i in $(seq 0 5); do
    name=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
    if [ "$name" = "lan" ]; then
        lan_zone_idx=$i
        break
    fi
done
if [ -n "$lan_zone_idx" ]; then
    uci set firewall.@zone[$lan_zone_idx].input='ACCEPT'
    uci set firewall.@zone[$lan_zone_idx].output='ACCEPT'
    uci set firewall.@zone[$lan_zone_idx].forward='ACCEPT'
    # LAN zone 同时覆盖 IPv4+IPv6 网络（先删除已有避免重复）
    uci -q del_list firewall.@zone[$lan_zone_idx].network='lan'
    uci add_list firewall.@zone[$lan_zone_idx].network='lan'
fi

# --- 1.3 WAN zone（守门员：默认拒绝入站）---
# 查找或创建 WAN zone（通常是 @zone[1]）
wan_zone_idx=""
for i in $(seq 0 5); do
    name=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
    if [ "$name" = "wan" ]; then
        wan_zone_idx=$i
        break
    fi
done

if [ -z "$wan_zone_idx" ]; then
    # WAN zone 不存在则创建
    uci add firewall zone
    wan_zone_idx=$(uci show firewall | grep "=zone" | tail -1 | cut -d[ -f2 | cut -d] -f1)
    uci set firewall.@zone[$wan_zone_idx].name='wan'
    uci add_list firewall.@zone[$wan_zone_idx].network='wan'
    uci add_list firewall.@zone[$wan_zone_idx].network='wan6'
fi

# WAN zone 基础策略
# 初始 input=ACCEPT（兼容首次访问，避免断联）
# 若 LOCKDOWN_AFTER_INIT=yes，脚本末尾自动切换为 REJECT
uci set firewall.@zone[$wan_zone_idx].input='ACCEPT'
uci set firewall.@zone[$wan_zone_idx].output='ACCEPT'
uci set firewall.@zone[$wan_zone_idx].forward='DROP'
# IPv4 做 MASQ（CGNAT 环境下必须），IPv6 不做 MASQ（公网地址直通）
uci set firewall.@zone[$wan_zone_idx].masq='1'
uci set firewall.@zone[$wan_zone_idx].masq6='0'
uci set firewall.@zone[$wan_zone_idx].mtu_fix='1'

# 确保 WAN zone 的 network 列表包含 wan 和 wan6
uci -q del_list firewall.@zone[$wan_zone_idx].network='wan'
uci -q del_list firewall.@zone[$wan_zone_idx].network='wan6'
uci add_list firewall.@zone[$wan_zone_idx].network='wan'
uci add_list firewall.@zone[$wan_zone_idx].network='wan6'

# --- 1.4 LAN->WAN 转发（内网出站）---
# 先清理旧的 LAN->WAN 转发（避免重复）
for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
    src=$(uci -q get firewall.@forwarding[$idx].src 2>/dev/null)
    dest=$(uci -q get firewall.@forwarding[$idx].dest 2>/dev/null)
    if [ "$src" = "lan" ] && [ "$dest" = "wan" ]; then
        uci delete firewall.@forwarding[$idx]
    fi
done

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'

# --- 1.5 IPv6 ICMP 协议放行（IPv6 正常运行所必需，无论 WAN 入站策略如何）---
# 先清理旧的 ICMPv6 规则
for idx in $(uci show firewall | grep "=rule" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
    name=$(uci -q get firewall.@rule[$idx].name 2>/dev/null)
    case "$name" in
        Allow-DHCPv6|Allow-MLD|Allow-ICMPv6-Input|Allow-ICMPv6-Forward)
            uci delete firewall.@rule[$idx]
            ;;
    esac
done

# DHCPv6 客户端（WAN 侧获取 IPv6 地址）
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-DHCPv6'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].src_ip='fe80::/10'
uci set firewall.@rule[-1].dest_port='546'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].target='ACCEPT'

# MLD 组播侦听（IPv6 多播基础协议）
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-MLD'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='icmp'
uci set firewall.@rule[-1].src_ip='fe80::/10'
uci -q add_list firewall.@rule[-1].icmp_type='130/0'
uci -q add_list firewall.@rule[-1].icmp_type='131/0'
uci -q add_list firewall.@rule[-1].icmp_type='132/0'
uci -q add_list firewall.@rule[-1].icmp_type='143/0'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].target='ACCEPT'

# ICMPv6 入站（邻居发现、路径 MTU 发现、Ping 等）
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-ICMPv6-Input'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='icmp'
uci -q add_list firewall.@rule[-1].icmp_type='echo-request'
uci -q add_list firewall.@rule[-1].icmp_type='echo-reply'
uci -q add_list firewall.@rule[-1].icmp_type='destination-unreachable'
uci -q add_list firewall.@rule[-1].icmp_type='packet-too-big'
uci -q add_list firewall.@rule[-1].icmp_type='time-exceeded'
uci -q add_list firewall.@rule[-1].icmp_type='bad-header'
uci -q add_list firewall.@rule[-1].icmp_type='unknown-header-type'
uci -q add_list firewall.@rule[-1].icmp_type='router-solicitation'
uci -q add_list firewall.@rule[-1].icmp_type='neighbour-solicitation'
uci -q add_list firewall.@rule[-1].icmp_type='router-advertisement'
uci -q add_list firewall.@rule[-1].icmp_type='neighbour-advertisement'
uci set firewall.@rule[-1].limit='1000/sec'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].target='ACCEPT'

# ICMPv6 转发（让内网设备也能收到必要的 ICMPv6 报文）
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-ICMPv6-Forward'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest='*'
uci set firewall.@rule[-1].proto='icmp'
uci -q add_list firewall.@rule[-1].icmp_type='echo-request'
uci -q add_list firewall.@rule[-1].icmp_type='echo-reply'
uci -q add_list firewall.@rule[-1].icmp_type='destination-unreachable'
uci -q add_list firewall.@rule[-1].icmp_type='packet-too-big'
uci -q add_list firewall.@rule[-1].icmp_type='time-exceeded'
uci -q add_list firewall.@rule[-1].icmp_type='bad-header'
uci -q add_list firewall.@rule[-1].icmp_type='unknown-header-type'
uci set firewall.@rule[-1].limit='1000/sec'
uci set firewall.@rule[-1].family='ipv6'
uci set firewall.@rule[-1].target='ACCEPT'

# --- 1.6 按需服务暴露规则（IPv6 公网可达端口）---
if [ -n "$EXPOSED_PORTS" ]; then
    for port_spec in $EXPOSED_PORTS; do
        port="${port_spec%/*}"
        proto="${port_spec#*/}"
        rule_name="Allow-IPv6-Service-${port}-${proto}"
        # 幂等：已存在则跳过
        if ! uci show firewall | grep -q "name='$rule_name'"; then
            uci add firewall rule
            uci set firewall.@rule[-1].name="$rule_name"
            uci set firewall.@rule[-1].src='wan'
            uci set firewall.@rule[-1].dest='lan'
            uci set firewall.@rule[-1].proto="$proto"
            uci set firewall.@rule[-1].dest_port="$port"
            uci set firewall.@rule[-1].family='ipv6'
            uci set firewall.@rule[-1].target='ACCEPT'
            echo "  Exposed IPv6 port: $port/$proto" >>$LOGFILE
        fi
    done
fi

uci commit firewall
echo "  Firewall configured (WAN input=ACCEPT initially, ICMPv6 rules added)" >>$LOGFILE

# ============================================================================
# 第2部分：DNS/DHCP 配置
# ============================================================================
echo ">>> Configuring DNS/DHCP..." >>$LOGFILE

# 主机名映射（解决安卓原生 TV 时间同步问题）
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 设置 ULA 前缀（内网 IPv6 稳定地址，不随 PD 前缀变化）
uci set network.globals.ula_prefix="$ULA_PREFIX"

uci commit dhcp
uci commit network

# ============================================================================
# 第3部分：读取 PPPoE 配置
# ============================================================================
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
    enable_pppoe="no"
else
    . "$SETTINGS_FILE"
    echo "PPPoE settings loaded: enable_pppoe=$enable_pppoe account_len=${#pppoe_account} pass_len=${#pppoe_password}" >>$LOGFILE
fi

# ============================================================================
# 第4部分：物理网口检测
# ============================================================================
echo ">>> Detecting physical interfaces..." >>$LOGFILE

# 等待 USB 网卡就绪（部分 x86 设备使用 USB 外接网卡，启动早期可能未初始化）
# 最多等待 15 秒，每 2 秒检查一次
MAX_WAIT=15
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    eth_count=0
    for iface in /sys/class/net/*; do
        iface_name=$(basename "$iface")
        if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
            eth_count=$((eth_count + 1))
        fi
    done
    if [ $eth_count -ge 2 ]; then
        echo "  $eth_count eth interfaces detected after ${WAITED}s" >>$LOGFILE
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    # 跳过虚拟接口（lo、docker*、br-*、veth*、ppp*、wg*、tun*、tap* 等）
    case "$iface_name" in
        lo|docker*|br-*|veth*|ppp*|wg*|tun*|tap*|sit*|ip6tnl*|gre*|gretap*|ip_vti*|erspan*) continue ;;
    esac
    # 检测物理网口：有 device 符号链接，或 type=1（以太网）且名字匹配 eth/en
    if [ -e "$iface/device" ]; then
        if echo "$iface_name" | grep -Eq '^eth|^en'; then
            ifnames="$ifnames $iface_name"
        fi
    elif [ "$(cat "$iface/type" 2>/dev/null)" = "1" ]; then
        # 备用检测：ARPPHRD_ETHER = 1，某些驱动不创建 device 符号链接
        if echo "$iface_name" | grep -Eq '^eth|^en'; then
            ifnames="$ifnames $iface_name"
            echo "  Fallback detection: $iface_name (type=1, no device symlink)" >>$LOGFILE
        fi
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames (count=$count)" >>$LOGFILE

# 板子型号特殊处理
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        ;;
    *)
        # 默认：按字母序第一个网口做 WAN，其余做 LAN
        # 注意：x86 设备网口顺序取决于内核枚举（通常 PCI 总线序），可能与物理面板标注不一致
        # 如果发现 WAN/LAN 颠倒，请在刷机后手动调整 /etc/config/network
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        ;;
esac
echo "WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
echo "  NOTE: If WAN/LAN assignment is reversed, manually edit /etc/config/network after boot." >>"$LOGFILE"

# ============================================================================
# 第5部分：网络接口配置
# ============================================================================
echo ">>> Configuring network interfaces..." >>$LOGFILE

if [ "$count" -eq 1 ]; then
    # ---- 单网口模式：DHCP ----
    echo "  Single-NIC mode: DHCP" >>$LOGFILE
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr 2>/dev/null
    uci delete network.lan.netmask 2>/dev/null
    uci delete network.lan.gateway 2>/dev/null
    uci delete network.lan.dns 2>/dev/null
    uci commit network

elif [ "$count" -gt 1 ]; then
    # ---- 多网口模式 ----
    echo "  Multi-NIC mode: WAN=$wan_ifname LAN=$lan_ifnames" >>$LOGFILE

    # 5.1 配置 WAN
    # 根据 PPPoE 开关决定协议：先判断避免重复设置
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"

    if [ "$enable_pppoe" = "yes" ]; then
        echo "  PPPoE mode enabled, setting WAN proto=pppoe" >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan.mtu='1492'
    else
        uci set network.wan.proto='dhcp'
        uci set network.wan.mtu="$WAN_MTU"
    fi

    # 5.2 配置 WAN6（IPv6 DHCPv6-PD，获取公网前缀）
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.reqaddress='try'
    uci set network.wan6.reqprefix="$PD_PREFIX_LEN"
    # 默认路由优先级：IPv4 优先（国内 CDN 兼容），IPv6 次之
    uci set network.wan6.defaultroute='1'
    uci set network.wan6.metric='512'

    # PPPoE 模式下，wan6 应绑定到 ppp 虚接口而非物理网口
    if [ "$enable_pppoe" = "yes" ]; then
        uci set network.wan6.device='@wan'
    fi

    # 5.3 配置 br-lan 网桥端口
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "  ERROR: cannot find device 'br-lan'" >>$LOGFILE
    else
        uci -q delete "network.$section.ports"
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "  br-lan ports: $lan_ifnames" >>$LOGFILE
    fi

    # 5.4 配置 LAN（静态 IPv4 + DHCPv6 分发）
    uci set network.lan.proto='static'
    uci set network.lan.netmask='255.255.255.0'
    # 启用 IPv6 前缀委派下发（让 LAN 设备获得公网 IPv6）
    uci set network.lan.ip6assign='64'
    # 同时也分配 ULA 地址
    uci set network.lan.ip6class='local'

    # 路由器管理 IP
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        uci set network.lan.ipaddr="$CUSTOM_IP"
        echo "  Custom router IP: $CUSTOM_IP" >>$LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "  Default router IP: 192.168.100.1" >>$LOGFILE
    fi

    uci commit network
fi

# ============================================================================
# 第6部分：DHCP/RA 配置（IPv6 地址分配）
# ============================================================================
echo ">>> Configuring DHCP/RA..." >>$LOGFILE

uci set dhcp.lan.start="$DHCP_START"
uci set dhcp.lan.limit="$DHCP_LIMIT"
uci set dhcp.lan.leasetime="$DHCP_LEASETIME"
# RA 服务器模式：让内网设备通过 SLAAC 获取公网 IPv6
uci set dhcp.lan.ra="$RA_MODE"
# RA 管理标志：1=DHCPv6 Stateful（可分配 DNS），同时 SLAAC 也能用
uci set dhcp.lan.ra_management="$RA_MANAGEMENT"
# DHCPv6 服务器模式
uci set dhcp.lan.dhcpv6='server'
# NDP 代理：让内网设备能互相发现
uci set dhcp.lan.ndp='hybrid'

uci commit dhcp

# ============================================================================
# 第7部分：服务访问配置
# ============================================================================
# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface 2>/dev/null

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# ============================================================================
# 第8部分：系统信息
# ============================================================================
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# ============================================================================
# 第9部分：advancedplus 修复
# ============================================================================
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "Fixed advancedplus zsh issue" >>$LOGFILE
fi

# ============================================================================
# 第10部分：quickfile nginx 配置
# ============================================================================
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
    echo "Fixed quickfile nginx config" >>$LOGFILE
fi

# ============================================================================
# 第11部分：硬件卸载优化（ethtool GRO）
# ============================================================================
echo ">>> Configuring ethtool GRO optimization..." >>$LOGFILE
cat > /etc/rc.local <<'RCLOCALEOF'
#!/bin/sh
# 硬件卸载优化：对所有物理网卡启用 UDP GRO 转发
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ethtool -K "$iface_name" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null
    fi
done
exit 0
RCLOCALEOF
chmod +x /etc/rc.local

# ============================================================================
# 第12部分：Docker 配置
# ============================================================================
if command -v dockerd >/dev/null 2>&1; then
    echo ">>> Configuring Docker..." >>$LOGFILE

    # 12.1 Dockerd 全局参数
    if uci -q get dockerd.globals >/dev/null 2>&1; then
        uci set dockerd.globals.iptables='0'
        uci set dockerd.globals.ip6tables='0'
        uci set dockerd.globals.log_level='warn'
        uci set dockerd.globals.data_root='/opt/docker/'
        uci add_list dockerd.globals.log_opt='max-size=10m'
        uci add_list dockerd.globals.log_opt='max-file=5'
        uci commit dockerd
        echo "  Dockerd: iptables off, data=/opt/docker/, log=10MBx5" >>$LOGFILE
    fi

    # 12.2 移除 Docker 默认 WAN 阻断规则
    if uci -q get dockerd.@firewall[0] >/dev/null 2>&1; then
        uci -q del_list dockerd.@firewall[0].blocked_interfaces='wan'
        uci commit dockerd
    fi

    # 12.3 Docker 防火墙规则（子网模式，覆盖所有 Docker 网段）
    FW_FILE="/etc/config/firewall"

    # 清理旧配置
    if uci -q get firewall.docker >/dev/null 2>&1; then
        uci delete firewall.docker
    fi
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci -q get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci -q get firewall.@forwarding[$idx].dest 2>/dev/null)
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            uci delete firewall.@forwarding[$idx]
        fi
    done
    uci commit firewall

    # 追加 Docker zone + 转发规则
    cat <<'DOCKEREOF' >>"$FW_FILE"

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
DOCKEREOF

    echo "  Docker firewall rules configured" >>$LOGFILE
else
    echo "Docker not detected, skipped." >>$LOGFILE
fi

# ============================================================================
# 第13部分：IPv6 内核参数加固
# ============================================================================
echo ">>> Hardening IPv6 kernel parameters..." >>$LOGFILE

cat > /etc/sysctl.d/99-ipv6-hardening.conf <<'SYSCTLEOF'
# IPv6 安全加固
# 接受 RA（路由器通告），但仅从默认网关
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
# 拒绝 ICMP 重定向（防路由劫持）
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
# 启用 IPv6 转发（网关必须）
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
# 启用反向路径过滤（防 IP 欺骗）
net.ipv6.conf.all.rp_filter=1
net.ipv6.conf.default.rp_filter=1
# 禁用自动配置（WAN 侧由 odhcp6c 管理，LAN 侧由 odhcpd 管理）
# 防止意外获取不期望的地址
net.ipv6.conf.all.autoconf=0
net.ipv6.conf.default.autoconf=0
SYSCTLEOF

echo "  IPv6 hardening config written to /etc/sysctl.d/99-ipv6-hardening.conf" >>$LOGFILE

# ============================================================================
# 第14部分：OpenClash IPv6 兼容提示
# ============================================================================
if [ -f /etc/init.d/openclash ] || [ -f /usr/share/openclash/openclash.sh ]; then
    echo ">>> OpenClash detected, configuring IPv6 compatibility..." >>$LOGFILE

    # 创建 OpenClash IPv6 兼容配置提示文件
    # 不直接修改 OpenClash 配置，而是提供配置指南
    cat > /etc/openclash/ipv6-compat-guide.txt <<'CLASHGUIDE'
# OpenClash 与 IPv6 兼容配置指南
# ==========================================
# 场景：双栈网关（公网IPv6 + CGNAT IPv4）
#
# 推荐配置：
# 1. OpenClash 全局设置 → 绕过中国大陆 IPv6：
#    - 勾选 "IPv6 流量代理"（如需代理 IPv6）
#    - 或 关闭 "IPv6 流量代理"（仅代理 IPv4，IPv6 直连）
#
# 2. 如果选择仅代理 IPv4（推荐，避免 IPv6 代理问题）：
#    - 关闭 OpenClash 的 IPv6 代理
#    - 在 DNS 设置中启用 "禁止 Dnsmasq 缓存 DNS"
#    - 在覆写设置中启用 "自定义上游 DNS 服务器"
#
# 3. 防火墙安全策略：
#    - 首次启动 WAN 入站为 ACCEPT（确保能访问 WebUI）
#    - 确认网络正常后，手动切换 WAN 入站为 REJECT
#    - 或刷机前设置 LOCKDOWN_AFTER_INIT="yes" 自动锁门
#    - 可在 LuCI → 网络 → 防火墙 中添加 Traffic Rule 按需暴露端口
#
# 4. IPv6 测试：
#    curl -6 https://ipv6.icanhazip.com
#    ping -6 google.com
CLASHGUIDE

    echo "  OpenClash IPv6 compatibility guide created" >>$LOGFILE
fi

# ============================================================================
# 第15部分：可选——初始化完成后自动锁门（守门员模式）
# ============================================================================
if [ "$LOCKDOWN_AFTER_INIT" = "yes" ]; then
    echo ">>> LOCKDOWN_AFTER_INIT=yes, switching WAN input to REJECT..." >>$LOGFILE

    # 切换 WAN zone 入站策略为 REJECT
    for i in $(seq 0 5); do
        name=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
        if [ "$name" = "wan" ]; then
            uci set firewall.@zone[$i].input='REJECT'
            break
        fi
    done
    uci commit firewall
    /etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null

    echo "  WAN input switched to REJECT. Only ICMPv6 + exposed ports are allowed." >>$LOGFILE
    echo "  To expose additional services, edit EXPOSED_PORTS in 99-custom.sh and reflash." >>$LOGFILE
    echo "  Or add Traffic Rules manually in LuCI -> Network -> Firewall." >>$LOGFILE
else
    echo ">>> LOCKDOWN_AFTER_INIT=no, WAN input remains ACCEPT." >>$LOGFILE
    echo "  After confirming network is working, manually switch WAN input to REJECT:" >>$LOGFILE
    echo "  LuCI -> 网络 -> 防火墙 -> WAN 区域 -> 入站数据 -> 拒绝 -> 保存并应用" >>$LOGFILE
fi

# ============================================================================
# 第16部分：替换 APK 软件源镜像为 USTC
# ============================================================================
echo ">>> Replacing APK repository mirrors with USTC..." >>$LOGFILE

DISTFEEDS_FILE="/etc/apk/repositories.d/distfeeds.list"
if [ -f "$DISTFEEDS_FILE" ]; then
    # 将 vsean.net 镜像替换为 USTC ImmortalWrt 镜像
    sed -i 's|https://mirrors\.vsean\.net/openwrt/|https://mirrors.ustc.edu.cn/immortalwrt/|g' "$DISTFEEDS_FILE"
    echo "  APK repositories updated to USTC mirror" >>$LOGFILE
else
    echo "  distfeeds.list not found, skipping APK mirror replacement" >>$LOGFILE
fi

echo "===== 99-custom.sh finished at $(date) =====" >>$LOGFILE
exit 0
