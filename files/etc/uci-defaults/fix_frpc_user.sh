#!/bin/sh
FRPC_CONF="/etc/config/frpc"
LOGFILE="/var/log/init.log"

# 延迟几秒，等待网络接口就绪
sleep 10

# 检测 LAN 接口（优先 br-lan, eth0, eth1，否则取第一个非 lo）
if [ -d /sys/class/net/br-lan ]; then
    LAN_IF="br-lan"
elif [ -d /sys/class/net/eth0 ]; then
    LAN_IF="eth0"
elif [ -d /sys/class/net/eth1 ]; then
    LAN_IF="eth1"
else
    LAN_IF=$(ls /sys/class/net | grep -v lo | head -n 1)
fi

# 获取 MAC 地址（去掉冒号）
if [ -n "$LAN_IF" ] && [ -f "/sys/class/net/$LAN_IF/address" ]; then
    LAN_MAC=$(cat /sys/class/net/$LAN_IF/address | tr -d ':')
else
    LAN_MAC="000000000000"
fi

# 如果 frpc 配置不存在，创建一个最小骨架以便替换行存在
if [ ! -f "$FRPC_CONF" ]; then
    cat >"$FRPC_CONF" <<'EOF'
config init
        option stdout '1'
        option stderr '1'
        option user 'root'
        option group 'root'
        option respawn '1'

config conf 'common'
        option server_addr ''
        option server_port ''
        option token ''
        option tls_enable 'false'
        option user '123'
EOF
fi

# 修改 frpc 配置中的 user 字段（仅替换第一处出现的 option user）
# 使用 sed 精准替换以防其它位置被误改
# 若不存在 option user 行，则追加一行到 common 段（简单实现）
if grep -q "option user" "$FRPC_CONF"; then
    # 只替换第一个匹配到的 option user 行
    # 使用 awk 保证只替换第一个出现的 "option user"
    awk -v mac="$LAN_MAC" '{
        if (!done && $1=="option" && $2=="user") {
            print "        option user \047" mac "\047"
            done=1
        } else {
            print $0
        }
    }' "$FRPC_CONF" >"${FRPC_CONF}.tmp" && mv "${FRPC_CONF}.tmp" "$FRPC_CONF"
else
    # 找到 common 段并在其后追加 option user 行；如果找不到 common 则追加到文件末尾
    if grep -q "^config conf 'common'" "$FRPC_CONF"; then
        awk -v mac="$LAN_MAC" '{
            print $0
            if ($0 ~ /^config conf '"'"'common'"'"'/) { add=1; next }
            if (add && /^[[:space:]]*$/) { print "        option user \047" mac "\047"; add=0 }
        }' "$FRPC_CONF" >"${FRPC_CONF}.tmp" && mv "${FRPC_CONF}.tmp" "$FRPC_CONF"
        # 若上面未成功（如文件末尾无空行），追加到文件末尾
        if ! grep -q "option user" "$FRPC_CONF"; then
            sed -i "/^config conf 'common'/,/$/a\        option user '"$LAN_MAC" "$FRPC_CONF"
        fi
    else
        echo "        option user '$LAN_MAC'" >>"$FRPC_CONF"
    fi
fi

echo "[$(date '+%F %T')] Updated frpc user=$LAN_MAC from $LAN_IF" >>"$LOGFILE"

# --- 从 /etc/rc.local 中移除启动调用，避免重复运行 ---
RCLOCAL="/etc/rc.local"
if [ -f "$RCLOCAL" ]; then
    # 删除包含 /usr/bin/fix_frpc_user.sh 的行（无论是否带 &）
    # 使用 grep -v 写回文件，保持文件末尾的 exit 0
    grep -v "/usr/bin/fix_frpc_user.sh" "$RCLOCAL" >"${RCLOCAL}.tmp" && \
        mv "${RCLOCAL}.tmp" "$RCLOCAL" && \
        echo "[$(date '+%F %T')] Removed fix_frpc_user invocation from $RCLOCAL" >>"$LOGFILE"

    # 确保 /etc/rc.local 以 exit 0 结尾（OpenWrt 标准）
    if ! tail -n 1 "$RCLOCAL" | grep -q "^exit 0"; then
        echo "exit 0" >> "$RCLOCAL"
    fi

    # 确保可执行
    chmod +x "$RCLOCAL"
else
    echo "[$(date '+%F %T')] $RCLOCAL not found, skipping removal." >>"$LOGFILE"
fi

exit 0
