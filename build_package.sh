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
    # Create a basic clientstatus.sh
    cat > "${DEST}/clientstatus.sh" << 'EOF'
#!/bin/sh
# clientstatus main script

CLIENTSTATUS_FILE="/tmp/clientstatus"
REFRESH_INTERVAL=30

log() {
    logger -t "clientstatus" "$1"
}

scan_clients() {
    # Scan ARP table and DHCP leases
    > "$CLIENTSTATUS_FILE"
    
    # Read ARP table
    while read -r line; do
        set -- $line
        if [ $# -ge 6 ]; then
            ip="$1"
            mac="$4"
            iface="$6"
            echo "CLIENT|$mac|$ip|$iface|unknown|0|0|0" >> "$CLIENTSTATUS_FILE"
        fi
    done < /proc/net/arp
    
    # Update with DHCP info
    if [ -f /tmp/dhcp.leases ]; then
        while read -r line; do
            set -- $line
            if [ $# -ge 4 ]; then
                mac="$2"
                ip="$3"
                hostname="$4"
                # Update hostname in clientstatus file
                sed -i "s/CLIENT|$mac|[^|]*|[^|]*|[^|]*/CLIENT|$mac|$ip|br-lan|$hostname/" "$CLIENTSTATUS_FILE"
            fi
        done < /tmp/dhcp.leases
    fi
}

main_loop() {
    log "clientstatus started"
    while true; do
        scan_clients
        sleep "$REFRESH_INTERVAL"
    done
}

# Main
main_loop
EOF
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
