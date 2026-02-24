#!/bin/bash

# 将 clash 安装为当前用户的 systemd user service
# 用法: bash install.sh [--uninstall]

set -e

SERVICE_NAME="clash"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}.service"
CONF_DIR="${SCRIPT_DIR}/conf"
LOG_DIR="${SCRIPT_DIR}/logs"

# ==================== 函数定义 ====================

info()    { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()    { echo -e "\033[33m[WARN]\033[0m $*"; }
error()   { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }

# 检测 CPU 架构，返回对应的二进制文件路径
detect_binary() {
    local arch
    arch=$(uname -m 2>/dev/null || arch 2>/dev/null)
    case "$arch" in
        x86_64|amd64)
            echo "${SCRIPT_DIR}/bin/clash-linux-amd64"
            ;;
        aarch64|arm64)
            echo "${SCRIPT_DIR}/bin/clash-linux-arm64"
            ;;
        armv7*)
            echo "${SCRIPT_DIR}/bin/clash-linux-armv7"
            ;;
        *)
            error "不支持的 CPU 架构: $arch"
            ;;
    esac
}

# 检查 systemd --user 是否可用
check_systemd_user() {
    if ! systemctl --user status &>/dev/null; then
        error "systemd --user 不可用。请确保以普通用户身份运行，且 systemd 版本 >= 220。"
    fi
}

# 检查 loginctl 是否启用了 linger（确保用户服务在未登录时也能运行）
check_linger() {
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        warn "用户 '$USER' 未启用 linger，服务将在注销后停止。"
        warn "如需后台常驻，请执行: sudo loginctl enable-linger $USER"
    fi
}

# ==================== 卸载 ====================

uninstall() {
    info "正在卸载 ${SERVICE_NAME} user service..."
    systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl --user daemon-reload
    info "卸载完成。"
    exit 0
}

# ==================== 安装 ====================

install() {
    check_systemd_user

    local binary
    binary=$(detect_binary)

    info "检测到 CPU 架构: $(uname -m)，使用二进制: ${binary}"

    # 检查文件是否存在
    [[ -f "$binary" ]]   || error "二进制文件不存在: $binary"
    [[ -d "$CONF_DIR" ]] || error "配置目录不存在: $CONF_DIR"
    [[ -f "${CONF_DIR}/config.yaml" ]] || warn "配置文件 ${CONF_DIR}/config.yaml 不存在，请先运行 start.sh 生成配置后再启用服务。"

    # 确保目录和权限
    mkdir -p "${SYSTEMD_USER_DIR}"
    mkdir -p "${LOG_DIR}"
    chmod +x "$binary"

    # 生成 service 文件（用实际路径替换占位符）
    sed \
        -e "s|CLASH_BINARY|${binary}|g" \
        -e "s|CONF_DIR|${CONF_DIR}|g" \
        -e "s|LOG_DIR|${LOG_DIR}|g" \
        "${SCRIPT_DIR}/clash.service" > "${SERVICE_FILE}"

    info "已写入 service 文件: ${SERVICE_FILE}"

    # 重载并启用
    systemctl --user daemon-reload
    systemctl --user enable "${SERVICE_NAME}.service"
    systemctl --user start  "${SERVICE_NAME}.service"

    # 等待片刻确认进程启动
    sleep 2
    if systemctl --user is-active --quiet "${SERVICE_NAME}.service"; then
        info "服务启动成功！"
    else
        warn "服务未正常启动，请查看日志："
        warn "  journalctl --user -u ${SERVICE_NAME}.service -n 30"
        warn "  或查看: ${LOG_DIR}/clash.log"
        exit 1
    fi

    check_linger

    echo ""
    echo "  常用命令："
    echo "    启动: systemctl --user start ${SERVICE_NAME}"
    echo "    停止: systemctl --user stop ${SERVICE_NAME}"
    echo "    重载配置: systemctl --user reload ${SERVICE_NAME}"
    echo "    查看状态: systemctl --user status ${SERVICE_NAME}"
    echo "    查看日志: journalctl --user -u ${SERVICE_NAME} -f"
    echo "    卸载服务: bash install.sh --uninstall"
    echo ""
}

# ==================== 入口 ====================

case "${1:-}" in
    --uninstall|-u)
        uninstall
        ;;
    *)
        install
        ;;
esac
