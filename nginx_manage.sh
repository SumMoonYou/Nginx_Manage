#!/bin/bash

# ==========================
# Nginx 一键管理脚本 v2.2
# 功能:
# 安装/单站/批量添加 (预留)/删除/卸载/自动续期/防火墙/显示网站信息
# 支持: Debian/Ubuntu, CentOS/RHEL/AlmaLinux/RockyLinux, Fedora
# ==========================

NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT="/var/www"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 用户运行此脚本"
   exit 1
fi

# 检测系统类型
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="redhat"
    elif command -v dnf &>/dev/null; then
        OS_TYPE="fedora"
    else
        echo "不支持的系统"
        exit 1
    fi
}

# 开放防火墙端口
open_firewall_ports() {
    detect_os
    if [[ "$OS_TYPE" == "debian" ]]; then
        if command -v ufw &>/dev/null; then
            ufw allow 80
            ufw allow 443
            ufw reload
        fi
    else
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            firewall-cmd --reload
        else
            iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT
            command -v service &>/dev/null && service iptables save 2>/dev/null
        fi
    fi
}

# 显示常用命令
show_nginx_commands() {
    echo "Nginx 常用命令："
    echo "systemctl start nginx"
    echo "systemctl stop nginx"
    echo "systemctl restart nginx"
    echo "systemctl reload nginx"
    echo "nginx -t   # 检查配置"
    echo "tail -f /var/log/nginx/error.log"
}

# 安装 Nginx + Certbot
install_nginx() {
    detect_os

    if ! command -v nginx &>/dev/null; then
        echo "正在安装 Nginx..."

        case "$OS_TYPE" in
            debian)
                apt update
                apt install -y nginx openssl certbot python3-certbot-nginx
                ;;

            redhat)
                yum install -y epel-release
                yum install -y nginx openssl certbot python3-certbot-nginx
                ;;

            fedora)
                dnf install -y nginx openssl certbot python3-certbot-nginx
                ;;
        esac
    fi

    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CONF_ENABLED"
    systemctl enable nginx
    systemctl start nginx
    open_firewall_ports
    show_nginx_commands
}

# 自动续期
setup_cert_renewal() {
    if command -v certbot &>/dev/null; then
        cron_job="0 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"
        crontab -l 2>/dev/null | grep -F "$cron_job" >/dev/null || \
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    fi
}

# 显示网站信息
show_site_info() {
    local domain="$1"
    local site_root="$2"
    local conf_file="$3"
    local port="$4"
    local cert_type="$5"

    echo "====== 网站信息 ======"
    echo "域名: $domain"
    echo "根目录: $site_root"
    echo "配置文件: $conf_file"

    if [[ "$port" == "443" || "$port" == "80+443" ]]; then
        if [[ "$cert_type" == "self" ]]; then
            echo "证书类型: 自签"
            echo "证书: /etc/ssl/$domain/$domain.crt"
        else
            echo "证书类型: Let’s Encrypt"
            echo "证书: /etc/letsencrypt/live/$domain/"
        fi
    fi

    echo "======================="
}

# 添加网站
add_site() {
    read -p "请输入域名: " domain
    site_root="$WEB_ROOT/$domain"
    mkdir -p "$site_root"
    echo "<h1>Welcome $domain</h1>" > "$site_root/index.html"

    echo "选择端口:"
    echo "1) 80"
    echo "2) 443"
    echo "3) 80+443"
    read -p "选择 [1-3]: " port_choice

    case "$port_choice" in
        1) port="80" ;;
        2) port="443" ;;
        3) port="80+443" ;;
        *) echo "无效选项"; return ;;
    esac

    conf_file="$NGINX_CONF_DIR/$domain.conf"
    SSL_DIR="/etc/ssl/$domain"
    mkdir -p "$SSL_DIR"

    # ---- 80 ----
    if [[ "$port" == "80" ]]; then
        cat > "$conf_file" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    root $site_root;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    # ---- HTTPS ----
    if [[ "$port" == "443" || "$port" == "80+443" ]]; then
        echo "选择证书类型:"
        echo "1) 自签证书"
        echo "2) Let’s Encrypt"
        read -p "选择 [1-2]: " cert_choice

        if [[ "$port" == "80+443" ]]; then
            cat > "$conf_file" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    root $site_root;

    location / { try_files \$uri \$uri/ =404; }
}
EOF
        fi

        if [[ "$cert_choice" == 1 ]]; then
            cert_type="self"
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$SSL_DIR/$domain.key" \
                -out "$SSL_DIR/$domain.crt" \
                -subj "/CN=$domain"

            cat >> "$conf_file" <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $domain;

    ssl_certificate $SSL_DIR/$domain.crt;
    ssl_certificate_key $SSL_DIR/$domain.key;

    root $site_root;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

        else
            cert_type="letsencrypt"
            certbot --nginx -d "$domain" --agree-tos --register-unsafely-without-email --non-interactive
        fi
    fi

    ln -s "$conf_file" "$NGINX_CONF_ENABLED/$domain.conf" 2>/dev/null || true
    nginx -t && systemctl reload nginx
    open_firewall_ports
    [[ "$cert_type" == "letsencrypt" ]] && setup_cert_renewal

    show_site_info "$domain" "$site_root" "$conf_file" "$port" "$cert_type"
}

# 删除网站
delete_site() {
    echo "====== 删除网站 ======"
    read -p "请输入要删除的域名: " domain

    conf_file="$NGINX_CONF_DIR/$domain.conf"
    enabled_file="$NGINX_CONF_ENABLED/$domain.conf"
    site_root="$WEB_ROOT/$domain"
    ssl_dir="/etc/ssl/$domain"
    le_dir="/etc/letsencrypt/live/$domain"

    if [[ ! -f "$conf_file" ]]; then
        echo "❌ 未找到网站：$domain"
        return
    fi

    echo "将删除:"
    echo "- $conf_file"
    echo "- $enabled_file"
    echo "- $site_root"
    [[ -d "$ssl_dir" ]] && echo "- $ssl_dir"
    [[ -d "$le_dir" ]] && echo "- Let's Encrypt 证书"

    read -p "确认删除？(y/N): " confirm
    [[ "$confirm" != "y" ]] && echo "取消。" && return

    rm -f "$conf_file" "$enabled_file"
    rm -rf "$site_root"
    rm -rf "$ssl_dir"

    if [[ -d "$le_dir" ]]; then
        rm -rf "/etc/letsencrypt/live/$domain"
        rm -rf "/etc/letsencrypt/archive/$domain"
        rm -f "/etc/letsencrypt/renewal/$domain.conf"
    fi

    nginx -t && systemctl reload nginx
    echo "✅ $domain 已删除"
}

# 卸载 Nginx
uninstall_nginx() {
    detect_os
    echo "正在卸载 Nginx..."

    systemctl stop nginx
    systemctl disable nginx

    case "$OS_TYPE" in
        debian) apt purge -y nginx nginx-common ;;
        redhat) yum remove -y nginx ;;
        fedora) dnf remove -y nginx ;;
    esac

    rm -rf /etc/nginx /var/www
    echo "Nginx 已卸载。"
}

# 主菜单
while true; do
echo "====== Nginx 一键管理 v2.2 ======"
echo "1) 安装 Nginx"
echo "2) 添加单个网站"
echo "3) 删除网站"
echo "4) 卸载 Nginx"
echo "5) 退出"
read -p "请选择操作 [1-5]: " choice

case "$choice" in
    1) install_nginx ;;
    2) add_site ;;
    3) delete_site ;;
    4) uninstall_nginx ;;
    5) exit 0 ;;
    *) echo "无效选择" ;;
esac

echo
done
