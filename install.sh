#!/bin/bash

# 将 clash 安装为系统级 systemd service（需要 root 权限）
# 流程：读取 .env → 下载订阅 → 生成 conf/config.yaml → 注册并启动 systemd service
#
# 用法:
#   sudo bash install.sh            # 安装（首次或更新订阅配置后重装）
#   sudo bash install.sh --uninstall # 卸载服务

set -e

SERVICE_NAME="clash"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
SERVICE_FILE="${SYSTEMD_SYSTEM_DIR}/${SERVICE_NAME}.service"
CONF_DIR="${SCRIPT_DIR}/conf"
TEMP_DIR="${SCRIPT_DIR}/temp"
LOG_DIR="${SCRIPT_DIR}/logs"
DASHBOARD_DIR="${SCRIPT_DIR}/dashboard/public"

# ==================== 工具函数 ====================

info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "系统级 service 安装需要 root 权限，请使用: sudo bash install.sh"
    fi
}

# 检测 CPU 架构，输出对应的二进制文件路径
detect_binary() {
    local arch
    arch=$(uname -m 2>/dev/null || arch 2>/dev/null)
    case "$arch" in
        x86_64|amd64)   echo "${SCRIPT_DIR}/bin/clash-linux-amd64" ;;
        aarch64|arm64)  echo "${SCRIPT_DIR}/bin/clash-linux-arm64" ;;
        armv7*)         echo "${SCRIPT_DIR}/bin/clash-linux-armv7" ;;
        *)              error "不支持的 CPU 架构: $arch" ;;
    esac
}

# ==================== 卸载 ====================

uninstall() {
    check_root
    info "正在卸载 ${SERVICE_NAME} 系统服务..."
    systemctl stop    "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    info "卸载完成。"
    exit 0
}

# ==================== 读取 .env ====================

load_env() {
    local env_file="${SCRIPT_DIR}/.env"
    [[ -f "$env_file" ]] || error ".env 文件不存在: ${env_file}，请参考 .env.bak 创建。"
    # shellcheck source=/dev/null
    source "$env_file"
    URL=${CLASH_URL:?".env 中未设置 CLASH_URL，请填写订阅地址"}
    Secret=${CLASH_SECRET:-$(openssl rand -hex 32)}
    info "订阅地址已加载。"
}

# ==================== 下载订阅并生成配置 ====================

download_subscription() {
    info "正在检测订阅地址可达性..."
    # 临时清除代理环境变量，避免使用旧代理下载
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY

    if ! curl -o /dev/null -L -k -sS --retry 3 -m 15 --connect-timeout 10 \
              -w "%{http_code}" "$URL" | grep -qE '^[23][0-9]{2}$'; then
        error "订阅地址不可访问: ${URL}"
    fi
    info "订阅地址可访问。"

    info "正在下载订阅配置..."
    mkdir -p "$TEMP_DIR"
    if ! curl -L -k -sS --retry 5 -m 30 -o "${TEMP_DIR}/clash.yaml" "$URL"; then
        # curl 失败，回退到 wget
        warn "curl 下载失败，尝试 wget..."
        local success=0
        for i in {1..5}; do
            if wget -q --no-check-certificate -O "${TEMP_DIR}/clash.yaml" "$URL"; then
                success=1
                break
            fi
        done
        [[ $success -eq 1 ]] || error "订阅下载失败，请检查网络或订阅地址。"
    fi
    info "订阅下载成功。"
}

convert_subscription() {
    local arch
    arch=$(uname -m 2>/dev/null)

    cp -a "${TEMP_DIR}/clash.yaml" "${TEMP_DIR}/clash_config.yaml"

    # 仅 x86_64 / arm64 支持格式检测与转换
    if [[ "$arch" =~ x86_64|amd64|aarch64|arm64 ]]; then
        info "正在检测订阅格式..."
        # 导出供 clash_profile_conversion.sh 使用的变量
        export Server_Dir="$SCRIPT_DIR"
        export CpuArch="$arch"
        if ! bash "${SCRIPT_DIR}/scripts/clash_profile_conversion.sh"; then
            error "订阅格式转换失败，请检查订阅地址内容是否有效。"
        fi
        sleep 1
    else
        warn "当前架构 ($arch) 不支持订阅格式自动转换，跳过检测。"
    fi
}

build_config() {
    info "正在生成 conf/config.yaml..."
    mkdir -p "$CONF_DIR"

    # 提取代理相关部分，过滤掉模板已有的全局字段
    sed -n '/^proxies:/,$p' "${TEMP_DIR}/clash_config.yaml" \
        | sed \
            -e '/^port:/d' \
            -e '/^socks-port:/d' \
            -e '/^redir-port:/d' \
            -e '/^allow-lan:/d' \
            -e '/^mode:/d' \
            -e '/^log-level:/d' \
            -e '/^external-controller:/d' \
            -e '/^secret:/d' \
        > "${TEMP_DIR}/proxy.txt"

    # 合并模板 + 代理配置
    cat "${TEMP_DIR}/templete_config.yaml" > "${TEMP_DIR}/config.yaml"
    cat "${TEMP_DIR}/proxy.txt"           >> "${TEMP_DIR}/config.yaml"
    cp  "${TEMP_DIR}/config.yaml"            "${CONF_DIR}/config.yaml"

    # 注入 Dashboard 路径和 Secret
    sed -ri "s|^# external-ui:.*|external-ui: ${DASHBOARD_DIR}|g" "${CONF_DIR}/config.yaml"
    sed -r  -i "/^secret: /s|(secret: ).*|\1${Secret}|g"           "${CONF_DIR}/config.yaml"

    info "配置文件生成完成: ${CONF_DIR}/config.yaml"
    info "Dashboard Secret: ${Secret}"
}

# ==================== 注册 systemd service ====================

register_service() {
    local binary
    binary=$(detect_binary)

    [[ -f "$binary" ]] || error "二进制文件不存在: $binary"
    chmod +x "$binary"
    mkdir -p "$LOG_DIR"

    # 用实际路径替换 service 模板中的占位符
    sed \
        -e "s|CLASH_BINARY|${binary}|g" \
        -e "s|CONF_DIR|${CONF_DIR}|g" \
        -e "s|LOG_DIR|${LOG_DIR}|g" \
        "${SCRIPT_DIR}/clash.service" > "${SERVICE_FILE}"

    info "已写入 service 文件: ${SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"

    # 若服务已在运行则 reload，否则 start
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        systemctl reload "${SERVICE_NAME}.service"
        info "服务已重载配置。"
    else
        systemctl start "${SERVICE_NAME}.service"
        sleep 2
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            info "服务启动成功！"
        else
            warn "服务未正常启动，请查看日志："
            warn "  journalctl -u ${SERVICE_NAME}.service -n 30"
            warn "  或查看: ${LOG_DIR}/clash.log"
            exit 1
        fi
    fi
}

# ==================== 写入代理环境变量函数 ====================

write_proxy_env() {
    cat > /etc/profile.d/clash.sh << 'EOF'
# 开启系统代理
open_proxy() {
    export http_proxy=http://127.0.0.1:7890
    export https_proxy=http://127.0.0.1:7890
    export no_proxy=127.0.0.1,localhost
    export HTTP_PROXY=http://127.0.0.1:7890
    export HTTPS_PROXY=http://127.0.0.1:7890
    export NO_PROXY=127.0.0.1,localhost
    echo -e "\033[32m[√] 已开启代理\033[0m"
}

# 关闭系统代理
close_proxy() {
    unset http_proxy https_proxy no_proxy
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY
    echo -e "\033[31m[×] 已关闭代理\033[0m"
}
EOF
    info "代理环境变量函数已写入 /etc/profile.d/clash.sh"
}

# ==================== 安装主流程 ====================

install() {
    check_root
    load_env
    download_subscription
    convert_subscription
    build_config
    register_service
    write_proxy_env

    echo ""
    echo "  Clash Dashboard : http://<ip>:9090/ui"
    echo "  Secret          : ${Secret}"
    echo ""
    echo "  常用命令："
    echo "    启动        : systemctl start ${SERVICE_NAME}"
    echo "    停止        : systemctl stop ${SERVICE_NAME}"
    echo "    重载配置    : systemctl reload ${SERVICE_NAME}"
    echo "    查看状态    : systemctl status ${SERVICE_NAME}"
    echo "    查看日志    : journalctl -u ${SERVICE_NAME} -f"
    echo "    卸载服务    : sudo bash install.sh --uninstall"
    echo ""
    echo "  加载代理函数（新终端自动生效，当前终端执行）:"
    echo "    source /etc/profile.d/clash.sh"
    echo "    open_proxy    # 开启代理"
    echo "    close_proxy   # 关闭代理"
    echo ""
}

# ==================== 入口 ====================

case "${1:-}" in
    --uninstall|-u) uninstall ;;
    *)              install   ;;
esac
