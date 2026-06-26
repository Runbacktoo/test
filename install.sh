#!/bin/bash
# =============================================================================
# Zabbix 7.4 离线自动安装脚本
# 平台: Rocky Linux 8
# 组件: Server + Frontend + Agent 2
# 数据库: MySQL 8.0
# Web服务器: Nginx
# =============================================================================

set -euo pipefail

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==================== 脚本目录 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
PKG_DIR="${SCRIPT_DIR}/packages"
CONFIG_DIR="${SCRIPT_DIR}/config"

# ==================== 安装配置（可修改） ====================
# 数据库配置
DB_HOST="localhost"
DB_PORT="3306"
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASSWORD="Zabbix@2024!"          # ← 修改为强密码
DB_ROOT_PASSWORD="MySQL@Root2024!"  # ← 修改为强密码

# Zabbix Server 配置
ZBX_SERVER_HOST="localhost"
ZBX_SERVER_PORT="10051"

# Nginx 配置
NGINX_PORT="80"
PHP_TIMEZONE="Asia/Shanghai"

# Zabbix 版本
ZBX_VERSION="7.4"
ZBX_RELEASE="1"

# ==================== 工具函数 ====================
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${timestamp} [${level}] ${msg}" >> "${LOG_FILE}"
    case "${level}" in
        INFO)  echo -e "${GREEN}[INFO]${NC}  ${msg}" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC}  ${msg}" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} ${msg}" ;;
        STEP)  echo -e "\n${CYAN}======= ${msg} =======${NC}" ;;
        *)     echo "${msg}" ;;
    esac
}

die() {
    log ERROR "$1"
    log ERROR "安装失败，请查看日志: ${LOG_FILE}"
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 用户或 sudo 运行此脚本"
}

check_os() {
    if [[ ! -f /etc/rocky-release ]]; then
        die "此脚本仅支持 Rocky Linux 8，当前系统不匹配"
    fi
    local ver
    ver=$(grep -oP '\d+' /etc/rocky-release | head -1)
    [[ "${ver}" == "8" ]] || die "需要 Rocky Linux 8，检测到版本: ${ver}"
    log INFO "操作系统检查通过: $(cat /etc/rocky-release)"
}

check_disk_space() {
    local required_gb=10
    local available_kb
    available_kb=$(df /var | awk 'NR==2 {print $4}')
    local available_gb=$(( available_kb / 1024 / 1024 ))
    if (( available_gb < required_gb )); then
        die "磁盘空间不足，需要至少 ${required_gb}GB，当前可用 ${available_gb}GB"
    fi
    log INFO "磁盘空间检查通过，可用: ${available_gb}GB"
}

show_banner() {
    echo -e "${BLUE}"
    cat << 'EOF'
  ______ ____  ____  ____  ____  _  __
 |_  /  v  | '  _ `'  _ `| '_ \| |/ /
  / /| '  '| | |_) | |_) | | | |   /
 /___|_||_|_| .__/| .__/|_| |_|_|\_\
            |_|   |_|
  Zabbix 7.4 离线安装程序
  Rocky Linux 8 | MySQL 8.0 | Nginx
EOF
    echo -e "${NC}"
}

confirm_install() {
    echo -e "${YELLOW}"
    echo "=========================================="
    echo "  即将安装以下组件:"
    echo "    - Zabbix Server ${ZBX_VERSION}"
    echo "    - Zabbix Frontend ${ZBX_VERSION}"
    echo "    - Zabbix Agent 2 ${ZBX_VERSION}"
    echo "    - MySQL 8.0"
    echo "    - Nginx"
    echo "    - PHP 8.x"
    echo ""
    echo "  数据库:"
    echo "    数据库名: ${DB_NAME}"
    echo "    用户名:   ${DB_USER}"
    echo ""
    echo "  日志文件: ${LOG_FILE}"
    echo "=========================================="
    echo -e "${NC}"

    read -rp "确认安装? (yes/no): " answer
    [[ "${answer}" == "yes" ]] || { log INFO "用户取消安装"; exit 0; }
}

# ==================== 安装模式检测 ====================
detect_install_mode() {
    if [[ -d "${PKG_DIR}" ]] && ls "${PKG_DIR}"/*.rpm &>/dev/null 2>&1; then
        INSTALL_MODE="offline"
        log INFO "检测到离线包目录，使用离线安装模式"
    else
        INSTALL_MODE="online"
        log WARN "未找到离线包，使用在线安装模式（需要网络）"
    fi
}

# ==================== Step 1: 系统准备 ====================
step_prepare_system() {
    log STEP "Step 1: 系统环境准备"

    # 关闭 SELinux（临时）
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        log INFO "临时关闭 SELinux..."
        setenforce 0
        # 永久关闭
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        log INFO "SELinux 已设置为 permissive 模式"
    fi

    # 关闭 firewalld（生产环境请根据需要放行端口）
    if systemctl is-active --quiet firewalld; then
        log WARN "检测到 firewalld 正在运行，将开放必要端口..."
        firewall-cmd --permanent --add-service=http --quiet || true
        firewall-cmd --permanent --add-port=10051/tcp --quiet || true
        firewall-cmd --permanent --add-port=10050/tcp --quiet || true
        firewall-cmd --reload --quiet || true
        log INFO "防火墙端口已放行: 80, 10050, 10051"
    fi

    # 设置系统时区
    timedatectl set-timezone Asia/Shanghai
    log INFO "时区已设置为 Asia/Shanghai"

    # 停止并禁用冲突服务
    for svc in apache2 httpd; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            systemctl stop "${svc}"
            systemctl disable "${svc}"
            log WARN "已停止冲突服务: ${svc}"
        fi
    done
}

# ==================== Step 2: 安装 MySQL ====================
step_install_mysql() {
    log STEP "Step 2: 安装 MySQL 8.0"

    if systemctl is-active --quiet mysqld 2>/dev/null; then
        log WARN "MySQL 已在运行，跳过安装"
        return 0
    fi

    if [[ "${INSTALL_MODE}" == "offline" ]]; then
        log INFO "离线安装 MySQL..."
        dnf install -y --disablerepo='*' \
            "${PKG_DIR}"/mysql-community-*.rpm \
            "${PKG_DIR}"/mysql-*.rpm 2>>"${LOG_FILE}" || \
        dnf install -y "${PKG_DIR}"/mysql*.rpm 2>>"${LOG_FILE}" || true
    else
        log INFO "在线安装 MySQL 8.0..."
        # 添加 MySQL 官方仓库
        dnf install -y https://dev.mysql.com/get/mysql80-community-release-el8-9.noarch.rpm 2>>"${LOG_FILE}" || true
        dnf module disable -y mysql 2>>"${LOG_FILE}" || true
        dnf install -y mysql-community-server 2>>"${LOG_FILE}"
    fi

    # 启动 MySQL
    systemctl enable mysqld
    systemctl start mysqld
    log INFO "MySQL 服务已启动"

    # 获取临时密码
    local tmp_pass
    tmp_pass=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | awk '{print $NF}' | tail -1 || echo "")

    if [[ -n "${tmp_pass}" ]]; then
        log INFO "检测到 MySQL 临时密码，正在初始化..."
        mysql --connect-expired-password -uroot -p"${tmp_pass}" 2>>"${LOG_FILE}" << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    else
        # 无密码初始化
        mysql -uroot 2>>"${LOG_FILE}" << EOF || true
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    fi

    log INFO "MySQL root 密码已设置"
}

# ==================== Step 3: 创建数据库 ====================
step_create_database() {
    log STEP "Step 3: 创建 Zabbix 数据库"

    # 检查数据库是否已存在
    local db_exists
    db_exists=$(mysql -uroot -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>>"${LOG_FILE}" | grep -c "${DB_NAME}" || echo "0")

    if [[ "${db_exists}" -gt 0 ]]; then
        log WARN "数据库 ${DB_NAME} 已存在，跳过创建"
        return 0
    fi

    mysql -uroot -p"${DB_ROOT_PASSWORD}" 2>>"${LOG_FILE}" << EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_HOST}';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
EOF

    log INFO "数据库 ${DB_NAME} 和用户 ${DB_USER} 创建成功"
}

# ==================== Step 4: 安装 Zabbix 仓库和包 ====================
step_install_zabbix() {
    log STEP "Step 4: 安装 Zabbix 7.4"

    if [[ "${INSTALL_MODE}" == "offline" ]]; then
        log INFO "离线安装 Zabbix..."
        # 安装 zabbix-release 包（包含仓库配置）
        if ls "${PKG_DIR}"/zabbix-release-*.rpm &>/dev/null 2>&1; then
            rpm -Uvh --force "${PKG_DIR}"/zabbix-release-*.rpm 2>>"${LOG_FILE}" || true
        fi

        # 离线安装所有 Zabbix 包
        dnf install -y --disablerepo='*' \
            "${PKG_DIR}"/zabbix-server-mysql-*.rpm \
            "${PKG_DIR}"/zabbix-web-mysql-*.rpm \
            "${PKG_DIR}"/zabbix-nginx-conf-*.rpm \
            "${PKG_DIR}"/zabbix-sql-scripts-*.rpm \
            "${PKG_DIR}"/zabbix-selinux-policy-*.rpm \
            "${PKG_DIR}"/zabbix-agent2-*.rpm \
            2>>"${LOG_FILE}" || \
        rpm -Uvh --nodeps \
            "${PKG_DIR}"/zabbix-*.rpm \
            2>>"${LOG_FILE}"
    else
        log INFO "在线安装 Zabbix 7.4..."
        # 添加官方仓库
        rpm -Uvh --force \
            "https://repo.zabbix.com/zabbix/${ZBX_VERSION}/rocky/8/x86_64/zabbix-release-${ZBX_VERSION}-${ZBX_RELEASE}.el8.noarch.rpm" \
            2>>"${LOG_FILE}" || true
        dnf clean all 2>>"${LOG_FILE}"

        dnf install -y \
            zabbix-server-mysql \
            zabbix-web-mysql \
            zabbix-nginx-conf \
            zabbix-sql-scripts \
            zabbix-selinux-policy \
            zabbix-agent2 \
            2>>"${LOG_FILE}"
    fi

    log INFO "Zabbix 包安装完成"
}

# ==================== Step 5: 导入数据库 Schema ====================
step_import_schema() {
    log STEP "Step 5: 导入 Zabbix 数据库 Schema"

    # 检查是否已导入
    local table_count
    table_count=$(mysql -u"${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" \
        -e "SHOW TABLES;" 2>>"${LOG_FILE}" | wc -l || echo "0")

    if [[ "${table_count}" -gt 5 ]]; then
        log WARN "数据库表已存在（${table_count}张），跳过 Schema 导入"
        return 0
    fi

    log INFO "正在导入数据库 Schema（可能需要几分钟）..."
    zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | \
        mysql --default-character-set=utf8mb4 \
              -u"${DB_USER}" -p"${DB_PASSWORD}" \
              "${DB_NAME}" 2>>"${LOG_FILE}"

    # 导入完成后关闭 log_bin_trust_function_creators
    mysql -uroot -p"${DB_ROOT_PASSWORD}" 2>>"${LOG_FILE}" << EOF
SET GLOBAL log_bin_trust_function_creators = 0;
EOF

    log INFO "数据库 Schema 导入完成"
}

# ==================== Step 6: 配置 Zabbix Server ====================
step_configure_server() {
    log STEP "Step 6: 配置 Zabbix Server"

    local conf="/etc/zabbix/zabbix_server.conf"
    [[ -f "${conf}" ]] || die "找不到 Zabbix Server 配置文件: ${conf}"

    # 备份原配置
    cp -n "${conf}" "${conf}.bak"

    # 应用自定义配置（如果存在）
    if [[ -f "${CONFIG_DIR}/zabbix_server.conf" ]]; then
        log INFO "使用自定义 zabbix_server.conf"
        cp "${CONFIG_DIR}/zabbix_server.conf" "${conf}"
    else
        log INFO "修改默认 zabbix_server.conf..."
        # 数据库配置
        sed -i "s/^# DBHost=localhost/DBHost=${DB_HOST}/" "${conf}"
        sed -i "s/^DBName=.*/DBName=${DB_NAME}/" "${conf}"
        sed -i "s/^DBUser=.*/DBUser=${DB_USER}/" "${conf}"

        # 添加或更新密码
        if grep -q "^DBPassword=" "${conf}"; then
            sed -i "s/^DBPassword=.*/DBPassword=${DB_PASSWORD}/" "${conf}"
        else
            sed -i "/^DBUser=/a DBPassword=${DB_PASSWORD}" "${conf}"
        fi

        # 性能调优
        sed -i "s/^# StartPollers=5/StartPollers=10/" "${conf}"
        sed -i "s/^# StartPingers=1/StartPingers=3/" "${conf}"
        sed -i "s/^# CacheSize=8M/CacheSize=64M/" "${conf}"
        sed -i "s/^# HistoryCacheSize=16M/HistoryCacheSize=64M/" "${conf}"
        sed -i "s/^# TrendCacheSize=4M/TrendCacheSize=16M/" "${conf}"
        sed -i "s/^# ValueCacheSize=8M/ValueCacheSize=64M/" "${conf}"

        # 日志
        sed -i "s|^LogFile=.*|LogFile=/var/log/zabbix/zabbix_server.log|" "${conf}"
        sed -i "s/^# LogFileSize=1/LogFileSize=100/" "${conf}"

        # PID
        sed -i "s|^# PidFile=.*|PidFile=/run/zabbix/zabbix_server.pid|" "${conf}"
    fi

    log INFO "Zabbix Server 配置完成"
}

# ==================== Step 7: 配置 Nginx + PHP ====================
step_configure_nginx() {
    log STEP "Step 7: 配置 Nginx 和 PHP-FPM"

    # 安装 PHP（如果缺失）
    if ! command -v php &>/dev/null; then
        if [[ "${INSTALL_MODE}" == "offline" ]]; then
            log INFO "离线安装 PHP..."
            ls "${PKG_DIR}"/php-*.rpm &>/dev/null 2>&1 && \
                dnf install -y --disablerepo='*' "${PKG_DIR}"/php-*.rpm 2>>"${LOG_FILE}" || true
        else
            log INFO "在线安装 PHP..."
            dnf install -y php php-fpm php-mysqlnd php-gd php-xml php-bcmath \
                php-mbstring php-json php-ldap php-curl 2>>"${LOG_FILE}"
        fi
    fi

    # 配置 Nginx for Zabbix
    local nginx_conf="/etc/nginx/conf.d/zabbix.conf"

    if [[ -f "${CONFIG_DIR}/zabbix_nginx.conf" ]]; then
        log INFO "使用自定义 nginx 配置"
        cp "${CONFIG_DIR}/zabbix_nginx.conf" "${nginx_conf}"
    else
        # Zabbix 官方 nginx 配置
        cat > "${nginx_conf}" << 'NGINX_CONF'
server {
    listen          80;
    server_name     _;

    root    /usr/share/zabbix;
    index   index.php;

    location = /favicon.ico {
        log_not_found   off;
    }

    location / {
        try_files       $uri $uri/ =404;
    }

    location /assets {
        access_log      off;
        expires         10d;
    }

    location ~ /\.ht {
        deny            all;
    }

    location ~ /(api\/|conf[^\.]|include|locale) {
        deny            all;
        return          404;
    }

    location /vendor {
        deny            all;
        return          404;
    }

    location ~ [^/]\.php(/|$) {
        fastcgi_pass    unix:/run/php-fpm/zabbix.sock;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_index   index.php;

        fastcgi_param   DOCUMENT_ROOT   /usr/share/zabbix;
        fastcgi_param   SCRIPT_FILENAME /usr/share/zabbix$fastcgi_script_name;
        fastcgi_param   PATH_TRANSLATED /usr/share/zabbix$fastcgi_script_name;

        include fastcgi_params;
        fastcgi_param   QUERY_STRING    $query_string;
        fastcgi_param   REQUEST_METHOD  $request_method;
        fastcgi_param   CONTENT_TYPE    $content_type;
        fastcgi_param   CONTENT_LENGTH  $content_length;

        fastcgi_intercept_errors        on;
        fastcgi_ignore_client_abort     off;
        fastcgi_connect_timeout         60;
        fastcgi_send_timeout            180;
        fastcgi_read_timeout            180;
        fastcgi_buffer_size             128k;
        fastcgi_buffers                 4 256k;
        fastcgi_busy_buffers_size       256k;
        fastcgi_temp_file_write_size    256k;
    }
}
NGINX_CONF
    fi

    # 删除默认 nginx server 配置中的 default_server
    if [[ -f /etc/nginx/nginx.conf ]]; then
        cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
        # 注释掉默认 server 块（避免端口冲突）
        sed -i '/^    server {/,/^    }/{ /listen.*80.*default_server/s/^/# / }' \
            /etc/nginx/nginx.conf 2>/dev/null || true
    fi

    # 配置 PHP 时区
    local php_fpm_conf="/etc/php-fpm.d/zabbix.conf"
    if [[ -f "${php_fpm_conf}" ]]; then
        sed -i "s|;php_value\[date.timezone\].*|php_value[date.timezone] = ${PHP_TIMEZONE}|" "${php_fpm_conf}"
        sed -i "s|php_value\[date.timezone\].*|php_value[date.timezone] = ${PHP_TIMEZONE}|" "${php_fpm_conf}"
    fi

    log INFO "Nginx 和 PHP-FPM 配置完成"
}

# ==================== Step 8: 配置 Zabbix Frontend ====================
step_configure_frontend() {
    log STEP "Step 8: 配置 Zabbix Frontend"

    local web_conf_dir="/etc/zabbix/web"
    local zabbix_conf="${web_conf_dir}/zabbix.conf.php"
    mkdir -p "${web_conf_dir}"

    if [[ -f "${CONFIG_DIR}/zabbix.conf.php" ]]; then
        log INFO "使用自定义 zabbix.conf.php"
        cp "${CONFIG_DIR}/zabbix.conf.php" "${zabbix_conf}"
    else
        log INFO "生成 Zabbix Frontend 配置..."
        cat > "${zabbix_conf}" << PHP_CONF
<?php
// Zabbix GUI configuration file.
global \$DB, \$HISTORY;

\$DB['TYPE']                     = 'MYSQL';
\$DB['SERVER']                   = '${DB_HOST}';
\$DB['PORT']                     = '${DB_PORT}';
\$DB['DATABASE']                 = '${DB_NAME}';
\$DB['USER']                     = '${DB_USER}';
\$DB['PASSWORD']                 = '${DB_PASSWORD}';

// Schema name. Used for PostgreSQL.
\$DB['SCHEMA']                   = '';

// Used for TLS connection.
\$DB['ENCRYPTION']               = false;
\$DB['KEY_FILE']                 = '';
\$DB['CERT_FILE']                = '';
\$DB['CA_FILE']                  = '';
\$DB['VERIFY_HOST']              = false;
\$DB['CIPHER_LIST']              = '';

// Vault configuration. Used if database credentials are stored in Vault.
\$DB['VAULT']                    = '';
\$DB['VAULT_URL']                = '';
\$DB['VAULT_DB_PATH']            = '';
\$DB['VAULT_TOKEN']              = '';
\$DB['VAULT_CERT_FILE']          = '';
\$DB['VAULT_KEY_FILE']           = '';
\$DB['VAULT_CA_FILE']            = '';
\$DB['VAULT_CACHE']              = false;

\$ZBX_SERVER                     = '${ZBX_SERVER_HOST}';
\$ZBX_SERVER_PORT                = '${ZBX_SERVER_PORT}';
\$ZBX_SERVER_NAME                = 'Zabbix Server';

\$IMAGE_FORMAT_DEFAULT           = IMAGE_FORMAT_PNG;
PHP_CONF
    fi

    chown -R apache:apache "${web_conf_dir}" 2>/dev/null || \
    chown -R nginx:nginx "${web_conf_dir}" 2>/dev/null || true
    chmod 640 "${zabbix_conf}"

    log INFO "Zabbix Frontend 配置完成"
}

# ==================== Step 9: 配置 Agent 2 ====================
step_configure_agent() {
    log STEP "Step 9: 配置 Zabbix Agent 2"

    local agent_conf="/etc/zabbix/zabbix_agent2.conf"
    [[ -f "${agent_conf}" ]] || { log WARN "Agent 2 配置文件不存在，跳过"; return 0; }

    cp -n "${agent_conf}" "${agent_conf}.bak"

    if [[ -f "${CONFIG_DIR}/zabbix_agent2.conf" ]]; then
        log INFO "使用自定义 agent2 配置"
        cp "${CONFIG_DIR}/zabbix_agent2.conf" "${agent_conf}"
    else
        sed -i "s/^Server=.*/Server=${ZBX_SERVER_HOST}/" "${agent_conf}"
        sed -i "s/^ServerActive=.*/ServerActive=${ZBX_SERVER_HOST}/" "${agent_conf}"
        local hostname
        hostname=$(hostname -f)
        sed -i "s/^Hostname=.*/Hostname=${hostname}/" "${agent_conf}"
    fi

    log INFO "Agent 2 配置完成"
}

# ==================== Step 10: 启动服务 ====================
step_start_services() {
    log STEP "Step 10: 启动所有服务"

    local services=("php-fpm" "nginx" "zabbix-server" "zabbix-agent2")

    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            log INFO "启动服务: ${svc}..."
            systemctl enable "${svc}" 2>>"${LOG_FILE}"
            systemctl restart "${svc}" 2>>"${LOG_FILE}"
            if systemctl is-active --quiet "${svc}"; then
                log INFO "  ✓ ${svc} 运行正常"
            else
                log WARN "  ✗ ${svc} 启动失败，请检查: journalctl -u ${svc}"
            fi
        else
            log WARN "服务 ${svc} 不存在，跳过"
        fi
    done
}

# ==================== Step 11: 安装后验证 ====================
step_verify() {
    log STEP "Step 11: 安装验证"

    local all_ok=true

    # 检查服务状态
    for svc in mysqld php-fpm nginx zabbix-server zabbix-agent2; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            log INFO "  ✓ ${svc}: 运行中"
        else
            log WARN "  ✗ ${svc}: 未运行"
            all_ok=false
        fi
    done

    # 检查端口监听
    for port in 80 10050 10051 3306; do
        if ss -tlnp | grep -q ":${port} "; then
            log INFO "  ✓ 端口 ${port}: 监听中"
        else
            log WARN "  ✗ 端口 ${port}: 未监听"
            all_ok=false
        fi
    done

    # 检查 Zabbix server 日志
    if [[ -f /var/log/zabbix/zabbix_server.log ]]; then
        local errors
        errors=$(tail -20 /var/log/zabbix/zabbix_server.log | grep -c "error\|ERROR" || echo "0")
        if [[ "${errors}" -gt 0 ]]; then
            log WARN "  Zabbix Server 日志中有 ${errors} 个错误，请检查: /var/log/zabbix/zabbix_server.log"
        fi
    fi

    if [[ "${all_ok}" == "true" ]]; then
        log INFO "✓ 所有检查通过！"
    else
        log WARN "部分检查失败，请查看上方警告信息"
    fi
}

# ==================== 显示完成信息 ====================
show_completion() {
    local ip_addr
    ip_addr=$(ip route get 1 | awk '{print $7;exit}' 2>/dev/null || hostname -I | awk '{print $1}')

    echo -e "\n${GREEN}"
    cat << EOF
╔══════════════════════════════════════════════════════╗
║            Zabbix 7.4 安装完成！                     ║
╠══════════════════════════════════════════════════════╣
║  Web 界面地址:                                       ║
║    http://${ip_addr}/                                 
║                                                      ║
║  默认登录凭据:                                       ║
║    用户名: Admin                                     ║
║    密  码: zabbix                                    ║
║                                                      ║
║  数据库信息:                                         ║
║    数据库: ${DB_NAME}                                 
║    用户名: ${DB_USER}                                 
║                                                      ║
║  服务状态查看:                                       ║
║    systemctl status zabbix-server                   ║
║    systemctl status zabbix-agent2                   ║
║    systemctl status nginx                           ║
║                                                      ║
║  安装日志: ${LOG_FILE}  
╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "${YELLOW}⚠️  首次登录后请立即修改默认密码！${NC}\n"
}

# ==================== 主流程 ====================
main() {
    show_banner
    check_root
    check_os
    check_disk_space
    detect_install_mode
    confirm_install

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