#!/bin/bash
# ==========================
# Nginx 一键管理脚本
# Version: 1.9
# 功能: 安装/单站/批量添加/删除/卸载/自动续期/防火墙放行/开机自启/输出网站信息/80+443监听
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

# 检测系统类型及版本
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
        DEBIAN_VERSION=$(lsb_release -r | awk '{print $2}')
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="redhat"
        REDHAT_VERSION=$(rpm -E %{rhel})
    elif [[ $(command -v dnf) ]]; then
        OS_TYPE="fedora"
    else
        echo "不支持的操作系统"
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
            if command -v service &>/dev/null && service iptables status &>/dev/null; then
                service iptables save
            fi
        fi
    fi
}

# 安装 Nginx 与 Certbot
install_nginx() {
    detect_os
    if ! command -v nginx &>/dev/null; then
        echo "正在安装 Nginx..."
        case "$OS_TYPE" in
            debian)
                if [[ "$DEBIAN_VERSION" < "9" ]]; then
                    # 低版本 Debian 安装源
                    apt update
                    apt install -y nginx openssl certbot python-certbot-nginx
                else
                    apt update
                    apt install -y nginx openssl certbot python3-certbot-nginx
                fi
                ;;
            redhat)
                if [[ "$REDHAT_VERSION" -eq 7 ]]; then
                    # CentOS 7 系统兼容
                    yum install -y epel-release
                    yum install -y nginx openssl certbot python2-certbot-nginx
                else
                    yum install -y nginx openssl certbot python3-certbot-nginx
                fi
                ;;
            fedora)
                dnf install -y nginx openssl certbot python3-certbot-nginx
                ;;
        esac
        echo "Nginx 安装完成"
    else
        echo "Nginx 已安装"
    fi

    systemctl enable nginx
    systemctl start nginx

    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CONF_ENABLED"
    open_firewall_ports
}

# 设置 Certbot 自动续期
setup_cert_renewal() {
    if command -v certbot &>/dev/null; then
        echo "设置 Certbot 自动续期任务..."
        cron_job="0 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"
        crontab -l 2>/dev/null | grep -F "$cron_job" >/dev/null || (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        echo "自动续期任务已设置，每天 2:00 检查证书并重载 Nginx"
    fi
}

# 输出网站信息函数
show_site_info() {
    local domain="$1"
    local site_root="$2"
    local conf_file="$3"
    local port="$4"
    local cert_choice="$5"
    local ssl_dir="$6"

    echo
    echo "====== 网站信息 ======"
    echo "域名: $domain"
    echo "网站根目录: $site_root"
    echo "Nginx 配置文件: $conf_file"
    if [[ "$port" == "443" || "$port" == "80+443" ]]; then
        if [[ "$cert_choice" == 1 ]]; then
            echo "证书类型: 自签"
            echo "证书文件: $ssl_dir/$domain.crt"
            echo "私钥文件: $ssl_dir/$domain.key"
        else
            echo "证书类型: Let’s Encrypt"
            echo "证书文件: /etc/letsencrypt/live/$domain/fullchain.pem"
            echo "私钥文件: /etc/letsencrypt/live/$domain/privkey.pem"
        fi
    fi
    echo "====================="
}

# 添加单个网站
add_site() {
    read -p "请输入网站域名: " domain
    site_root="$WEB_ROOT/$domain"

    if [[ -d "$site_root" ]]; then
        echo "网站目录已存在: $site_root"
        return
    fi

    mkdir -p "$site_root"
    echo "<h1>欢迎访问 $domain</h1>" > "$site_root/index.html"

    echo "请选择监听端口: "
    echo "1) 80"
    echo "2) 443"
    echo "3) 80+443"
    read -p "请输入选项 [1-3]: " port_choice

    case "$port_choice" in
        1) port=80 ;;
        2) port=443 ;;
        3) port="80+443" ;;
        *) echo "无效选项"; return ;;
    esac

    conf_file="$NGINX_CONF_DIR/$domain.conf"
    SSL_DIR="/etc/ssl/$domain"
    mkdir -p "$SSL_DIR"

    # 生成 Nginx 配置
    if [[ "$port" == "80" ]]; then
        cat > "$conf_file" <<EOL
server {
    listen 80;
    server_name $domain;

    root $site_root;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL

    elif [[ "$port" == "443" ]]; then
        echo "请选择证书类型:"
        echo "1) 自签证书"
        echo "2) Let’s Encrypt 自动申请"
        read -p "请输入选项 [1-2]: " cert_choice

        if [[ "$cert_choice" == 1 ]]; then
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$SSL_DIR/$domain.key" \
                -out "$SSL_DIR/$domain.crt" \
                -subj "/CN=$domain"
            cat > "$conf_file" <<EOL
server {
    listen 443 ssl;
    server_name $domain;

    root $site_root;
    index index.html;

    ssl_certificate $SSL_DIR/$domain.crt;
    ssl_certificate_key $SSL_DIR/$domain.key;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL
        else
            certbot --nginx -d "$domain" --non-interactive --agree-tos -m admin@$domain
            cert_choice=2
        fi
    elif [[ "$port" == "80+443" ]]; then
        echo "请选择证书类型:"
        echo "1) 自签证书"
        echo "2) Let’s Encrypt 自动申请"
        read -p "请输入选项 [1-2]: " cert_choice

        # HTTP server 块
        cat > "$conf_file" <<EOL
server {
    listen 80;
    server_name $domain;

    root $site_root;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL

        # HTTPS server 块
        if [[ "$cert_choice" == 1 ]]; then
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$SSL_DIR/$domain.key" \
                -out "$SSL_DIR/$domain.crt" \
                -subj "/CN=$domain"
            cat >> "$conf_file" <<EOL
server {
    listen 443 ssl;
    server_name $domain;

    root $site_root;
    index index.html;

    ssl_certificate $SSL_DIR/$domain.crt;
    ssl_certificate_key $SSL_DIR/$domain.key;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOL
        else
            certbot --nginx -d "$domain" --non-interactive --agree-tos -m admin@$domain
            cert_choice=2
        fi
    fi

    ln -s "$conf_file" "$NGINX_CONF_ENABLED/$domain.conf" 2>/dev/null || true
    nginx -t && systemctl reload nginx
    open_firewall_ports
    show_site_info "$domain" "$site_root" "$conf_file" "$port" "$cert_choice" "$SSL_DIR"

    # 自动续期
    if [[ "$port" == "443" || "$port" == "80+443" ]] && [[ "$cert_choice" == 2 ]]; then
        setup_cert_renewal
    fi
}

# 主菜单
echo "====== Nginx 一键管理 v1.9 ======"
echo "1) 安装 Nginx"
echo "2) 添加单个网站"
echo "3) 批量添加网站"
echo "4) 删除网站"
echo "5) 卸载 Nginx"
echo "6) 退出"
read -p "请选择操作 [1-6]: " choice
case "$choice" in
    1) install_nginx; setup_cert_renewal ;;
    2) add_site ;;
    3) add_sites_batch ;;
    4) delete_site ;;
    5) uninstall_nginx ;;
    6) exit 0 ;;
    *) echo "无效选择"; exit 1 ;;
esac
