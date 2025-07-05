#!/bin/bash

#================================================================
#   描述: WireGuard 极简稳定版脚本 (纯IPv4)
#   版本: 4.2 (支持生成 Base64 QR 链接)
#   作者: Gemini
#================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- 脚本配置 (纯IPv4) ---
SERVER_WG_NIC="wg0"
SERVER_CONFIG_DIR="/etc/wireguard"
CLIENT_CONFIG_DIR="${SERVER_CONFIG_DIR}/clients"
SERVER_CONFIG_FILE="${SERVER_CONFIG_DIR}/${SERVER_WG_NIC}.conf"
SERVER_WG_IPV4="10.88.88.1"
SERVER_PORT=51820
CLIENT_DNS="8.8.8.8, 1.1.1.1"

# --- 权限检查 ---
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}错误：此脚本需要 root 权限运行。${NC}"
    exit 1
fi

# --- 功能函数 ---

detect_server_info() {
    SERVER_NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    if [[ -z "$SERVER_NIC" ]]; then
        echo -e "${RED}错误：无法检测到网络接口。${NC}"; exit 1
    fi

    echo -e "${YELLOW}正在检测公网IP...${NC}"
    SERVER_PUB_IP=$(curl -s4 https://api.ipify.org || curl -s4 https://ifconfig.me)
    if [[ -z "$SERVER_PUB_IP" ]]; then
        read -p "无法自动检测公网IPv4，请手动输入: " SERVER_PUB_IP
        if [[ -z "$SERVER_PUB_IP" ]]; then echo -e "${RED}未提供公网IP。退出。${NC}"; exit 1; fi
    fi
}

install_wireguard() {
    echo -e "${GREEN}=== WireGuard 首次安装程序 (纯IPv4模式) ===${NC}"
    apt-get update
    apt-get install -y wireguard qrencode curl iptables-persistent

    mkdir -p "$SERVER_CONFIG_DIR" "$CLIENT_CONFIG_DIR"
    chmod 700 "$SERVER_CONFIG_DIR" "$CLIENT_CONFIG_DIR"

    wg genkey | tee "${SERVER_CONFIG_DIR}/server_private.key" | wg pubkey > "${SERVER_CONFIG_DIR}/server_public.key"
    SERVER_PRIVATE_KEY=$(cat "${SERVER_CONFIG_DIR}/server_private.key")

    echo "正在创建 wg0.conf..."
    cat > "$SERVER_CONFIG_FILE" << EOF_WG_CONF
[Interface]
Address = ${SERVER_WG_IPV4}/24
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${SERVER_NIC} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${SERVER_NIC} -j MASQUERADE
EOF_WG_CONF

    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    systemctl enable wg-quick@${SERVER_WG_NIC}
    systemctl start wg-quick@${SERVER_WG_NIC}

    sleep 2
    if systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"; then
        echo -e "${GREEN}✓ WireGuard 服务安装并启动成功！${NC}"
    else
        echo -e "${RED}错误：WireGuard 服务启动失败！${NC}"
        echo -e "${YELLOW}请运行以下命令查看详细的错误日志:${NC}"
        echo "journalctl -u wg-quick@wg0 --no-pager | tail -n 20"
        exit 1
    fi
}

add_client() {
    if [[ -z "$SERVER_PUB_IP" ]]; then
        detect_server_info
    fi

    echo -e "\n${GREEN}=== 添加新客户端 ===${NC}"
    read -p "请输入客户端名称 (例如: myphone): " CLIENT_NAME
    if [[ -z "$CLIENT_NAME" ]]; then echo -e "${RED}客户端名称不能为空。${NC}"; return; fi
    if [[ -f "${CLIENT_CONFIG_DIR}/${CLIENT_NAME}.conf" ]]; then echo -e "${RED}客户端 '${CLIENT_NAME}' 已存在。${NC}"; return; fi

    LAST_IP_OCTET=$(grep AllowedIPs "$SERVER_CONFIG_FILE" | awk -F '[ ./]' '{print $6}' | sort -n | tail -1)
    [[ -z "$LAST_IP_OCTET" ]] && LAST_IP_OCTET=1
    NEW_CLIENT_IP_OCTET=$((LAST_IP_OCTET + 1))
    CLIENT_WG_IPV4="10.88.88.${NEW_CLIENT_IP_OCTET}"

    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
    SERVER_PUBLIC_KEY=$(cat "${SERVER_CONFIG_DIR}/server_public.key")

    cat > "${CLIENT_CONFIG_DIR}/${CLIENT_NAME}.conf" << EOF_CLIENT_CONF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUB_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF_CLIENT_CONF

    echo -e "\n# Client: ${CLIENT_NAME}" >> "$SERVER_CONFIG_FILE"
    echo "[Peer]" >> "$SERVER_CONFIG_FILE"
    echo "PublicKey = ${CLIENT_PUBLIC_KEY}" >> "$SERVER_CONFIG_FILE"
    echo "AllowedIPs = ${CLIENT_WG_IPV4}/32" >> "$SERVER_CONFIG_FILE"

    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

    echo "--------------------------------------------------"
    echo -e "${GREEN}✓ 客户端 '${CLIENT_NAME}' 添加成功！${NC}"
    qrencode -t ansiutf8 < "${CLIENT_CONFIG_DIR}/${CLIENT_NAME}.conf"

    # 可选生成 Base64 编码配置链接
    BASE64_STRING=$(base64 -w 0 "${CLIENT_CONFIG_DIR}/${CLIENT_NAME}.conf")
    echo "--------------------------------------------------"
    echo -e "${YELLOW}Base64 链接（适合 Windows 等无法扫码场景）:${NC}"
    echo "data:application/wireguard-config;base64,${BASE64_STRING}"
    echo "--------------------------------------------------"
    echo -e "配置文件保存在: ${YELLOW}${CLIENT_CONFIG_DIR}/${CLIENT_NAME}.conf${NC}"
}

delete_client() {
    echo -e "\n${GREEN}=== 删除客户端 ===${NC}"
    mapfile -t client_files < <(ls -1 "${CLIENT_CONFIG_DIR}"/*.conf 2>/dev/null)
    if [ ${#client_files[@]} -eq 0 ]; then echo -e "${YELLOW}没有任何客户端可供删除。${NC}"; return; fi

    local i=1
    for file in "${client_files[@]}"; do
        echo " $i) $(basename "$file" .conf)"
        ((i++))
    done

    local choice
    read -p "请输入您想删除的客户端编号: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#client_files[@]} ]; then
        echo -e "${RED}无效的选择。${NC}"; return
    fi

    local selected_file="${client_files[$((choice-1))]}"
    local client_name=$(basename "$selected_file" .conf)

    read -p "您确定要删除客户端 '${client_name}' 吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "操作已取消。" && return

    sed -i.bak "/# Client: ${client_name}/, /AllowedIPs/d" "$SERVER_CONFIG_FILE"
    rm -f "$selected_file"

    wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
    echo -e "${GREEN}✓ 客户端 '${client_name}' 已成功删除。${NC}"
}

uninstall_wireguard() {
    read -p "您确定要卸载 WireGuard 吗？(y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "操作已取消。" && return

    systemctl stop wg-quick@wg0 2>/dev/null
    systemctl disable wg-quick@wg0 2>/dev/null
    apt-get purge -y wireguard wireguard-tools
    rm -rf "$SERVER_CONFIG_DIR"
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}✓ WireGuard 已成功卸载。${NC}"
    echo -e "${YELLOW}提示: 可运行 'sudo apt autoremove' 清理依赖。${NC}"
}

main_menu() {
    [[ ! -f "$SERVER_CONFIG_FILE" ]] && detect_server_info && install_wireguard
    [[ -z "$SERVER_PUB_IP" ]] && detect_server_info

    while true; do
        echo -e "\n${GREEN}WireGuard 极简稳定版 (v4.2)${NC}"
        echo "--------------------------------"
        echo " 1. 添加客户端"
        echo " 2. 删除客户端"
        echo " 3. 查看连接状态"
        echo " 4. 卸载 WireGuard"
        echo " 5. 退出"
        echo "--------------------------------"
        read -p "请输入您的选择 [1-5]: " choice
        case $choice in
            1) add_client ;;
            2) delete_client ;;
            3) wg show wg0 2>/dev/null || echo "WireGuard 服务未运行" ;;
            4) uninstall_wireguard ;;
            5) exit 0 ;;
            *) echo -e "${RED}无效选择。${NC}" ;;
        esac
    done
}

main_menu
