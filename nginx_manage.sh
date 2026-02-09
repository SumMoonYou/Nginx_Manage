#!/bin/bash
# =============================================================
#  NGINX TURBO MANAGER v5.5 - Enterprise Edition
# =============================================================

export LANG=en_US.UTF-8

# --- 路径定义 ---
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT="/var/www"
CERT_DIR="/etc/nginx/ssl_self"
LE_DIR="/etc/letsencrypt/live"

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && echo "[错误] 请使用 root 权限运行！" && exit 1

# --- 端口放行 ---
open_ports() {
    echo ">> 自动放行 80/443 端口..."
    if command -v ufw &>/dev/null && ufw status | grep -q active; then
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service={http,https} >/dev/null
        firewall-cmd --reload >/dev/null
    else
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    fi
}

draw_header() {
    clear
    echo "==============================================================="
    echo "                NGINX TURBO MANAGER v5.5                        "
    echo "==============================================================="
    echo "  服务状态: $(pgrep nginx >/dev/null && echo "运行中" || echo "已停止")"
    echo "---------------------------------------------------------------"
}

# =============================================================
# SSL Certificate Status Panel
# =============================================================
cert_status_panel() {
    echo ""
    echo "==============================================================="
    echo " 🔐 SSL Certificate Status Panel"
    echo "==============================================================="
    printf "%-30s %-10s %-8s %-10s\n" "Domain" "DaysLeft" "Type" "Status"
    echo "---------------------------------------------------------------"

    check_cert() {
        cert="$1"; domain="$2"; type="$3"
        end_date=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        [ -z "$end_date" ] && return

        end_ts=$(date -d "$end_date" +%s)
        now_ts=$(date +%s)
        days_left=$(( (end_ts - now_ts) / 86400 ))

        if [ "$days_left" -gt 30 ]; then
            status="🟢 OK"
        elif [ "$days_left" -gt 7 ]; then
            status="🟡 WARN"
        else
            status="🔴 EXPIRE"
        fi

        printf "%-30s %-10s %-8s %-10s\n" "$domain" "$days_left" "$type" "$status"
    }

    # Let's Encrypt
    if [ -d "$LE_DIR" ]; then
        for cert in $LE_DIR/*/fullchain.pem; do
            [ -f "$cert" ] || continue
            domain=$(basename "$(dirname "$cert")")
            check_cert "$cert" "$domain" "LE"
        done
    fi

    # Self-signed
    if [ -d "$CERT_DIR" ]; then
        for cert in $CERT_DIR/*/c.pem; do
            [ -f "$cert" ] || continue
            domain=$(basename "$(dirname "$cert")")
            check_cert "$cert" "$domain" "SELF"
        done
    fi

    echo "==============================================================="
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
}

# =============================================================
# 初始化系统
# =============================================================
init_system() {
    echo ">> 初始化系统环境..."

    mkdir -p /etc/nginx

    if command -v apt &>/dev/null; then
        DEFAULT_USER="www-data"
        apt update
        apt install -y --reinstall nginx-common
        apt install -y nginx certbot python3-certbot-nginx openssl
        apt --fix-broken install -y
    else
        DEFAULT_USER="nginx"
        yum install -y epel-release nginx certbot python3-certbot-nginx openssl
    fi

    # 修复 mime.types
    if [ ! -f /etc/nginx/mime.types ]; then
        cat > /etc/nginx/mime.types <<EOF
types {
    text/html html htm;
    text/css css;
    application/javascript js;
    image/png png;
    image/jpeg jpg jpeg;
}
EOF
    fi

    open_ports
    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CONF_ENABLED" "$WEB_ROOT" "$CERT_DIR"

    cat > /etc/nginx/nginx.conf <<EOF
user $DEFAULT_USER;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    # certbot cron
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "30 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

    systemctl enable nginx
    systemctl restart nginx
    echo ">> 初始化完成"
}

# =============================================================
# 添加站点
# =============================================================
add_site() {
    read -p "请输入域名: " domain
    [ -z "$domain" ] && return

    site_path="$WEB_ROOT/$domain"
    conf_file="$NGINX_CONF_DIR/$domain.conf"
    sc="$CERT_DIR/$domain"
    mkdir -p "$site_path" "$sc"
    echo "<h1>$domain working</h1>" > "$site_path/index.html"

    echo "SSL 选项: 1=自动LE  2=粘贴证书  3=100年自签"
    read -p "选择: " ssl_choice

    case $ssl_choice in
        1)
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"; do_certbot="y"
            ;;
        2)
            echo "粘贴CRT Ctrl+D结束"
            cat > "$sc/local_cert.pem"
            echo "粘贴KEY Ctrl+D结束"
            cat > "$sc/local_key.pem"
            final_c="$sc/local_cert.pem"; final_k="$sc/local_key.pem"
            ;;
        *)
            openssl req -x509 -nodes -days 36500 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"
            ;;
    esac

    cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $domain;
    ssl_certificate $final_c;
    ssl_certificate_key $final_k;
    root $site_path;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

    ln -sf "$conf_file" "$NGINX_CONF_ENABLED/$domain.conf"

    if nginx -t; then
        systemctl reload nginx
        if [ "$do_certbot" == "y" ]; then
            read -p "输入邮箱: " mail
            certbot --nginx -d "$domain" -m "$mail" --agree-tos --non-interactive
        fi
        systemctl reload nginx
        echo "站点已启用"
    else
        echo "配置错误已回滚"
        rm -f "$NGINX_CONF_ENABLED/$domain.conf"
    fi
}

# =============================================================
# 卸载
# =============================================================
uninstall() {
    read -p "确认深度卸载? y/n: " confirm
    [ "$confirm" != "y" ] && return

    systemctl stop nginx
    if command -v apt &>/dev/null; then
        apt purge -y nginx nginx-common certbot
        apt autoremove -y
    else
        yum remove -y nginx certbot
    fi
    rm -rf /etc/nginx /var/www /etc/letsencrypt "$CERT_DIR"
    crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
    echo "卸载完成"
    exit 0
}

# =============================================================
# 菜单
# =============================================================
while true; do
    draw_header
    echo "1) 初始化环境"
    echo "2) 站点列表"
    echo "3) 添加站点"
    echo "4) 删除站点"
    echo "5) 重启 Nginx"
    echo "6) 深度卸载"
    echo "12) SSL Certificate Status Panel"
    echo "0) 退出"
    echo "---------------------------------------------------------------"
    read -p "请选择: " choice

    case $choice in
        1) init_system ;;
        2) ls "$NGINX_CONF_ENABLED" ;;
        3) add_site ;;
        4) read -p "输入域名: " d; rm -f "$NGINX_CONF_DIR/$d.conf" "$NGINX_CONF_ENABLED/$d.conf"; nginx -t && systemctl reload nginx ;;
        5) systemctl restart nginx ;;
        6) uninstall ;;
        12) cert_status_panel ;;
        0) exit 0 ;;
    esac
done
