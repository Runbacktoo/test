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

log "安装 dnf-plugins-core..."
dnf install -y dnf-plugins-core

log "添加 Zabbix 7.4 仓库..."
rpm -e zabbix-release 2>/dev/null || true
rpm -Uvh https://repo.zabbix.com/zabbix/7.4/release/alma/8/noarch/zabbix-release-latest-7.4.el8.noarch.rpm
dnf clean all

log "验证 Zabbix repo..."
dnf repolist | grep zabbix || { echo "ERROR: Zabbix repo 未添加成功！"; exit 1; }

log "禁用系统 MySQL 模块..."
dnf module disable -y mysql 2>/dev/null || true

log "添加 MySQL 8.0 官方仓库..."
if ! rpm -q mysql80-community-release &>/dev/null; then
    dnf install -y https://dev.mysql.com/get/mysql80-community-release-el8-9.noarch.rpm
fi
dnf config-manager --enable mysql80-community
dnf clean all

log "切换 PHP 8.2 模块..."
dnf module switch-to -y php:8.2

log "下载 Zabbix 7.4 主要包（含依赖）..."
dnf download --resolve --alldeps --destdir="$PKG_DIR" \
    zabbix-server-mysql \
    zabbix-web-mysql \
    zabbix-nginx-conf \
    zabbix-sql-scripts \
    zabbix-selinux-policy \
    zabbix-agent2 \
    zabbix-agent2-plugin-mongodb \
    zabbix-agent2-plugin-mssql \
    zabbix-agent2-plugin-postgresql

log "下载 MySQL 8.0 包（含依赖）..."
dnf download --resolve --alldeps --destdir="$PKG_DIR" \
    mysql-community-server \
    mysql-community-client \
    mysql-community-client-plugins \
    mysql-community-common \
    mysql-community-icu-data-files \
    mysql-community-libs

log "下载 Nginx + PHP 包（含依赖）..."
dnf download --resolve --alldeps --destdir="$PKG_DIR" \
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

log "下载 zabbix-release rpm..."
dnf download --destdir="$PKG_DIR" zabbix-release 2>/dev/null || \
curl -sL "https://repo.zabbix.com/zabbix/7.4/release/alma/8/noarch/zabbix-release-latest-7.4.el8.noarch.rpm" \
    -o "$PKG_DIR/zabbix-release-latest-7.4.el8.noarch.rpm"

COUNT=$(ls "$PKG_DIR"/*.rpm 2>/dev/null | wc -l)
SIZE=$(du -sh "$PKG_DIR" 2>/dev/null | awk '{print $1}')
echo ""
echo "========================================"
echo "✓ 完成！共 ${COUNT} 个 RPM，总大小 ${SIZE}"
echo "  存放位置: $PKG_DIR"
echo "========================================"
ls "$PKG_DIR"/*.rpm | xargs -I{} basename {}