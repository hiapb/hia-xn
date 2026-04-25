#!/usr/bin/env bash

# ==========================================
# XBoard 运维控制台 - MySQL 多容器版
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
DEFAULT_INSTALL_PATH="/opt/xboard"

CRON_TAG_BEGIN="# XBOARD_BACKUP_BEGIN"
CRON_TAG_END="# XBOARD_BACKUP_END"
BACKUP_LOG="/var/log/xboard_backup.log"

# ---- 基础工具函数 ----
info() { echo -e "\033[32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[33m[WARN]\033[0m $1" >&2; }
err()  { echo -e "\033[31m[ERROR]\033[0m $1" >&2; }
die()  { echo -e "\033[31m[FATAL]\033[0m $1" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "系统缺少核心依赖: $1，请安装后重试。"
}

get_local_ip() {
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

docker_compose_cmd() {
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        die "未检测到 Docker Compose，请先安装 docker-compose 或 docker compose 插件。"
    fi
}

get_workdir() {
    if [[ -f "/etc/xboard_env" ]]; then
        local dir
        dir=$(cat "/etc/xboard_env")
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return
        fi
    fi
    echo ""
}

fix_xboard_image() {
    if [[ -f docker-compose.yaml ]]; then
        sed -i 's#ghcr.io/ghcr.io/cedar2025/xboard:latest#ghcr.io/cedar2025/xboard:latest#g' docker-compose.yaml
        sed -i 's#image:[[:space:]]*cedar2025/xboard:latest#image: ghcr.io/cedar2025/xboard:latest#g' docker-compose.yaml
    fi
}

get_compose_port() {
    local port
    port=$(sed -nE 's/^[[:space:]]*-[[:space:]]*"?([0-9]+):7001"?.*/\1/p' docker-compose.yaml 2>/dev/null | head -n1)
    echo "${port:-7001}"
}

wait_mysql_ready() {
    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "正在等待 MySQL 容器就绪..."
    for i in {1..60}; do
        if $dc_cmd -f docker-compose.yaml exec -T mysql mysqladmin ping -h localhost >/dev/null 2>&1; then
            info "MySQL 容器已就绪。"
            return 0
        fi
        sleep 2
    done

    err "MySQL 容器等待超时，请检查 mysql 日志。"
    return 1
}

wait_app_mysql_ready() {
    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    info "正在等待 App 容器连接 MySQL..."
    for i in {1..60}; do
        if $dc_cmd -f docker-compose.yaml exec -T app php -r '
            $host=getenv("DB_HOST");
            $db=getenv("DB_DATABASE");
            $user=getenv("DB_USERNAME");
            $pass=getenv("DB_PASSWORD");
            try {
                new PDO("mysql:host=".$host.";port=3306;dbname=".$db, $user, $pass);
                exit(0);
            } catch (Throwable $e) {
                exit(1);
            }
        ' >/dev/null 2>&1; then
            info "App 已成功连接 MySQL。"
            return 0
        fi
        sleep 2
    done

    err "App 连接 MySQL 超时，请检查 app/mysql 容器日志。"
    return 1
}

# ---- 1. 一键部署系统 ----
deploy_xboard() {
    info "== 启动 XBoard 自动化部署编排 =="
    require_cmd docker
    require_cmd curl
    require_cmd openssl

    local dc_cmd
    dc_cmd=$(docker_compose_cmd)

    read -r -p "请输入安装路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local install_path=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$install_path" && -f "$install_path/docker-compose.yaml" ]]; then
        err "该路径已存在部署实例，请先执行 [8] 卸载。"
        return
    fi

    mkdir -p "$install_path"
    echo "$install_path" > "/etc/xboard_env"
    cd "$install_path" || return

    read -r -p "请输入对外访问端口 [默认: 7001]: " input_port
    local host_port=${input_port:-7001}

    info "正在生成核心配置..."
    local db_password
    local app_key
    db_password=$(openssl rand -hex 16)
    app_key="base64:$(openssl rand -base64 32)"

    cat > .env <<EOF
APP_NAME=XBoard
APP_ENV=production
APP_KEY=${app_key}
APP_DEBUG=false
APP_URL=http://$(get_local_ip):${host_port}

CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis

DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=xboard
DB_USERNAME=xboard
DB_PASSWORD=${db_password}

REDIS_HOST=redis
REDIS_PASSWORD=null
REDIS_PORT=6379
EOF

    info "正在生成 Docker Compose 文件..."
    cat > docker-compose.yaml <<EOF
services:
  app:
    image: ghcr.io/cedar2025/xboard:latest
    container_name: xboard_web
    restart: always
    env_file: .env
    ports:
      - "${host_port}:7001"
    volumes:
      - ./data:/www/workspace
    depends_on:
      - redis
      - mysql
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2048M

  queue:
    image: ghcr.io/cedar2025/xboard:latest
    container_name: xboard_queue
    restart: always
    env_file: .env
    command: php artisan queue:work --tries=3 --timeout=60
    volumes:
      - ./data:/www/workspace
    depends_on:
      - app
      - redis
      - mysql
    deploy:
      resources:
        limits:
          cpus: '1.5'
          memory: 1024M

  schedule:
    image: ghcr.io/cedar2025/xboard:latest
    container_name: xboard_schedule
    restart: always
    env_file: .env
    command: php artisan schedule:work
    volumes:
      - ./data:/www/workspace
    depends_on:
      - app
      - mysql

  redis:
    image: redis:7.2-alpine
    container_name: xboard_redis
    restart: always
    command: redis-server --appendonly yes --maxmemory 512mb --maxmemory-policy allkeys-lru
    volumes:
      - ./redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  mysql:
    image: mariadb:10.11
    container_name: xboard_mysql
    restart: always
    env_file: .env
    environment:
      MYSQL_ROOT_PASSWORD: ${db_password}
      MYSQL_DATABASE: xboard
      MYSQL_USER: xboard
      MYSQL_PASSWORD: ${db_password}
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb_buffer_pool_size=1G
      - --max_connections=2000
      - --innodb_flush_log_at_trx_commit=2
      - --skip-log-bin
    volumes:
      - ./mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 15s
      timeout: 5s
      retries: 5
EOF

    mkdir -p data mysql_data redis_data
    chmod -R 777 data mysql_data redis_data

    info "正在拉起微服务矩阵..."
    $dc_cmd -f docker-compose.yaml up -d || {
        err "容器启动失败，请检查 Docker 状态。"
        return
    }

    wait_mysql_ready || return
    wait_app_mysql_ready || return

    $dc_cmd -f docker-compose.yaml exec -T app php artisan config:clear || true
    $dc_cmd -f docker-compose.yaml exec -T app php artisan cache:clear || true
    $dc_cmd -f docker-compose.yaml exec -T app php artisan xboard:install || warn "首次安装脚本执行异常，请手动检查。"

    local server_ip
    server_ip=$(get_local_ip)

    echo -e "\n=================================================="
    echo -e "\033[32m✅ XBoard 部署完成！\033[0m"
    echo -e "请务必在服务器防火墙/安全组中放行 \033[31m${host_port}\033[0m 端口！"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${host_port}\033[0m"
    echo -e "数据库密码: \033[33m${db_password}\033[0m"
    echo -e "==================================================\n"
}

# ---- 2. 升级服务 ----
upgrade_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的 XBoard，请先执行 [1] 一键部署。"
        return
    fi

    cd "$workdir" || return
    fix_xboard_image

    info "正在拉取最新镜像并重建容器..."
    $(docker_compose_cmd) -f docker-compose.yaml pull
    $(docker_compose_cmd) -f docker-compose.yaml up -d

    wait_app_mysql_ready || return

    $(docker_compose_cmd) -f docker-compose.yaml exec -T app php artisan config:clear || true
    $(docker_compose_cmd) -f docker-compose.yaml exec -T app php artisan cache:clear || true
    $(docker_compose_cmd) -f docker-compose.yaml exec -T app php artisan xboard:update || warn "升级命令异常，请手动检查。"

    info "升级服务完成！"
}

# ---- 3. 停止服务 ----
pause_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的 XBoard，请先执行 [1] 一键部署。"
        return
    fi

    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yaml stop || true
    info "服务已停止。"
}

# ---- 4. 重启服务 ----
restart_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到运行中的 XBoard，请先执行 [1] 一键部署。"
        return
    fi

    cd "$workdir" || return
    fix_xboard_image
    $(docker_compose_cmd) -f docker-compose.yaml restart || true
    info "服务已重启。"
}

# ---- 5. 手动备份 ----
do_backup() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法执行备份。"
        return
    fi

    cd "$workdir" || return
    fix_xboard_image

    local backup_dir="${workdir}/backups"
    mkdir -p "$backup_dir"

    local timestamp
    local backup_file
    timestamp=$(date +"%Y%m%d_%H%M%S")
    backup_file="${backup_dir}/xboard_backup_${timestamp}.tar.gz"

    info "开始执行备份..."

    local db_pass
    db_pass=$(grep -oP '^DB_PASSWORD=\K.*' .env)

    if ! $(docker_compose_cmd) -f docker-compose.yaml exec -T mysql mysqldump -uxboard -p"${db_pass}" xboard > ./database_dump.sql; then
        err "数据库导出失败，备份终止。"
        rm -f ./database_dump.sql
        return
    fi

    if [[ ! -s ./database_dump.sql ]]; then
        err "数据库备份文件为空，备份终止。"
        rm -f ./database_dump.sql
        return
    fi

    local target_files="docker-compose.yaml .env database_dump.sql data"

    tar -czf "$backup_file" $target_files || {
        err "打包失败，备份终止。"
        rm -f ./database_dump.sql
        return
    }

    rm -f ./database_dump.sql

    cd "$backup_dir" || return
    ls -t xboard_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f

    info "备份执行完毕。当前可用备份如下："
    for f in $(ls -t xboard_backup_*.tar.gz 2>/dev/null); do
        local abs_path="${backup_dir}/${f}"
        local fsize
        fsize=$(du -h "$f" | cut -f1)
        echo -e "  📦 \033[36m${abs_path}\033[0m (大小: ${fsize})"
    done
}

# ---- 6. 恢复备份 ----
restore_backup() {
    info "== 灾备恢复 / 数据迁入引擎 =="

    local default_backup=""
    local current_wd
    local search_dir

    current_wd=$(get_workdir)
    search_dir="${current_wd:-$DEFAULT_INSTALL_PATH}/backups"

    if [[ -d "$search_dir" ]]; then
        default_backup=$(ls -t "${search_dir}"/xboard_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
    fi

    local backup_path=""
    if [[ -n "$default_backup" ]]; then
        echo -e "已智能嗅探到最新备份快照: \033[33m${default_backup}\033[0m"
        read -r -p "请输入备份文件路径 [直接回车使用默认]: " input_backup
        backup_path=${input_backup:-$default_backup}
    else
        read -r -p "请输入备份文件(.tar.gz)路径: " backup_path
    fi

    if [[ ! -f "$backup_path" ]]; then
        err "目标路径下未找到有效的快照文件，请检查。"
        return
    fi

    read -r -p "请输入恢复到的目标路径 [默认: $DEFAULT_INSTALL_PATH]: " input_path
    local target_dir=${input_path:-$DEFAULT_INSTALL_PATH}

    if [[ -d "$target_dir" && -f "$target_dir/docker-compose.yaml" ]]; then
        warn "目标目录已存在实例，恢复将覆盖现有数据！"
        read -r -p "是否强制覆盖继续？(y/N): " force_override
        if [[ ! "$force_override" =~ ^[Yy]$ ]]; then
            info "已终止恢复流程。"
            return
        fi

        cd "$target_dir" || return
        $(docker_compose_cmd) -f docker-compose.yaml down || true

        rm -rf "$target_dir/data" \
               "$target_dir/mysql_data" \
               "$target_dir/postgres_data" \
               "$target_dir/redis_data" \
               "$target_dir/docker-compose.yaml" \
               "$target_dir/.env" \
               "$target_dir/database_dump.sql"
    fi

    mkdir -p "$target_dir"
    tar -xzf "$backup_path" -C "$target_dir" || {
        err "解压失败，备份包可能损坏。"
        return
    }

    echo "$target_dir" > "/etc/xboard_env"
    cd "$target_dir" || return

    if [[ -d "postgres_data" && ! -d "mysql_data" ]]; then
        warn "检测到旧版 postgres_data，自动改名为 mysql_data。"
        mv postgres_data mysql_data
    fi

    mkdir -p data mysql_data redis_data
    chmod -R 777 data mysql_data redis_data 2>/dev/null || true

    if [[ ! -f "./docker-compose.yaml" || ! -f "./.env" ]]; then
        err "备份包缺少 docker-compose.yaml 或 .env，恢复终止。"
        return
    fi

    fix_xboard_image

    $(docker_compose_cmd) -f docker-compose.yaml up -d || {
        err "恢复启动失败。"
        return
    }

    wait_mysql_ready || return
    wait_app_mysql_ready || return

    if [[ -f "./database_dump.sql" ]]; then
        info "正在导入备份数据库..."

        local db_pass
        db_pass=$(grep -oP '^DB_PASSWORD=\K.*' .env)

        if ! $(docker_compose_cmd) -f docker-compose.yaml exec -T mysql mysql -uxboard -p"${db_pass}" xboard < ./database_dump.sql; then
            err "数据库导入失败，请检查 database_dump.sql。"
            return
        fi

        rm -f ./database_dump.sql
        $(docker_compose_cmd) -f docker-compose.yaml restart app queue schedule || true
    else
        warn "备份包中没有 database_dump.sql，仅恢复了文件和容器配置。"
    fi

    local server_ip
    local restore_port
    server_ip=$(get_local_ip)
    restore_port=$(get_compose_port)

    echo -e "\n=================================================="
    echo -e "\033[32m✅ XBoard 站点恢复完成！\033[0m"
    echo -e "访问地址: \033[36mhttp://${server_ip}:${restore_port}\033[0m"
    echo -e "==================================================\n"
}

# ---- 7. 定时备份 ----
setup_auto_backup() {
    require_cmd crontab
    info "== 定时备份策略管控 =="

    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无法配置定时备份。"
        return
    fi

    local existing_cron=""
    local reset_cron=""
    local cron_type=""
    local cron_spec=""
    local min_interval=""
    local cron_time=""
    local hour=""
    local minute=""
    local tmp_cron=""

    local cron_script="${workdir}/cron_backup.sh"

    existing_cron="$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)"

    if [[ -n "$existing_cron" ]]; then
        echo -e "\033[36m>>> 发现当前正在运行的定时备份任务:\033[0m"
        echo -e "\033[33m${existing_cron}\033[0m"
        echo -e "---------------------------------------------------"
        read -r -p "是否需要重新设置或覆盖该任务？(y/N): " reset_cron
        if [[ ! "$reset_cron" =~ ^[Yy]$ ]]; then
            info "已保留当前配置，操作取消。"
            return
        fi
    else
        echo -e "当前未检测到定时备份任务。"
    fi

    echo " 1) 按固定分钟步进备份（推荐：10/15/20/30/60）"
    echo " 2) 按每日固定时间点备份（例如：每天 04:30）"
    echo " 3) 删除当前的定时备份任务"
    read -r -p "请选择策略 [1/2/3]: " cron_type

    if [[ "$cron_type" == "1" ]]; then
        read -r -p "请输入间隔分钟数 [推荐 10/15/20/30/60]: " min_interval
        if [[ ! "$min_interval" =~ ^[0-9]+$ ]]; then
            err "输入无效，必须是整数。"
            return
        fi
        cron_spec="*/${min_interval} * * * *"
        info "已下发指令：每 ${min_interval} 分钟执行一次。"
    elif [[ "$cron_type" == "2" ]]; then
        read -r -p "请输入每天固定备份时间 (格式 HH:MM): " cron_time
        if [[ ! "$cron_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            err "时间格式不正确。"
            return
        fi
        hour="${cron_time%:*}"
        minute="${cron_time#*:}"
        cron_spec="${minute} ${hour} * * *"
        info "已下发指令：每天 ${cron_time} 执行一次。"
    elif [[ "$cron_type" == "3" ]]; then
        tmp_cron="$(mktemp)" || return
        crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron"
        rm -f "$cron_script"
        info "定时备份任务已被成功清理。"
        return
    else
        err "无效的选择。"
        return
    fi

    info "正在生成定时备份程序..."
    cat > "$cron_script" << EOF
#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"

WORKDIR="${workdir}"
cd "\$WORKDIR" || exit 1

BACKUP_DIR="\${WORKDIR}/backups"
mkdir -p "\$BACKUP_DIR"

TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/xboard_backup_\${TIMESTAMP}.tar.gz"

if command -v docker-compose >/dev/null 2>&1; then
    DC_CMD="docker-compose"
elif docker compose version >/dev/null 2>&1; then
    DC_CMD="docker compose"
else
    echo "[\$(date)] [FATAL] 未检测到 Docker Compose，备份终止。" >> ${BACKUP_LOG}
    exit 1
fi

sed -i 's#ghcr.io/ghcr.io/cedar2025/xboard:latest#ghcr.io/cedar2025/xboard:latest#g' docker-compose.yaml
sed -i 's#image:[[:space:]]*cedar2025/xboard:latest#image: ghcr.io/cedar2025/xboard:latest#g' docker-compose.yaml

DB_PASS=\$(grep -oP '^DB_PASSWORD=\K.*' .env)

if ! \$DC_CMD -f docker-compose.yaml exec -T mysql mysqldump -uxboard -p"\${DB_PASS}" xboard > ./database_dump.sql; then
    echo "[\$(date)] [ERROR] 数据库导出失败，备份终止。" >> ${BACKUP_LOG}
    rm -f ./database_dump.sql
    exit 1
fi

if [[ ! -s ./database_dump.sql ]]; then
    echo "[\$(date)] [ERROR] 数据库备份文件为空，备份终止。" >> ${BACKUP_LOG}
    rm -f ./database_dump.sql
    exit 1
fi

TARGET_FILES="docker-compose.yaml .env database_dump.sql data"

if tar -czf "\$BACKUP_FILE" \$TARGET_FILES; then
    rm -f ./database_dump.sql
    cd "\$BACKUP_DIR" || exit 1
    ls -t xboard_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -r rm -f
    echo "[\$(date)] [INFO] 备份完成：\$BACKUP_FILE" >> ${BACKUP_LOG}
else
    echo "[\$(date)] [ERROR] 打包失败，备份终止。" >> ${BACKUP_LOG}
    rm -f ./database_dump.sql
    exit 1
fi
EOF

    chmod +x "$cron_script"

    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true

    cat >> "$tmp_cron" <<EOF
${CRON_TAG_BEGIN}
${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF

    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron"

    info "新的定时任务已成功注入调度引擎。"
    echo -e "\033[36m底层调度链路已锚定实体文件:\033[0m"
    echo -e "\033[33m${cron_spec} bash ${cron_script} >> ${BACKUP_LOG} 2>&1\033[0m"
}

# ---- 8. 彻底卸载 ----
uninstall_service() {
    local workdir
    workdir=$(get_workdir)
    if [[ -z "$workdir" ]]; then
        err "未检测到部署环境，无需卸载。"
        return
    fi

    echo -e "\033[31m⚠️ 警告：这将彻底删除 XBoard 容器及本地业务数据！\033[0m"
    read -r -p "确认完全卸载？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "操作已取消。"
        return
    fi

    cd "$workdir" || return
    $(docker_compose_cmd) -f docker-compose.yaml down -v || true

    cd /
    rm -rf "$workdir" || true
    rm -f "/etc/xboard_env" || true

    local tmp_cron
    tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$tmp_cron" || true
    crontab "$tmp_cron" 2>/dev/null || true
    rm -f "$tmp_cron" || true

    info "XBoard 容器及本地业务数据已删除。"
}

install_ftp(){
    require_cmd curl
    clear
    echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
    bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
    sleep 2
    exit 0
}

# ---- 交互式主菜单 ----
main_menu() {
    clear
    echo "==================================================="
    echo "                 XBoard 一键管理                 "
    echo "==================================================="
    local wd
    wd=$(get_workdir)
    echo -e " 实例运行路径: \033[36m${wd:-未部署}\033[0m"
    echo "---------------------------------------------------"
    echo "  1) 一键部署"
    echo "  2) 升级服务"
    echo "  3) 停止服务"
    echo "  4) 重启服务"
    echo "  5) 手动备份"
    echo "  6) 恢复备份"
    echo "  7) 定时备份"
    echo "  8) 完全卸载"
    echo "  9) 📂 FTP/SFTP 备份工具"
    echo "  0) 退出脚本"
    echo "==================================================="

    read -r -p "请输入操作序号 [0-9]: " choice
    case "$choice" in
        1) deploy_xboard ;;
        2) upgrade_service ;;
        3) pause_service ;;
        4) restart_service ;;
        5) do_backup ;;
        6) restore_backup ;;
        7) setup_auto_backup ;;
        8) uninstall_service ;;
        9) install_ftp ;;
        0) info "欢迎下次使用，再见!"; exit 0 ;;
        *) warn "无效的指令，请重新输入。" ;;
    esac
}

# 路由引擎
if [[ "${1:-}" == "run-backup" ]]; then
    do_backup
else
    if [[ $EUID -ne 0 ]]; then die "权限收敛：必须使用 Root 权限执行脚本。"; fi
    while true; do
        main_menu
        echo ""
        read -r -p "➤ 按回车键返回主菜单..."
    done
fi
