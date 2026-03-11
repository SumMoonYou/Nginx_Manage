#!/bin/bash

# ==============================================================
#  NGINX MANAGER
# ==============================================================
# 该脚本用于管理 Nginx 服务，包括环境初始化、SSL 配置、站点管理、重启服务、以及深度卸载等功能。
# 支持自动修复 Nginx 配置、安装相关依赖、自动配置 SSL 证书等。
# ==============================================================

export LANG=en_US.UTF-8

# 颜色设置，用于美化输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'  # No Color

# --- 路径定义 ---
NGINX_CONF_DIR="/etc/nginx/sites-available"        # Nginx 配置文件存放目录
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"      # Nginx 启用站点的目录
WEB_ROOT="/var/www"                                # 网站根目录
CERT_DIR="/etc/nginx/ssl_self"                     # SSL 证书存放目录

# --- 权限检查 ---
# 确保脚本以 root 用户身份运行
[[ $EUID -ne 0 ]] && echo -e "${RED}[错误] 请使用 root 权限运行！${NC}" && exit 1

# --- 端口放行 ---
# 自动放行 80 和 443 端口
open_ports() {
    echo -e "${CYAN}>> 正在自动放行 80/443 端口...${NC}"
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        # 如果使用 ufw 管理防火墙，放行 80 和 443 端口
        ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        # 如果使用 firewalld 管理防火墙，放行 http 和 https 服务
        firewall-cmd --permanent --add-service={http,https} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null
    else
        # 使用 iptables 放行端口
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
    fi
}

# 打印头部信息，清屏并显示菜单标题
draw_header() {
    clear
    echo -e "${BLUE}==============================================================="
    echo -e "${WHITE}                   NGINX 管理工具                        ${NC}"
    echo -e "${BLUE}==============================================================="
    echo -e "${CYAN}  服务状态: $(pgrep nginx >/dev/null && echo "运行中" || echo "已停止")${NC}"
    echo -e "${WHITE}---------------------------------------------------------------${NC}"
}

# --- 核心修复：初始化逻辑 ---
# 该函数会安装 Nginx 及其依赖，并进行必要的修复和配置
init_system() {
    echo -e "${CYAN}>> 正在准备系统环境...${NC}"

    # 预防性措施：确保 Nginx 配置目录存在，防止安装过程中找不到目录
    mkdir -p /etc/nginx

    # 根据操作系统的包管理器选择不同的安装方式
    if command -v apt &>/dev/null; then 
        PKG_MGR="apt"; DEFAULT_USER="www-data"  # 对于 Debian/Ubuntu 系统
        apt update
        apt install -y --reinstall nginx-common  # 重新安装 nginx-common
        apt install -y nginx certbot python3-certbot-nginx openssl  # 安装 Nginx、Certbot 和 OpenSSL
        apt --fix-broken install -y  # 自动修复未完成的安装
    else 
        PKG_MGR="yum"; DEFAULT_USER="nginx"  # 对于 CentOS/RHEL 系统
        yum install -y epel-release nginx certbot python3-certbot-nginx openssl
    fi

    # 紧急补丁：如果 mime.types 文件丢失，则手动创建该文件
    if [ ! -f /etc/nginx/mime.types ]; then
        echo -e "${CYAN}>> 检测到关键文件 mime.types 丢失，正在手动补全...${NC}"
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

    # 清理可能存在的 acme.sh 冲突
    crontab -l 2>/dev/null | grep "acme.sh" && crontab -l | grep -v "acme.sh" | crontab -
    
    # 确保必需的目录存在
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

    # 设置 Certbot 证书续签任务
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "30 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    
    # 启动并重启 Nginx 服务
    systemctl enable nginx && systemctl restart nginx
    echo -e "${GREEN}>> 环境初始化完成，服务已恢复正常。${NC}"
}

# 添加站点的函数
add_site() {
    read -p "请输入域名: " domain
    [[ -z "$domain" ]] && return  # 如果没有输入域名，则跳过

    site_path="$WEB_ROOT/$domain"
    conf_file="$NGINX_CONF_DIR/$domain.conf"
    sc="$CERT_DIR/$domain"
    mkdir -p "$site_path" "$sc"
    echo "<h1>$domain working</h1>" > "$site_path/index.html"

    # 提供 SSL 配置选项
    echo -e "\nSSL 选项: 1.自动申请 | 2.粘贴内容 | 3.仅自签"
    read -p "选择: " ssl_choice

    case $ssl_choice in
        1)
            # 自动生成证书
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"; do_certbot="y"
            ;;
        2)
            # 用户粘贴证书和私钥
            echo "--- 粘贴证书内容 (CRT)，按 Ctrl+D 结束 ---"
            cat > "$sc/local_cert.pem"
            echo "--- 粘贴私钥内容 (KEY)，按 Ctrl+D 结束 ---"
            cat > "$sc/local_key.pem"
            final_c="$sc/local_cert.pem"; final_k="$sc/local_key.pem"
            ;;
        3)
            # 自签证书
            echo "--- 仅自签证书生成中 ---"
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"
            do_certbot="n"  # 不调用 Certbot
            ;;
        *)
            echo -e "${RED}[错误] 无效的选择，跳过 SSL 配置${NC}"
            return
            ;;
    esac

    # 写入站点的 Nginx 配置文件
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

    # 测试配置文件是否正确，并重启 Nginx 服务
    if nginx -t; then
        systemctl reload nginx
        # 如果选择了 Certbot，则执行证书申请
        if [[ "$do_certbot" == "y" ]]; then
            read -p "请输入邮箱地址: " mail
            certbot --nginx -d "$domain" -m "$mail" --agree-tos --non-interactive
            systemctl reload nginx
        fi
        echo -e "${GREEN}[成功] 站点已启用。${NC}"
    else
        echo -e "${RED}[错误] Nginx 校验失败，已回滚。请检查 SSL 内容是否粘贴完整。${NC}"
        rm -f "$NGINX_CONF_ENABLED/$domain.conf"
    fi
}

# 卸载函数
uninstall() {
    read -p "确定要彻底清理 Nginx 环境吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        # 停止 Nginx 服务，并卸载相关包
        systemctl stop nginx 2>/dev/null
        if command -v apt &>/dev/null; then
            apt purge -y nginx nginx-common nginx-full certbot
            apt autoremove -y
        else
            yum remove -y nginx certbot
        fi
        # 删除相关目录和配置文件
        rm -rf /etc/nginx /var/www /etc/letsencrypt "$CERT_DIR"
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        echo -e "${YELLOW}深度卸载完成。${NC}"
        exit 0
    fi
}

# 主菜单循环
while true; do
    draw_header
    echo -e "${GREEN}  1. 环境初始化${NC}"
    echo -e "${GREEN}  2. 站点列表${NC}"
    echo -e "${GREEN}  3. 添加站点${NC}"
    echo -e "${GREEN}  4. 删除站点${NC}"
    echo -e "${GREEN}  5. 重启服务${NC}"
    echo -e "${GREEN}  6. 深度卸载${NC}"
    echo -e "${RED}  0. 退出${NC}"
    echo -e "${WHITE}---------------------------------------------------------------${NC}"
    read -p "请选择: " choice
    case $choice in
        1) init_system; read -n 1 -s -r -p "按任意键继续..." ;;
        2) echo -e "${CYAN}已启用域名:"; for f in "$NGINX_CONF_ENABLED"/*.conf; do [ -e "$f" ] && echo " - $(basename "$f" .conf)"; done; read -n 1 -s -r -p "按任意键继续..." ;;
        3) add_site; read -n 1 -s -r -p "按任意键继续..." ;;
        4) read -p "输入要删除的域名: " d; rm -f "$NGINX_CONF_DIR/$d.conf" "$NGINX_CONF_ENABLED/$d.conf"; nginx -t && systemctl reload nginx; echo -e "${CYAN}已移除${NC}"; sleep 1 ;;
        5) systemctl restart nginx && echo -e "${CYAN}重启成功${NC}" || echo -e "${RED}重启失败${NC}"; sleep 1 ;;
        6) uninstall ;;
        0) exit 0 ;;
    esac
done
