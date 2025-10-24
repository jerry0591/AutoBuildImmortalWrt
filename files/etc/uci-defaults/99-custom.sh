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

# 修改主机名
uci set system.@system[0].hostname='FastnetOS'
uci commit system
echo "Hostname set to FastnetOS" >>$LOGFILE
# 修改默认密码admin123
sed -i 's|^root:[^:]*:|root:$1$aJagm5zW$w9H7NvLdbx79MoJNk8Gnh/:|' /etc/shadow


# ===============================
# 设置默认 frpc 配置
# ===============================
FRPC_CONF="/etc/config/frpc"
LOGFILE="/var/log/init.log"


# 生成默认 frpc 配置
cat >"$FRPC_CONF" <<EOF
config init
        option stdout '1'
        option stderr '1'
        option user 'root'
        option group 'root'
        option respawn '1'

config conf 'common'
        option server_addr '45.126.122.23'
        option server_port '11401'
        option token 'ClpPViOvk7E0WIMv'
        option tls_enable 'false'
        option user '123'

config conf 'ssh'
        option type 'tcp'
        option local_ip '127.0.0.1'
        option local_port '22'
        option name 'ssh'
        option use_encryption 'false'
        option use_compression 'false'

config conf 'web'
        option name 'web'
        option type 'tcp'
        option use_encryption 'false'
        option use_compression 'false'
        option local_ip '127.0.0.1'
        option local_port '80'
EOF



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

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall
    # 追加新的 zone + forwarding 配置
    cat <<EOF >>"$FW_FILE"

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

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by jerry"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if opkg list-installed | grep -q '^luci-app-advancedplus '; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
fi

# ===============================
# 创建 /usr/bin/fix_frpc_user.sh 并设置自启动
# ===============================
cat > /usr/bin/fix_frpc_user.sh <<'EOF'
#!/bin/sh
# fix_frpc_user.sh — 启动后自动修正 frpc user 字段为 LAN MAC 地址

LOGFILE="/var/log/fix_frpc_user.log"
FRPC_CONF="/etc/config/frpc"

echo "[$(date)] fix_frpc_user.sh started" >>$LOGFILE

# 等待系统获取到 LAN 接口 MAC 地址
sleep 5

# 获取LAN接口名
LAN_IF=$(uci get network.lan.device 2>/dev/null || echo "br-lan")

# 尝试从LAN接口读取MAC地址
MAC_ADDR=$(cat /sys/class/net/$LAN_IF/address 2>/dev/null | tr -d ':')

if [ -z "$MAC_ADDR" ]; then
    echo "[$(date)] 无法获取 $LAN_IF 的MAC地址" >>$LOGFILE
    exit 1
fi

echo "[$(date)] 获取到MAC地址：$MAC_ADDR" >>$LOGFILE

# 更新 frpc 配置中的 user 字段
uci set frpc.common.user="$MAC_ADDR"
uci commit frpc
echo "[$(date)] 已更新 frpc.user=$MAC_ADDR" >>$LOGFILE

# 成功后删除 /etc/rc.local 中的自启动命令，避免重复执行
sed -i '\|/usr/bin/fix_frpc_user.sh &|d' /etc/rc.local
echo "[$(date)] 已删除 /etc/rc.local 中自启动命令" >>$LOGFILE

EOF

# 设置执行权限
chmod +x /usr/bin/fix_frpc_user.sh

# 写入 rc.local 自启动命令（exit 0 前）
sed -i '/^exit 0/i\/usr/bin/fix_frpc_user.sh &' /etc/rc.local

# 先清空 /etc/banner
> /etc/banner

# 然后写入新的 ASCII banner
cat > /etc/banner <<'EOF'
*************************************************************
▄   ▄▄   ▄▄   ▄      ▗▄  ▗▖ ▗▖▗▖ ▗▖  ▄▄        ▄▄  ▗▄▖ ▗▄ ▄▖
█   ██   ██   █      ▛█  ▝█ █▘▝█ █▘ █▀▀▌      █▀▀▌ █▀█ ▐█ █▌
▜▖█▗▛▜▖█▗▛▜▖█▗▛       █   █ █  █ █ ▐▛        ▐▛   ▐▌ ▐▌▐███▌
▐▌█▐▌▐▌█▐▌▐▌█▐▌       █   █ █  █ █ ▐▌        ▐▌   ▐▌ ▐▌▐▌█▐▌
▐█▀█▌▐█▀█▌▐█▀█▌       █   ▐█▌  ▐█▌ ▐▙        ▐▙   ▐▌ ▐▌▐▌▀▐▌
▐█ █▌▐█ █▌▐█ █▌  █  ▗▄█▄▖ ▐█▌  ▐█▌  █▄▄▌  █   █▄▄▌ █▄█ ▐▌ ▐▌
▝▀ ▀▘▝▀ ▀▘▝▀ ▀▘  ▀  ▝▀▀▀▘ ▝▀▘  ▝▀▘   ▀▀   ▀    ▀▀  ▝▀▘ ▝▘ ▝▘
*************************************************************
 -----------------------------------------------------
 FastnetOS 23.05 jerry@1vvc.com 202510
 -----------------------------------------------------
EOF

# 修改 /etc/config/luci 中的 diag 部分
sed -i "s|option dns 'immortalwrt.org'|option dns 'tiktok.com'|" /etc/config/luci
sed -i "s|option ping 'immortalwrt.org'|option ping 'baidu.com'|" /etc/config/luci
sed -i "s|option route 'immortalwrt.org'|option route 'tiktok.com'|" /etc/config/luci


exit 0
