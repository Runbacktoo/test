#!/bin/bash
set -euo pipefail

PKG_DIR="/workspaces/test/packages"
mkdir -p "$PKG_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

log "======================================"
log "  Zabbix 7.4 离线包下载工具"
log "  目标目录: $PKG_DIR"
log "======================================"

# ---- 1. 安装 downloadonly 插件 ----
log "安装 dnf-plugins-core..."
dnf install -y dnf-plugins-core

# ---- 2. 强制重新添加 Zabbix 仓库 ----
log "添加 Zabbix 7.4 仓库..."
rpm -e zabbix-release 2>/dev/null || true
rpm -ivh https://repo.zabbix.com/zabbix/7.4/rocky/8/x86_64/zabbix-release-7.4-1.el8.noarch.rpm
dnf clean all

# ---- 3. 验证 Zabbix repo 已就绪 ----
log "验证 Zabbix repo..."
dnf repolist | grep zabbix || { echo "ERROR: Zabbix repo 未添加成功！"; exit 1; }

# ---- 4. 禁用系统自带 MySQL 模块 ----
log "禁用系统 MySQL 模块..."
dnf module disable -y mysql 2>/dev/null || true

# ---- 5. 添加 MySQL 8.0 官方仓库 ----
log "添加 MySQL 8.0 官方仓库..."
if ! rpm -q mysql80-community-release &>/dev/null; then
    dnf install -y https://dev.mysql.com/get/mysql80-community-release-el8-9.noarch.rpm
fi
dnf config-manager --enable mysql80-community
dnf clean all

# ---- 6. 下载 Zabbix 包 ----
log "下载 Zabbix 7.4 主要包（含依赖）..."
dnf download --resolve --destdir="$PKG_DIR" \
    zabbix-server-mysql \
    zabbix-web-mysql \
    zabbix-nginx-conf \
    zabbix-sql-scripts \
    zabbix-selinux-policy \
    zabbix-agent2

# ---- 7. 下载 MySQL 包 ----
log "下载 MySQL 8.0 包（含依赖）..."
dnf download --resolve --destdir="$PKG_DIR" \
    mysql-community-server \
    mysql-community-client \
    mysql-community-common \
    mysql-community-libs \
    mysql-community-libs-compat

# ---- 8. 下载 Nginx + PHP 包 ----
log "下载 Nginx + PHP 包（含依赖）..."
dnf download --resolve --destdir="$PKG_DIR" \
    nginx \
    php \
    php-fpm \
    php-mysqlnd \
    php-gd \
    php-xml \
    php-bcmath \
    php-mbstring \
    php-json \
    php-ldap \
    php-curl

# ---- 9. 把 zabbix-release rpm 也存进去 ----
log "保存 zabbix-release rpm..."
cp /var/cache/dnf/zabbix*/packages/*.rpm "$PKG_DIR/" 2>/dev/null || \
curl -sL "https://repo.zabbix.com/zabbix/7.4/rocky/8/x86_64/zabbix-release-7.4-1.el8.noarch.rpm" \
    -o "$PKG_DIR/zabbix-release-7.4-1.el8.noarch.rpm"

# ---- 完成统计 ----
COUNT=$(ls "$PKG_DIR"/*.rpm 2>/dev/null | wc -l)
SIZE=$(du -sh "$PKG_DIR" 2>/dev/null | awk '{print $1}')
echo ""
echo "========================================"
echo "✓ 完成！共 ${COUNT} 个 RPM，总大小 ${SIZE}"
echo "  存放位置: $PKG_DIR"
echo "========================================"
ls "$PKG_DIR"/*.rpm | xargs -I{} basename {}
