#!/bin/bash

# =============================================================
#  NGINX TURBO MANAGER v5.1 - AUTO PORT OPENING
# =============================================================

export LANG=en_US.UTF-8
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT="/var/www"
CERT_DIR="/etc/nginx/ssl_self"

[[ $EUID -ne 0 ]] && echo "[ERROR] 请使用 root 权限运行！" && exit 1

# ----------------- 自动放行端口 -----------------
open_ports() {
    echo ">> 正在检查并放行 80/443 端口..."
    
    # 1. 如果是 UFW (Ubuntu/Debian)
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        echo "   [UFW] 端口已放行"
    
    # 2. 如果是 FirewallD (CentOS/RHEL)
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=http >/dev/null 2>&1
        firewall-cmd --permanent --add-service=https >/dev/null 2>&1
        firewall-cmd --reload >/dev/null
        echo "   [FirewallD] 端口已放行"
    
    # 3. 如果是 iptables (通用)
    else
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        echo "   [iptables] 规则已添加"
    fi
}

draw_header() {
    clear
    echo "==============================================================="
    echo "                   NGINX 管理工具 v5.1                         "
    echo "==============================================================="
    echo "  状态: $(pgrep nginx >/dev/null && echo "运行中" || echo "未启动")"
    echo "---------------------------------------------------------------"
}

init_system() {
    echo ">> 安装/修复环境中..."
    if command -v apt &>/dev/null; then 
        PKG_MGR="apt"; DEFAULT_USER="www-data"
        apt update && apt install -y nginx certbot python3-certbot-nginx openssl
    else 
        PKG_MGR="yum"; DEFAULT_USER="nginx"
        yum install -y epel-release nginx certbot python3-certbot-nginx openssl
    fi
    
    # 清理 acme.sh 冲突
    crontab -l 2>/dev/null | grep "acme.sh" && crontab -l | grep -v "acme.sh" | crontab - && echo ">> 已清理 acme 冲突"
    
    open_ports
    
    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CONF_ENABLED" "$WEB_ROOT" "$CERT_DIR"
    
    cat > /etc/nginx/nginx.conf <<EOF
user $DEFAULT_USER;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
http {
    include /etc/nginx/mime.types;
    sendfile on;
    keepalive_timeout 65;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "30 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    systemctl enable nginx && systemctl restart nginx
    echo ">> 初始化完成。"
}

add_site() {
    read -p "请输入域名: " domain
    [[ -z "$domain" ]] && return
    
    site_path="$WEB_ROOT/$domain"
    conf_file="$NGINX_CONF_DIR/$domain.conf"
    sc="$CERT_DIR/$domain"
    mkdir -p "$site_path" "$sc"
    echo "<html><body style='text-align:center;'><h1>$domain</h1><p>Nginx Manager v5.1</p></body></html>" > "$site_path/index.html"

    echo -e "\n请选择 SSL 证书来源:"
    echo "1. 自动申请 (Let's Encrypt)"
    echo "2. 粘贴证书内容 (Manual Paste)"
    echo "3. 仅使用自签证书"
    read -p "选择 [1-3]: " ssl_choice

    case $ssl_choice in
        1)
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"; do_certbot="y"
            ;;
        2)
            echo "--- 请粘贴 证书 (CRT/PEM) 内容，按 Ctrl+D 结束 ---"
            cat > "$sc/local_cert.pem"
            echo "--- 请粘贴 私钥 (KEY) 内容，按 Ctrl+D 结束 ---"
            cat > "$sc/local_key.pem"
            final_c="$sc/local_cert.pem"; final_k="$sc/local_key.pem"
            ;;
        *)
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
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
    listen 443 ssl;
    http2 on;
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
        if [[ "$do_certbot" == "y" ]]; then
            read -p "输入邮箱用于申请证书: " mail
            certbot --nginx -d "$domain" -m "$mail" --agree-tos --non-interactive
            systemctl reload nginx
        fi
        open_ports
        echo -e "\n[配置摘要]\n目录: $site_path\n配置: $conf_file\n证书: $sc\n"
    else
        echo "[ERROR] Nginx 配置校验失败！"
        rm -f "$NGINX_CONF_ENABLED/$domain.conf"
    fi
}

uninstall() {
    read -p "确定深度卸载？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nginx 2>/dev/null
        command -v apt &>/dev/null && apt purge -y nginx certbot || yum remove -y nginx certbot
        rm -rf /etc/nginx /var/www /etc/letsencrypt "$CERT_DIR"
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        echo "清理完毕。"
        exit 0
    fi
}

while true; do
    draw_header
    echo "  1. 环境初始化"
    echo "  2. 站点列表"
    echo "  3. 添加站点"
    echo "  4. 删除站点"
    echo "  5. 重启服务"
    echo "  6. 深度卸载"
    echo "  0. 退出"
    echo "---------------------------------------------------------------"
    read -p "选择: " choice
    case $choice in
        1) init_system; read -n 1 -s -r -p "按任意键继续..." ;;
        2) echo "-----------------"; for f in "$NGINX_CONF_ENABLED"/*.conf; do [ -e "$f" ] && echo "域名: $(basename "$f" .conf)"; done; read -n 1 -s -r -p "按任意键继续..." ;;
        3) add_site; read -n 1 -s -r -p "按任意键继续..." ;;
        4) read -p "域名: " d; rm -f "$NGINX_CONF_DIR/$d.conf" "$NGINX_CONF_ENABLED/$d.conf"; nginx -t && systemctl reload nginx; echo "已移除"; sleep 1 ;;
        5) nginx -t && systemctl restart nginx; echo "重启成功"; sleep 1 ;;
        6) uninstall ;;
        0) exit 0 ;;
    esac
done
