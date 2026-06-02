#!/bin/bash
# Build script for luci-app-clientstatus_package.tar.gz

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_NAME="luci-app-clientstatus_package"
BUILD_DIR="/tmp/${PKG_NAME}_build"
OUTPUT_FILE="${SCRIPT_DIR}/${PKG_NAME}.tar.gz"

echo "== 清理旧构建目录..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/${PKG_NAME}"

echo "== 复制文件到构建目录..."
DEST="${BUILD_DIR}/${PKG_NAME}"

# 1. Controller
cp "${SCRIPT_DIR}/luci-app-clientstatus/luasrc/controller/clientstatus.lua" \
   "${DEST}/clientstatus.lua"

# 2. View
cp "${SCRIPT_DIR}/luci-app-clientstatus/luasrc/view/clientstatus.htm" \
   "${DEST}/clientstatus.htm"

# 3. Settings (CBI model)
cp "${SCRIPT_DIR}/luci-app-clientstatus/luasrc/model/cbi/clientstatus/settings.lua" \
   "${DEST}/settings.lua"

# 4. Config
cp "${SCRIPT_DIR}/luci-app-clientstatus/root/etc/config/clientstatus" \
   "${DEST}/clientstatus.conf"

# 5. Init script (from clientstatus directory)
if [ -f "${SCRIPT_DIR}/clientstatus/files/clientstatus.init" ]; then
    cp "${SCRIPT_DIR}/clientstatus/files/clientstatus.init" \
       "${DEST}/clientstatus.init"
elif [ -f "${SCRIPT_DIR}/clientstatus/openwrt/files/clientstatus.init" ]; then
    cp "${SCRIPT_DIR}/clientstatus/openwrt/files/clientstatus.init" \
       "${DEST}/clientstatus.init"
else
    # Create a basic init script
    cat > "${DEST}/clientstatus.init" << 'EOF'
#!/bin/sh /etc/rc.common
# clientstatus init script

START=99
STOP=10

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/clientstatus.sh
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    killall clientstatus.sh 2>/dev/null || true
}
EOF
fi

# 6. Main script (clientstatus.sh)
if [ -f "${SCRIPT_DIR}/clientstatus/files/clientstatus.sh" ]; then
    cp "${SCRIPT_DIR}/clientstatus/files/clientstatus.sh" \
       "${DEST}/clientstatus.sh"
elif [ -f "${SCRIPT_DIR}/clientstatus/openwrt/files/clientstatus.sh" ]; then
    cp "${SCRIPT_DIR}/clientstatus/openwrt/files/clientstatus.sh" \
       "${DEST}/clientstatus.sh"
else
    # Create a clientstatus.sh that outputs the same format as the C daemon
    cat > "${DEST}/clientstatus.sh" << 'SHELLEOF'
#!/bin/sh
# clientstatus shell daemon — drop-in replacement for clientstatus.c
# Generates /tmp/clientstatus in the same fixed-width format

CLIENTSTATUS_FILE="/tmp/clientstatus"
STATE_FILE="/tmp/clientstatus.state"
PID_FILE="/tmp/clientstatus.pid"
REFRESH_INTERVAL=30

# Read UCI config
INTERVAL=$(uci -q get clientstatus.global.refresh_interval 2>/dev/null)
[ -z "$INTERVAL" ] || [ "$INTERVAL" -lt 5 ] 2>/dev/null && INTERVAL=30
LAN_IFACE=$(uci -q get clientstatus.global.lan_iface 2>/dev/null)
[ -z "$LAN_IFACE" ] && LAN_IFACE="br-lan"

log() {
    logger -t "clientstatus" "$1"
}

# Write PID
echo $$ > "$PID_FILE"

# Signal handler for USR1 (force refresh)
trap '' USR1

format_duration() {
    local secs=$1
    local d=$((secs / 86400))
    local h=$(( (secs % 86400) / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if [ "$d" -gt 0 ]; then
        echo "${d}d${h}h"
    elif [ "$h" -gt 0 ]; then
        echo "${h}h${m}m"
    elif [ "$m" -gt 0 ]; then
        echo "${m}m${s}s"
    else
        echo "${s}s"
    fi
}

scan_clients() {
    local now=$(date +%s)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local tmpfile="${CLIENTSTATUS_FILE}.tmp"

    {
        echo "# Client Status — ${timestamp}"
        echo "# Refresh interval: ${INTERVAL}s  |  LAN: ${LAN_IFACE}"
        echo "# WiFi: disabled"
        echo "#"
        printf "# %-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n" "MAC" "STATUS" "DURATION" "IPv4" "HOSTNAME" "CNT"
        printf "# %-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n" "─────────────────" "────────" "──────────" "────────────────" "────────────────────" "──────────"

        # Read ARP table (skip header line)
        tail -n +2 /proc/net/arp 2>/dev/null | while read -r _ip _type _flags mac _mask _device; do
            # Skip incomplete or zero MACs
            [ -z "$mac" ] && continue
            mac=$(echo "$mac" | tr 'a-f' 'A-F')
            [ "$mac" = "00:00:00:00:00:00" ] && continue
            # Validate MAC format
            echo "$mac" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' || continue

            ip="$_ip"
            device="$_device"

            # Get hostname from DHCP leases
            hostname=""
            if [ -f /tmp/dhcp.leases ]; then
                dhcp_host=$(grep -i "$mac" /tmp/dhcp.leases 2>/dev/null | head -1 | awk '{print $4}')
                if [ -n "$dhcp_host" ] && [ "$dhcp_host" != "*" ]; then
                    hostname="$dhcp_host"
                fi
            fi
            [ -z "$hostname" ] && hostname="unknown"

            # Determine connection type
            conn="Ethernet"
            if [ "$device" != "$LAN_IFACE" ] && [ -n "$device" ]; then
                conn="$device"
            fi

            # Check if online via ping (quick check)
            status="online"
            ping -c1 -W1 "$ip" >/dev/null 2>&1 || status="offline"

            # Get duration from state file (preserve first seen time)
            duration="0s"
            first_seen="$now"
            if [ -f "$STATE_FILE" ]; then
                old_record=$(grep "^${mac}|" "$STATE_FILE" 2>/dev/null | head -1)
                if [ -n "$old_record" ]; then
                    old_since=$(echo "$old_record" | cut -d'|' -f3)
                    if [ -n "$old_since" ] && [ "$old_since" -gt 0 ] 2>/dev/null; then
                        first_seen="$old_since"
                        duration=$(format_duration $(( now - first_seen )))
                    fi
                fi
            fi

            # Format: fixed-width fields matching C daemon output
            printf "%-17s  %-8s  %-10s  %-16s  %-20s  %-10s\n" \
                "$mac" "$status" "$duration" "$ip" "$hostname" "$conn"
        done
    } > "$tmpfile"

    mv -f "$tmpfile" "$CLIENTSTATUS_FILE"

    # Update state file with preserved first_seen timestamps
    {
        tail -n +8 "${CLIENTSTATUS_FILE}" 2>/dev/null | while read -r mac status duration ip hostname conn; do
            [ -z "$mac" ] && continue
            # Get existing first_seen from old state file
            first_seen="$now"
            if [ -f "$STATE_FILE" ]; then
                old_since=$(grep "^${mac}|" "$STATE_FILE" 2>/dev/null | head -1 | cut -d'|' -f3)
                [ -n "$old_since" ] && [ "$old_since" -gt 0 ] 2>/dev/null && first_seen="$old_since"
            fi
            echo "$mac|online|${first_seen}|${ip}|${hostname}|Ethernet|99|0"
        done
    } > "${STATE_FILE}.tmp"
    mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
}

main_loop() {
    log "clientstatus.sh started (interval=${INTERVAL}s, lan=${LAN_IFACE})"
    while true; do
        scan_clients
        sleep "$INTERVAL"
    done
}

# Main
main_loop
SHELLEOF
fi

# 7. Language file (compile from .po)
if command -v po2lmo >/dev/null 2>&1; then
    echo "== 编译语言文件..."
    po2lmo "${SCRIPT_DIR}/luci-app-clientstatus/po/zh_Hans/clientstatus.po" \
           "${BUILD_DIR}/clientstatus.zh-cn.lmo"
else
    echo "== 警告: po2lmo 未安装，复制现有 lmo 文件..."
    if [ -f "${SCRIPT_DIR}/luci-app-clientstatus_package/clientstatus.zh-cn.lmo" ]; then
        cp "${SCRIPT_DIR}/luci-app-clientstatus_package/clientstatus.zh-cn.lmo" \
           "${DEST}/clientstatus.zh-cn.lmo"
    else
        touch "${DEST}/clientstatus.zh-cn.lmo"
    fi
fi

# 8. Install script
cat > "${DEST}/install.sh" << 'EOF'
#!/bin/sh
cd "$(dirname "$0")"

echo "请选择操作："
echo "1) 安装"
echo "2) 卸载"
printf "请输入 [1/2]: "

read choice </dev/tty

case "$choice" in
    1)
        echo "== 安装..."

        mkdir -p /usr/lib/lua/luci/model/cbi/clientstatus
        mkdir -p /usr/lib/lua/luci/controller
        mkdir -p /usr/lib/lua/luci/view
        mkdir -p /usr/lib/lua/luci/i18n
        mkdir -p /usr/bin
        mkdir -p /etc/init.d
        mkdir -p /etc/config

        mv -f settings.lua           /usr/lib/lua/luci/model/cbi/clientstatus/
        mv -f clientstatus.lua      /usr/lib/lua/luci/controller/
        mv -f clientstatus.htm      /usr/lib/lua/luci/view/
        mv -f clientstatus.zh-cn.lmo /usr/lib/lua/luci/i18n/
        mv -f clientstatus.sh       /usr/bin/
        mv -f clientstatus.init     /etc/init.d/clientstatus
        mv -f clientstatus.conf     /etc/config/clientstatus

        chmod +x /usr/bin/clientstatus.sh
        chmod +x /etc/init.d/clientstatus

        chown -R root:root \
            /usr/lib/lua/luci \
            /usr/bin/clientstatus.sh \
            /etc/init.d/clientstatus \
            /etc/config/clientstatus

        /etc/init.d/clientstatus enable
        /etc/init.d/clientstatus start
        [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd restart

        echo "== 安装完成 ✅ =="
        ;;

    2)
        echo "== 卸载..."

        /etc/init.d/clientstatus stop 2>/dev/null || true
        /etc/init.d/clientstatus disable 2>/dev/null || true

        rm -f /usr/lib/lua/luci/model/cbi/clientstatus/settings.lua
        rm -f /usr/lib/lua/luci/controller/clientstatus.lua
        rm -f /usr/lib/lua/luci/view/clientstatus.htm
        rm -f /usr/lib/lua/luci/i18n/clientstatus.zh-cn.lmo
        rm -f /usr/bin/clientstatus.sh
        rm -f /etc/init.d/clientstatus
        rm -f /etc/config/clientstatus

        echo "== 卸载完成 ✅ =="
        ;;

    *)
        echo "无效选择"
        exit 1
        ;;
esac
EOF

echo "== 设置权限..."
chmod +x "${DEST}/install.sh"
chmod +x "${DEST}/clientstatus.sh"
chmod +x "${DEST}/clientstatus.init"

echo "== 创建 tar.gz 包..."
cd "${BUILD_DIR}"
tar -czf "${OUTPUT_FILE}" "${PKG_NAME}/"

echo "== 清理构建目录..."
cd "${SCRIPT_DIR}"
rm -rf "${BUILD_DIR}"

echo "== 打包完成 ✅ =="
echo "输出文件: ${OUTPUT_FILE}"
echo "文件大小: $(du -h "${OUTPUT_FILE}" | cut -f1)"
echo ""
echo "包内容:"
tar -tzf "${OUTPUT_FILE}"
