#!/bin/bash

# =============================================================
#  NGINX TURBO MANAGER v5.4 - AUTO FIX & ROBUST EDITION
# =============================================================

export LANG=en_US.UTF-8

# --- 路径定义 ---
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT="/var/www"
CERT_DIR="/etc/nginx/ssl_self"

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && echo "[错误] 请使用 root 权限运行！" && exit 1

# --- 端口放行 ---
open_ports() {
    echo ">> 正在自动放行 80/443 端口..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service={http,https} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null
    else
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    fi
}

draw_header() {
    clear
    echo "==============================================================="
    echo "                   NGINX 管理工具 v5.4                         "
    echo "==============================================================="
    echo "  服务状态: $(pgrep nginx >/dev/null && echo "运行中" || echo "已停止")"
    echo "---------------------------------------------------------------"
}

# --- 核心修复：初始化逻辑 ---
init_system() {
    echo ">> 正在准备系统环境..."
    
    # 预防性措施：确保 Nginx 目录存在，防止安装脚本因找不到目录报错
    mkdir -p /etc/nginx
    
    # 安装基础组件
    if command -v apt &>/dev/null; then 
        PKG_MGR="apt"; DEFAULT_USER="www-data"
        apt update
        # 使用 --reinstall 确保即使已安装但损坏的文件也能被找回
        apt install -y --reinstall nginx-common
        apt install -y nginx certbot python3-certbot-nginx openssl
        apt --fix-broken install -y  # 自动修复未完成的安装
    else 
        PKG_MGR="yum"; DEFAULT_USER="nginx"
        yum install -y epel-release nginx certbot python3-certbot-nginx openssl
    fi
    
    # 针对你遇到的 mime.types 丢失问题的紧急补丁
    if [ ! -f /etc/nginx/mime.types ]; then
        echo ">> 检测到关键文件 mime.types 丢失，正在手动补全..."
        cat > /etc/nginx/mime.types <<EOF
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    text/plain                            txt;
    image/png                             png;
    image/svg+xml                         svg svgz;
    application/json                      json;
    application/zip                       zip;
    application/pdf                       pdf;
    application/octet-stream              bin exe dll;
}
EOF
    fi

    # 清理 acme.sh 冲突
    crontab -l 2>/dev/null | grep "acme.sh" && crontab -l | grep -v "acme.sh" | crontab -
    
    open_ports
    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CONF_ENABLED" "$WEB_ROOT" "$CERT_DIR"
    
    # 写入主配置文件
    cat > /etc/nginx/nginx.conf <<EOF
user $DEFAULT_USER;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
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

    # 写入定时续签任务
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "30 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    
    systemctl enable nginx && systemctl restart nginx
    echo ">> 环境初始化完成，服务已恢复正常。"
}

add_site() {
    read -p "请输入域名: " domain
    [[ -z "$domain" ]] && return
    
    site_path="$WEB_ROOT/$domain"
    conf_file="$NGINX_CONF_DIR/$domain.conf"
    sc="$CERT_DIR/$domain"
    mkdir -p "$site_path" "$sc"
    echo "<h1>$domain working</h1>" > "$site_path/index.html"

    echo -e "\nSSL 选项: 1.自动申请 | 2.粘贴内容 | 3.仅自签"
    read -p "选择: " ssl_choice

    case $ssl_choice in
        1)
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"; do_certbot="y"
            ;;
        2)
            echo "--- 粘贴证书内容 (CRT)，按 Ctrl+D 结束 ---"
            cat > "$sc/local_cert.pem"
            echo "--- 粘贴私钥内容 (KEY)，按 Ctrl+D 结束 ---"
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
        if [[ "$do_certbot" == "y" ]]; then
            read -p "输入邮箱: " mail
            certbot --nginx -d "$domain" -m "$mail" --agree-tos --non-interactive
            systemctl reload nginx
        fi
        echo -e "\n[成功] 站点已启用。"
    else
        echo "[错误] Nginx 校验失败，已回滚。请检查 SSL 内容是否粘贴完整。"
        rm -f "$NGINX_CONF_ENABLED/$domain.conf"
    fi
}

uninstall() {
    read -p "确定要彻底清理 Nginx 环境吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nginx 2>/dev/null
        if command -v apt &>/dev/null; then
            apt purge -y nginx nginx-common nginx-full certbot
            apt autoremove -y
        else
            yum remove -y nginx certbot
        fi
        rm -rf /etc/nginx /var/www /etc/letsencrypt "$CERT_DIR"
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        echo "深度卸载完成。"
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
    read -p "请选择: " choice
    case $choice in
        1) init_system; read -n 1 -s -r -p "按任意键继续..." ;;
        2) echo "已启用域名:"; for f in "$NGINX_CONF_ENABLED"/*.conf; do [ -e "$f" ] && echo " - $(basename "$f" .conf)"; done; read -n 1 -s -r -p "按任意键继续..." ;;
        3) add_site; read -n 1 -s -r -p "按任意键继续..." ;;
        4) read -p "输入要删除的域名: " d; rm -f "$NGINX_CONF_DIR/$d.conf" "$NGINX_CONF_ENABLED/$d.conf"; nginx -t && systemctl reload nginx; echo "已移除"; sleep 1 ;;
        5) systemctl restart nginx && echo "重启成功" || echo "重启失败"; sleep 1 ;;
        6) uninstall ;;
        0) exit 0 ;;
    esac
done
