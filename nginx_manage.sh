#!/bin/bash

# =============================================================
#  NGINX TURBO MANAGER v5.3 - FULLY COMMENTED EDITION
# =============================================================

# 设置语言环境为 UTF-8，确保中文不乱码
export LANG=en_US.UTF-8

# --- 路径全局变量定义 ---
NGINX_CONF_DIR="/etc/nginx/sites-available"    # 存放可选的配置文件
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"  # 存放生效的配置文件（软链接）
WEB_ROOT="/var/www"                            # 默认网页存放根目录
CERT_DIR="/etc/nginx/ssl_self"                 # 自签或本地证书存放目录

# --- 权限检查：必须以 root 身份运行 ---
[[ $EUID -ne 0 ]] && echo "[错误] 必须使用 sudo 或 root 账户运行此脚本！" && exit 1

# --- 端口自动放行函数 ---
# 逻辑：自动识别主流防火墙工具并开放 80(HTTP) 和 443(HTTPS)
open_ports() {
    echo ">> 正在检查系统防火墙并尝试放行 80/443 端口..."
    
    # 兼容 UFW (Ubuntu/Debian)
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
        echo "   [UFW] 已放行端口"
    
    # 兼容 FirewallD (CentOS/RHEL)
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service={http,https} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null
        echo "   [FirewallD] 已放行端口"
    
    # 兼容基础 iptables (万能保底方案)
    else
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null
        echo "   [iptables] 已添加放行规则"
    fi
}

# --- 界面头部显示 ---
draw_header() {
    clear
    echo "==============================================================="
    echo "                   NGINX 管理工具 v5.3                         "
    echo "==============================================================="
    echo "  Nginx 状态: $(pgrep nginx >/dev/null && echo "运行中" || echo "未启动")"
    echo "---------------------------------------------------------------"
}

# --- 功能 1：环境初始化 ---
init_system() {
    echo ">> 正在安装必要的软件包 (Nginx, Certbot, OpenSSL)..."
    
    # 根据包管理器判断系统类型 (Ubuntu/CentOS)
    if command -v apt &>/dev/null; then 
        PKG_MGR="apt"; DEFAULT_USER="www-data"
        apt update && apt install -y nginx certbot python3-certbot-nginx openssl
    else 
        PKG_MGR="yum"; DEFAULT_USER="nginx"
        yum install -y epel-release nginx certbot python3-certbot-nginx openssl
    fi
    
    # 关键：清理已存在的 acme.sh 定时任务防止证书冲突
    crontab -l 2>/dev/null | grep "acme.sh" && crontab -l | grep -v "acme.sh" | crontab - && echo ">> 已移除 acme.sh 冲突任务"
    
    # 放行防火墙
    open_ports
    
    # 创建必要的目录结构
    mkdir -p "$NGINX_CONF_DIR" "$NGINX_CONF_ENABLED" "$WEB_ROOT" "$CERT_DIR"
    
    # 覆盖重写主配置文件 nginx.conf，确保 user 指令匹配当前系统
    cat > /etc/nginx/nginx.conf <<EOF
user $DEFAULT_USER;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
http {
    include /etc/nginx/mime.types;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    # 添加 Certbot 自动续签定时任务 (每天 02:30 执行)
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "30 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    
    # 启动并设置开机自启
    systemctl enable nginx && systemctl restart nginx
    echo ">> 环境初始化完成！"
}

# --- 功能 3：添加站点逻辑 ---
add_site() {
    read -p "请输入要托管的域名 (如: example.com): " domain
    [[ -z "$domain" ]] && return
    
    site_path="$WEB_ROOT/$domain"
    conf_file="$NGINX_CONF_DIR/$domain.conf"
    sc="$CERT_DIR/$domain"
    
    # 准备目录和基础 index.html
    mkdir -p "$site_path" "$sc"
    echo "<html><body style='text-align:center;'><h1>$domain</h1><p>Nginx Manager v5.3</p></body></html>" > "$site_path/index.html"

    echo -e "\nSSL 证书选项:\n1. 自动申请 (Let's Encrypt)\n2. 粘贴证书内容 (Manual Paste)\n3. 仅使用自签 (测试用途)"
    read -p "选择 [1-3]: " ssl_choice

    case $ssl_choice in
        1)
            # 先生成一个临时自签证书，否则 Nginx 在申请到正式证书前无法启动
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"; do_certbot="y"
            ;;
        2)
            # 手动粘贴模式：使用 cat 获取终端输入直到 Ctrl+D
            echo "--- 请粘贴 证书 (CRT/PEM) 内容，按 Ctrl+D 结束 ---"
            cat > "$sc/local_cert.pem"
            echo "--- 请粘贴 私钥 (KEY) 内容，按 Ctrl+D 结束 ---"
            cat > "$sc/local_key.pem"
            final_c="$sc/local_cert.pem"; final_k="$sc/local_key.pem"
            ;;
        *)
            # 生成 10 年有效期的保底自签证书
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$sc/k.pem" -out "$sc/c.pem" -subj "/CN=$domain"
            final_c="$sc/c.pem"; final_k="$sc/k.pem"
            ;;
    esac

    # 写入站点配置文件（合并了 ssl 和 http2 指令以提高兼容性）
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
    # 创建软链接启用站点
    ln -sf "$conf_file" "$NGINX_CONF_ENABLED/$domain.conf"
    
    # 配置文件语法检查
    if nginx -t; then
        systemctl reload nginx
        # 如果选了 1，则触发真正的 Certbot 申请
        if [[ "$do_certbot" == "y" ]]; then
            read -p "请输入邮箱用于 SSL 到期通知: " mail
            certbot --nginx -d "$domain" -m "$mail" --agree-tos --non-interactive
            systemctl reload nginx
        fi
        echo -e "\n[配置成功]\n网页目录: $site_path\n配置文件: $conf_file\n证书目录: $sc\n"
    else
        echo "[错误] Nginx 语法校验失败，可能由于粘贴内容有误，配置已回滚。"
        rm -f "$NGINX_CONF_ENABLED/$domain.conf"
    fi
}

# --- 功能 6：深度卸载逻辑 ---
uninstall() {
    read -p "警告：这会删除 Nginx 及所有站点文件和证书，确定吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        systemctl stop nginx 2>/dev/null
        # 清理软件包
        command -v apt &>/dev/null && apt purge -y nginx certbot || yum remove -y nginx certbot
        # 删除所有配置、网页数据和证书
        rm -rf /etc/nginx /var/www /etc/letsencrypt "$CERT_DIR"
        # 从 Crontab 中删除续签任务
        crontab -l 2>/dev/null | grep -v "certbot renew" | crontab -
        echo ">> 所有 Nginx 数据清理完毕。"
        exit 0
    fi
}

# --- 主循环菜单 ---
while true; do
    draw_header
    echo "  1. 环境初始化 (安装/修复/防冲突/放行端口)"
    echo "  2. 站点列表 (查看已建域名)"
    echo "  3. 添加站点 (支持自动续签/粘贴本地证书)"
    echo "  4. 删除站点 (仅删除配置)"
    echo "  5. 重启服务 (重载配置生效)"
    echo "  6. 深度卸载 (彻底清理环境)"
    echo "  0. 退出脚本"
    echo "---------------------------------------------------------------"
    read -p "请选择操作 [0-6]: " choice
    case $choice in
        1) init_system; read -n 1 -s -r -p "处理完成，按任意键继续..." ;;
        2) 
            echo "当前已启用站点："
            for f in "$NGINX_CONF_ENABLED"/*.conf; do 
                [ -e "$f" ] && echo " - $(basename "$f" .conf)"
            done
            read -n 1 -s -r -p "按任意键继续..." ;;
        3) add_site; read -n 1 -s -r -p "处理完成，按任意键继续..." ;;
        4) 
            read -p "请输入要删除的域名: " d
            rm -f "$NGINX_CONF_DIR/$d.conf" "$NGINX_CONF_ENABLED/$d.conf"
            nginx -t && systemctl reload nginx && echo ">> 站点已移除。"
            sleep 1 ;;
        5) nginx -t && systemctl restart nginx && echo ">> Nginx 重启成功。" || echo ">> 重启失败，请检查配置。"; sleep 1 ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo "无效选项，请重新选择。"; sleep 1 ;;
    esac
done
