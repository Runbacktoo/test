#!/bin/bash
# =============================================================================
# Zabbix 7.4 离线自动安装脚本
# 平台: Rocky Linux 8
# 组件: Server + Frontend + Agent 2
# 数据库: MySQL 8.0
# Web服务器: Nginx
# 用法:
#   bash install.sh            正常安装（幂等，可重复执行）
#   bash install.sh --cleanup  清理本脚本安装的所有内容
# =============================================================================

set -euo pipefail

# ==================== 颜色定义 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ==================== 路径定义 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
PKG_DIR="${SCRIPT_DIR}/packages"
CONFIG_DIR="${SCRIPT_DIR}/config"
# 安装清单：记录本脚本创建的所有内容，供 --cleanup 使用
MANIFEST="${SCRIPT_DIR}/.install_manifest"

# ==================== 安装配置 ====================
DB_HOST="localhost"
DB_PORT="3306"
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"

ZBX_SERVER_HOST="localhost"
ZBX_SERVER_PORT="10051"
PHP_TIMEZONE="Asia/Shanghai"
ZBX_VERSION="7.4"

# ==================== 工具函数 ====================
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"; shift
    local msg="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}" >> "${LOG_FILE}"
    case "${level}" in
        INFO)  echo -e "${GREEN}[INFO]${NC}  ${msg}" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC}  ${msg}" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} ${msg}" ;;
        STEP)  echo -e "\n${CYAN}======= ${msg} =======${NC}" ;;
        *)     echo "${msg}" ;;
    esac
}

die() { log ERROR "$1"; log ERROR "失败，请查看日志: ${LOG_FILE}"; exit 1; }

# 向清单追加一条记录，格式: TYPE:VALUE
manifest_add() { echo "$1:$2" >> "${MANIFEST}"; }

# 检查清单中是否已有某条记录
manifest_has() { grep -qxF "$1:$2" "${MANIFEST}" 2>/dev/null; }

check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 用户或 sudo 运行此脚本"
}

check_os() {
    [[ -f /etc/rocky-release ]] || die "此脚本仅支持 Rocky Linux 8"
    local ver; ver=$(grep -oP '\d+' /etc/rocky-release | head -1)
    [[ "${ver}" == "8" ]] || die "需要 Rocky Linux 8，检测到版本: ${ver}"
    log INFO "操作系统: $(cat /etc/rocky-release)"
}

check_disk_space() {
    local avail_gb=$(( $(df /var | awk 'NR==2{print $4}') / 1024 / 1024 ))
    (( avail_gb >= 10 )) || die "磁盘空间不足，需要 10GB，可用 ${avail_gb}GB"
    log INFO "磁盘可用: ${avail_gb}GB"
}

prompt_passwords() {
    if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
        read -rsp "请输入 MySQL root 密码（至少8位）: " DB_ROOT_PASSWORD; echo
        [[ ${#DB_ROOT_PASSWORD} -ge 8 ]] || die "密码不足 8 位"
    fi
    if [[ -z "${DB_PASSWORD}" ]]; then
        read -rsp "请输入 Zabbix 数据库用户密码（至少8位）: " DB_PASSWORD; echo
        [[ ${#DB_PASSWORD} -ge 8 ]] || die "密码不足 8 位"
    fi
}

show_banner() {
    echo -e "${BLUE}"
    cat << 'EOF'
  Zabbix 7.4 离线安装程序
  Rocky Linux 8 | MySQL 8.0 | Nginx
EOF
    echo -e "${NC}"
}

confirm_install() {
    echo -e "${YELLOW}"
    echo "=========================================="
    echo "  即将安装: Zabbix ${ZBX_VERSION} + MySQL 8.0 + Nginx + PHP 8.2"
    echo "  数据库: ${DB_NAME}  用户: ${DB_USER}"
    echo "  日志: ${LOG_FILE}"
    [[ -f "${MANIFEST}" ]] && echo "  检测到历史清单，将跳过已完成步骤（幂等模式）"
    echo "=========================================="
    echo -e "${NC}"
    read -rp "确认安装? (yes/no): " answer
    [[ "${answer}" == "yes" ]] || { log INFO "用户取消"; exit 0; }
}

detect_install_mode() {
    if [[ -d "${PKG_DIR}" ]] && ls "${PKG_DIR}"/*.rpm &>/dev/null 2>&1; then
        INSTALL_MODE="offline"
        log INFO "离线安装模式（packages/ 目录已就绪）"
    else
        INSTALL_MODE="online"
        log WARN "在线安装模式（需要网络）"
    fi
}

# ==================== Step 1: 系统准备 ====================
step_prepare_system() {
    log STEP "Step 1: 系统环境准备"

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        for port in http 10051/tcp 10050/tcp; do
            if ! manifest_has FW "${port}"; then
                firewall-cmd --permanent --add-service=http --quiet 2>/dev/null || \
                firewall-cmd --permanent --add-port="${port}" --quiet 2>/dev/null || true
                manifest_add FW "${port}"
            fi
        done
        firewall-cmd --reload --quiet || true
        log INFO "防火墙端口已放行: 80, 10050, 10051"
    fi

    timedatectl set-timezone Asia/Shanghai
    log INFO "时区: Asia/Shanghai"

    for svc in apache2 httpd; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            systemctl stop "${svc}" && systemctl disable "${svc}"
            log WARN "已停止冲突服务: ${svc}"
        fi
    done
}

# ==================== Step 2: 安装 MySQL ====================
step_install_mysql() {
    log STEP "Step 2: 安装 MySQL 8.0"

    # 幂等：MySQL 已在运行则跳过安装
    if systemctl is-active --quiet mysqld 2>/dev/null; then
        log INFO "MySQL 已在运行，跳过安装"
    else
        if [[ "${INSTALL_MODE}" == "offline" ]]; then
            log INFO "离线安装 MySQL..."
            dnf install -y --disablerepo='*' "${PKG_DIR}"/mysql*.rpm 2>>"${LOG_FILE}"
        else
            log INFO "在线安装 MySQL 8.0..."
            dnf install -y https://dev.mysql.com/get/mysql80-community-release-el8-9.noarch.rpm \
                2>>"${LOG_FILE}" || true
            dnf module disable -y mysql 2>>"${LOG_FILE}" || true
            dnf install -y mysql-community-server 2>>"${LOG_FILE}"
        fi
        manifest_add PKG mysql-community-server
        systemctl enable mysqld
        systemctl start mysqld
        log INFO "MySQL 服务已启动"
    fi

    # 幂等：优先用用户提供的密码测试连通，已可用则跳过初始化
    if mysql -uroot -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &>/dev/null 2>&1; then
        log INFO "MySQL root 密码已就绪，跳过初始化"
        return 0
    fi

    # 尝试用临时密码初始化
    local tmp_pass
    tmp_pass=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null \
        | awk '{print $NF}' | tail -1 || echo "")

    if [[ -n "${tmp_pass}" ]]; then
        log INFO "使用临时密码初始化 root..."
        mysql --connect-expired-password -uroot -p"${tmp_pass}" 2>>"${LOG_FILE}" << EOF
SET GLOBAL validate_password.policy=LOW;
SET GLOBAL validate_password.length=8;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    else
        log INFO "无临时密码，直接设置 root 密码..."
        mysql -uroot 2>>"${LOG_FILE}" << EOF || true
SET GLOBAL validate_password.policy=LOW;
SET GLOBAL validate_password.length=8;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    fi

    # 验证密码是否设置成功
    mysql -uroot -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &>/dev/null 2>&1 \
        || die "MySQL root 密码设置失败，请检查日志"
    log INFO "MySQL root 密码设置成功"
}

# ==================== Step 3: 创建数据库 ====================
step_create_database() {
    log STEP "Step 3: 创建 Zabbix 数据库"

    local db_exists
    db_exists=$(mysql -uroot -p"${DB_ROOT_PASSWORD}" \
        -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>>"${LOG_FILE}" \
        | grep -c "${DB_NAME}" || echo "0")

    if [[ "${db_exists}" -gt 0 ]]; then
        log INFO "数据库 ${DB_NAME} 已存在，跳过创建"
    else
        mysql -uroot -p"${DB_ROOT_PASSWORD}" 2>>"${LOG_FILE}" << EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_HOST}';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF
        manifest_add DB "${DB_NAME}"
        manifest_add DBUSER "${DB_USER}@${DB_HOST}"
        log INFO "数据库 ${DB_NAME} 和用户 ${DB_USER} 创建成功"
    fi
}

# ==================== Step 4: 安装 Zabbix ====================
step_install_zabbix() {
    log STEP "Step 4: 安装 Zabbix 7.4"

    # 幂等：zabbix-server 已安装则跳过
    if rpm -q zabbix-server-mysql &>/dev/null; then
        log INFO "Zabbix 包已安装，跳过"
        return 0
    fi

    if [[ "${INSTALL_MODE}" == "offline" ]]; then
        log INFO "离线安装 Zabbix..."
        if ls "${PKG_DIR}"/zabbix-release-*.rpm &>/dev/null 2>&1; then
            rpm -Uvh "${PKG_DIR}"/zabbix-release-*.rpm 2>>"${LOG_FILE}" || true
        fi
        dnf install -y --disablerepo='*' \
            "${PKG_DIR}"/zabbix-server-mysql-*.rpm \
            "${PKG_DIR}"/zabbix-web-mysql-*.rpm \
            "${PKG_DIR}"/zabbix-nginx-conf-*.rpm \
            "${PKG_DIR}"/zabbix-sql-scripts-*.rpm \
            "${PKG_DIR}"/zabbix-selinux-policy-*.rpm \
            "${PKG_DIR}"/zabbix-agent2-*.rpm \
            2>>"${LOG_FILE}" || \
        rpm -Uvh --nodeps "${PKG_DIR}"/zabbix-*.rpm 2>>"${LOG_FILE}"
    else
        log INFO "在线安装 Zabbix 7.4..."
        rpm -Uvh \
            "https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/alma/8/noarch/zabbix-release-latest-${ZBX_VERSION}.el8.noarch.rpm" \
            2>>"${LOG_FILE}" || true
        dnf clean all 2>>"${LOG_FILE}"
        dnf install -y zabbix-server-mysql zabbix-web-mysql zabbix-nginx-conf \
            zabbix-sql-scripts zabbix-selinux-policy zabbix-agent2 2>>"${LOG_FILE}"
    fi

    manifest_add PKG zabbix-server-mysql
    manifest_add PKG zabbix-agent2
    log INFO "Zabbix 包安装完成"
}

# ==================== Step 5: 导入 Schema ====================
step_import_schema() {
    log STEP "Step 5: 导入 Zabbix 数据库 Schema"

    local table_count
    table_count=$(mysql -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" \
        -e "SHOW TABLES;" 2>>"${LOG_FILE}" | wc -l || echo "0")

    if [[ "${table_count}" -gt 5 ]]; then
        log INFO "数据库表已存在（${table_count} 张），跳过 Schema 导入"
        return 0
    fi

    local schema_file="/usr/share/zabbix-sql-scripts/mysql/server.sql.gz"
    [[ -f "${schema_file}" ]] || die "找不到 Schema 文件: ${schema_file}"

    log INFO "正在导入 Schema（可能需要几分钟，请耐心等待）..."
    zcat "${schema_file}" | \
        mysql --default-character-set=utf8mb4 \
              -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" 2>>"${LOG_FILE}"

    mysql -uroot -p"${DB_ROOT_PASSWORD}" 2>>"${LOG_FILE}" << EOF
SET GLOBAL log_bin_trust_function_creators = 0;
EOF
    manifest_add SCHEMA "${DB_NAME}"
    log INFO "Schema 导入完成"
}

# ==================== Step 6: 配置 Zabbix Server ====================
step_configure_server() {
    log STEP "Step 6: 配置 Zabbix Server"

    local conf="/etc/zabbix/zabbix_server.conf"
    [[ -f "${conf}" ]] || die "找不到配置文件: ${conf}"

    # 幂等：有备份说明已配置过，跳过
    if [[ -f "${conf}.bak" ]]; then
        log INFO "zabbix_server.conf 已配置过，跳过"
        return 0
    fi

    cp "${conf}" "${conf}.bak"
    manifest_add FILE "${conf}.bak"

    if [[ -f "${CONFIG_DIR}/zabbix_server.conf" ]]; then
        cp "${CONFIG_DIR}/zabbix_server.conf" "${conf}"
    else
        sed -i "s/^# DBHost=localhost/DBHost=${DB_HOST}/" "${conf}"
        sed -i "s/^DBName=.*/DBName=${DB_NAME}/" "${conf}"
        sed -i "s/^DBUser=.*/DBUser=${DB_USER}/" "${conf}"
        grep -q "^DBPassword=" "${conf}" \
            && sed -i "s/^DBPassword=.*/DBPassword=${DB_PASSWORD}/" "${conf}" \
            || sed -i "/^DBUser=/a DBPassword=${DB_PASSWORD}" "${conf}"
        sed -i "s/^# StartPollers=5/StartPollers=10/" "${conf}"
        sed -i "s/^# StartPingers=1/StartPingers=3/" "${conf}"
        sed -i "s/^# CacheSize=8M/CacheSize=64M/" "${conf}"
        sed -i "s/^# HistoryCacheSize=16M/HistoryCacheSize=64M/" "${conf}"
        sed -i "s/^# TrendCacheSize=4M/TrendCacheSize=16M/" "${conf}"
        sed -i "s/^# ValueCacheSize=8M/ValueCacheSize=64M/" "${conf}"
        sed -i "s|^LogFile=.*|LogFile=/var/log/zabbix/zabbix_server.log|" "${conf}"
        sed -i "s/^# LogFileSize=1/LogFileSize=100/" "${conf}"
        sed -i "s|^# PidFile=.*|PidFile=/run/zabbix/zabbix_server.pid|" "${conf}"
    fi
    log INFO "Zabbix Server 配置完成"
}

# ==================== Step 7: 配置 Nginx + PHP ====================
step_configure_nginx() {
    log STEP "Step 7: 配置 Nginx 和 PHP-FPM"

    if ! command -v php &>/dev/null; then
        if [[ "${INSTALL_MODE}" == "offline" ]]; then
            ls "${PKG_DIR}"/php-*.rpm &>/dev/null 2>&1 && \
                dnf install -y --disablerepo='*' "${PKG_DIR}"/php-*.rpm 2>>"${LOG_FILE}" || true
        else
            dnf module switch-to -y php:8.2 2>>"${LOG_FILE}"
            dnf install -y php php-fpm php-mysqlnd php-gd php-xml php-bcmath \
                php-mbstring php-json php-ldap php-curl 2>>"${LOG_FILE}"
        fi
        manifest_add PKG php-fpm
    fi

    local nginx_conf="/etc/nginx/conf.d/zabbix.conf"

    # 幂等：配置文件已存在则跳过
    if [[ -f "${nginx_conf}" ]]; then
        log INFO "Nginx zabbix.conf 已存在，跳过"
    else
        if [[ -f "${CONFIG_DIR}/zabbix_nginx.conf" ]]; then
            cp "${CONFIG_DIR}/zabbix_nginx.conf" "${nginx_conf}"
        else
            cat > "${nginx_conf}" << 'NGINX_CONF'
server {
    listen          80;
    server_name     _;
    root    /usr/share/zabbix;
    index   index.php;

    location = /favicon.ico { log_not_found off; }
    location / { try_files $uri $uri/ =404; }
    location /assets { access_log off; expires 10d; }
    location ~ /\.ht { deny all; }
    location ~ /(api\/|conf[^\.]|include|locale) { deny all; return 404; }
    location /vendor { deny all; return 404; }

    location ~ [^/]\.php(/|$) {
        fastcgi_pass            unix:/run/php-fpm/zabbix.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_index           index.php;
        fastcgi_param           DOCUMENT_ROOT    /usr/share/zabbix;
        fastcgi_param           SCRIPT_FILENAME  /usr/share/zabbix$fastcgi_script_name;
        fastcgi_param           PATH_TRANSLATED  /usr/share/zabbix$fastcgi_script_name;
        include                 fastcgi_params;
        fastcgi_param           QUERY_STRING     $query_string;
        fastcgi_param           REQUEST_METHOD   $request_method;
        fastcgi_param           CONTENT_TYPE     $content_type;
        fastcgi_param           CONTENT_LENGTH   $content_length;
        fastcgi_intercept_errors     on;
        fastcgi_ignore_client_abort  off;
        fastcgi_connect_timeout      60;
        fastcgi_send_timeout         180;
        fastcgi_read_timeout         180;
        fastcgi_buffer_size          128k;
        fastcgi_buffers              4 256k;
        fastcgi_busy_buffers_size    256k;
        fastcgi_temp_file_write_size 256k;
    }
}
NGINX_CONF
        fi
        manifest_add FILE "${nginx_conf}"
    fi

    # 注释掉 nginx.conf 里默认的 80 端口 server 块（幂等：已注释则跳过）
    if [[ -f /etc/nginx/nginx.conf ]] && ! [[ -f /etc/nginx/nginx.conf.bak ]]; then
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
        sed -i '/^    server {/,/^    }/{ /listen.*80.*default_server/s/^/# / }' \
            /etc/nginx/nginx.conf 2>/dev/null || true
        manifest_add FILE /etc/nginx/nginx.conf.bak
    fi

    local php_fpm_conf="/etc/php-fpm.d/zabbix.conf"
    if [[ -f "${php_fpm_conf}" ]]; then
        sed -i "s|;php_value\[date.timezone\].*|php_value[date.timezone] = ${PHP_TIMEZONE}|" "${php_fpm_conf}"
        sed -i "s|php_value\[date.timezone\].*|php_value[date.timezone] = ${PHP_TIMEZONE}|" "${php_fpm_conf}"
    fi

    log INFO "Nginx 和 PHP-FPM 配置完成"
}

# ==================== Step 8: 配置 Frontend ====================
step_configure_frontend() {
    log STEP "Step 8: 配置 Zabbix Frontend"

    local web_conf_dir="/etc/zabbix/web"
    local zabbix_conf="${web_conf_dir}/zabbix.conf.php"
    mkdir -p "${web_conf_dir}"

    # 幂等：配置文件已存在则跳过
    if [[ -f "${zabbix_conf}" ]]; then
        log INFO "zabbix.conf.php 已存在，跳过"
        return 0
    fi

    if [[ -f "${CONFIG_DIR}/zabbix.conf.php" ]]; then
        cp "${CONFIG_DIR}/zabbix.conf.php" "${zabbix_conf}"
    else
        cat > "${zabbix_conf}" << PHP_CONF
<?php
global \$DB, \$HISTORY;
\$DB['TYPE']         = 'MYSQL';
\$DB['SERVER']       = '${DB_HOST}';
\$DB['PORT']         = '${DB_PORT}';
\$DB['DATABASE']     = '${DB_NAME}';
\$DB['USER']         = '${DB_USER}';
\$DB['PASSWORD']     = '${DB_PASSWORD}';
\$DB['SCHEMA']       = '';
\$DB['ENCRYPTION']   = false;
\$DB['KEY_FILE']     = '';
\$DB['CERT_FILE']    = '';
\$DB['CA_FILE']      = '';
\$DB['VERIFY_HOST']  = false;
\$DB['CIPHER_LIST']  = '';
\$DB['VAULT']        = '';
\$DB['VAULT_URL']    = '';
\$DB['VAULT_DB_PATH']= '';
\$DB['VAULT_TOKEN']  = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE']  = '';
\$DB['VAULT_CA_FILE']   = '';
\$DB['VAULT_CACHE']     = false;
\$ZBX_SERVER         = '${ZBX_SERVER_HOST}';
\$ZBX_SERVER_PORT    = '${ZBX_SERVER_PORT}';
\$ZBX_SERVER_NAME    = 'Zabbix Server';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP_CONF
    fi

    chown -R nginx:nginx "${web_conf_dir}" 2>>"${LOG_FILE}" || true
    chmod 640 "${zabbix_conf}"
    manifest_add FILE "${zabbix_conf}"
    manifest_add DIR  "${web_conf_dir}"
    log INFO "Frontend 配置完成"
}

# ==================== Step 9: 配置 Agent 2 ====================
step_configure_agent() {
    log STEP "Step 9: 配置 Zabbix Agent 2"

    local agent_conf="/etc/zabbix/zabbix_agent2.conf"
    [[ -f "${agent_conf}" ]] || { log WARN "Agent 2 配置文件不存在，跳过"; return 0; }

    if [[ -f "${agent_conf}.bak" ]]; then
        log INFO "Agent 2 已配置过，跳过"
        return 0
    fi

    cp "${agent_conf}" "${agent_conf}.bak"
    manifest_add FILE "${agent_conf}.bak"

    if [[ -f "${CONFIG_DIR}/zabbix_agent2.conf" ]]; then
        cp "${CONFIG_DIR}/zabbix_agent2.conf" "${agent_conf}"
    else
        sed -i "s/^Server=.*/Server=${ZBX_SERVER_HOST}/" "${agent_conf}"
        sed -i "s/^ServerActive=.*/ServerActive=${ZBX_SERVER_HOST}/" "${agent_conf}"
        sed -i "s/^Hostname=.*/Hostname=$(hostname -f)/" "${agent_conf}"
    fi
    log INFO "Agent 2 配置完成"
}

# ==================== Step 10: 启动服务 ====================
step_start_services() {
    log STEP "Step 10: 启动所有服务"

    for svc in php-fpm nginx zabbix-server zabbix-agent2; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
            systemctl enable "${svc}" 2>>"${LOG_FILE}"
            systemctl restart "${svc}" 2>>"${LOG_FILE}"
            if systemctl is-active --quiet "${svc}"; then
                log INFO "  ✓ ${svc} 运行正常"
                manifest_add SVC "${svc}"
            else
                log WARN "  ✗ ${svc} 启动失败，请检查: journalctl -u ${svc}"
            fi
        fi
    done
}

# ==================== Step 11: 验证 ====================
step_verify() {
    log STEP "Step 11: 安装验证"
    local all_ok=true

    for svc in mysqld php-fpm nginx zabbix-server zabbix-agent2; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            log INFO "  ✓ ${svc}: 运行中"
        else
            log WARN "  ✗ ${svc}: 未运行"; all_ok=false
        fi
    done

    for port in 80 10050 10051 3306; do
        if ss -tlnp | grep -q ":${port} "; then
            log INFO "  ✓ 端口 ${port}: 监听中"
        else
            log WARN "  ✗ 端口 ${port}: 未监听"; all_ok=false
        fi
    done

    if [[ -f /var/log/zabbix/zabbix_server.log ]]; then
        local errors
        errors=$(tail -20 /var/log/zabbix/zabbix_server.log | grep -c "error\|ERROR" || echo "0")
        [[ "${errors}" -gt 0 ]] && \
            log WARN "  Zabbix Server 日志有 ${errors} 个错误: /var/log/zabbix/zabbix_server.log"
    fi

    [[ "${all_ok}" == "true" ]] && log INFO "✓ 所有检查通过！" \
        || log WARN "部分检查失败，请查看上方警告"
}

# ==================== 完成展示 ====================
show_completion() {
    local ip_addr
    ip_addr=$(ip route get 1 2>/dev/null | awk '{print $7;exit}' || hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}"
    cat << EOF
╔══════════════════════════════════════════════════╗
║          Zabbix 7.4 安装完成！                   ║
╠══════════════════════════════════════════════════╣
║  Web 界面: http://${ip_addr}/
║  默认账号: Admin / zabbix
║  数据库:   ${DB_NAME} / ${DB_USER}
║  日志:     ${LOG_FILE}
║  清单:     ${MANIFEST}
╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "${YELLOW}⚠️  首次登录后请立即修改默认密码！${NC}\n"
}

# ==================== 清理模式 ====================
do_cleanup() {
    echo -e "${RED}"
    echo "=========================================="
    echo "  清理模式：将删除本脚本安装的所有内容"
    echo "  依据清单: ${MANIFEST}"
    echo "=========================================="
    echo -e "${NC}"

    [[ -f "${MANIFEST}" ]] || { echo "未找到安装清单 ${MANIFEST}，无法清理"; exit 1; }

    read -rp "确认清理? 此操作不可恢复 (yes/no): " answer
    [[ "${answer}" == "yes" ]] || { echo "已取消"; exit 0; }

    # 停止并禁用服务
    while IFS=: read -r type value; do
        [[ "${type}" == "SVC" ]] || continue
        if systemctl is-active --quiet "${value}" 2>/dev/null; then
            systemctl stop "${value}" && systemctl disable "${value}"
            echo "已停止服务: ${value}"
        fi
    done < "${MANIFEST}"

    # 删除数据库和用户（需要 root 密码）
    if grep -q "^DB:" "${MANIFEST}" || grep -q "^DBUSER:" "${MANIFEST}"; then
        read -rsp "请输入 MySQL root 密码以删除数据库和用户: " _root_pass; echo
        while IFS=: read -r type value; do
            if [[ "${type}" == "DBUSER" ]]; then
                local u="${value%@*}" h="${value#*@}"
                mysql -uroot -p"${_root_pass}" -e "DROP USER IF EXISTS '${u}'@'${h}';" \
                    2>/dev/null && echo "已删除数据库用户: ${value}" || true
            fi
            if [[ "${type}" == "DB" ]]; then
                mysql -uroot -p"${_root_pass}" -e "DROP DATABASE IF EXISTS ${value};" \
                    2>/dev/null && echo "已删除数据库: ${value}" || true
            fi
        done < "${MANIFEST}"
    fi

    # 删除本脚本创建的文件
    while IFS=: read -r type value; do
        [[ "${type}" == "FILE" ]] || continue
        if [[ -f "${value}" ]]; then
            rm -f "${value}" && echo "已删除文件: ${value}"
        fi
    done < "${MANIFEST}"

    # 卸载 Zabbix 包（不卸载 MySQL/PHP，避免影响其他环境）
    if grep -q "^PKG:zabbix" "${MANIFEST}"; then
        dnf remove -y zabbix-server-mysql zabbix-web-mysql zabbix-nginx-conf \
            zabbix-sql-scripts zabbix-selinux-policy zabbix-agent2 zabbix-web \
            zabbix-web-deps 2>/dev/null || true
        rpm -e zabbix-release 2>/dev/null || true
        echo "已卸载 Zabbix 包"
    fi

    echo ""
    echo "注意: MySQL 和 PHP 包未自动卸载，如需卸载请手动执行:"
    echo "  dnf remove mysql-community-server mysql-community-client"
    echo "  dnf remove php php-fpm php-mysqlnd 等"
    echo ""

    rm -f "${MANIFEST}"
    echo "清理完成，安装清单已删除"
}

# ==================== 主流程 ====================
main() {
    if [[ "${1:-}" == "--cleanup" ]]; then
        check_root
        do_cleanup
        exit 0
    fi

    show_banner
    check_root
    check_os
    check_disk_space
    prompt_passwords
    detect_install_mode
    confirm_install

    touch "${MANIFEST}"

    step_prepare_system
    step_install_mysql
    step_create_database
    step_install_zabbix
    step_import_schema
    step_configure_server
    step_configure_nginx
    step_configure_frontend
    step_configure_agent
    step_start_services
    step_verify
    show_completion
}

main "$@"