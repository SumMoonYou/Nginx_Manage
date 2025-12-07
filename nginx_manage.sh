#!/bin/bash

# ==========================
# Nginx 一键管理脚本
# Version: 1.9
# 功能: 安装/单站/批量添加/删除/卸载/自动续期/防火墙放行/开机自启/输出网站信息/80+443监听
# 支持: Debian/Ubuntu, CentOS/RHEL/AlmaLinux/RockyLinux, Fedora
# ==========================

# 脚本版本号
SCRIPT_VERSION="1.9"
SCRIPT_CHANGELOG="修复了多版本系统支持，增加了自动检测并选择安装源功能"

# 显示版本号和变更记录
show_version() {
    echo "Nginx 一键管理脚本 - 版本 $SCRIPT_VERSION"
    echo "变更记录: $SCRIPT_CHANGELOG"
}

# 显示版本号
show_version

# ==========================
# 全部操作都在以下内容中进行

# Nginx 配置目录
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT="/var/www"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 用户运行此脚本"
   exit 1
fi

# 检测操作系统和版本
detect_os_version() {
    if [[ -f /etc/debian_version ]]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
        if [[ "$OS_VERSION" == 8* ]]; then
            OS_DISTRO="debian8"
        elif [[ "$OS_VERSION" == 9* ]]; then
            OS_DISTRO="debian9"
        elif [[ "$OS_VERSION" == 10* ]]; then
            OS_DISTRO="debian10"
        elif [[ "$OS_VERSION" == 11* ]]; then
            OS_DISTRO="debian11"
        fi
    elif [[ -f /etc/lsb-release ]]; then
        OS_TYPE="ubuntu"
        OS_VERSION=$(lsb_release -r | awk '{print $2}')
        if [[ "$OS_VERSION" == "16.04" ]]; then
            OS_DISTRO="ubuntu16"
        elif [[ "$OS_VERSION" == "18.04" ]]; then
            OS_DISTRO="ubuntu18"
        elif [[ "$OS_VERSION" == "20.04" ]]; then
            OS_DISTRO="ubuntu20"
        elif [[ "$OS_VERSION" == "22.04" ]]; then
            OS_DISTRO="ubuntu22"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="redhat"
        OS_VERSION=$(rpm -E %rhel)
        if [[ "$OS_VERSION" == "7" ]]; then
            OS_DISTRO="centos7"
        elif [[ "$OS_VERSION" == "8" ]]; then
            OS_DISTRO="centos8"
        fi
    else
        echo "不支持的操作系统"
        exit 1
    fi
}

# 安装 Nginx
install_nginx() {
    detect_os_version
    if ! command -v nginx &>/dev/null; then
        echo "正在安装 Nginx..."

        case "$OS_TYPE" in
            debian)
                case "$OS_DISTRO" in
                    debian8|debian9)
                        apt-get update
                        apt-get install -y nginx
                        ;;
                    debian10|debian11)
                        apt update
                        apt install -y nginx
                        ;;
                esac
                ;;
            ubuntu)
                case "$OS_DISTRO" in
                    ubuntu16|ubuntu18)
                        apt-get update
                        apt-get install -y nginx
                        ;;
                    ubuntu20|ubuntu22)
                        apt update
                        apt install -y nginx
                        ;;
                esac
                ;;
            centos7)
                yum install -y epel-release
                cat > /etc/yum.repos.d/nginx.repo << EOL
[nginx]
name=nginx repo
baseurl=http://nginx.org/packages/centos/7/\$basearch/
gpgcheck=0
enabled=1
EOL
                yum install -y nginx
                ;;
            centos8)
                dnf install -y nginx
                ;;
        esac

        echo "Nginx 安装完成"
    else
        echo "Nginx 已安装"
    fi

    systemctl enable nginx
    systemctl start nginx
    open_firewall_ports
}

# 安装 Certbot
install_certbot() {
    detect_os_version
    if ! command -v certbot &>/dev/null; then
        echo "正在安装 Certbot..."

        case "$OS_TYPE" in
            debian)
                case "$OS_DISTRO" in
                    debian8|debian9)
                        curl https://dl.eff.org/certbot-auto -o /usr/local/bin/certbot-auto
                        chmod +x /usr/local/bin/certbot-auto
                        /usr/local/bin/certbot-auto --install-only
                        ;;
                    debian10|debian11)
                        apt update
                        apt install -y certbot python3-certbot-nginx
                        ;;
                esac
                ;;
            ubuntu)
                case "$OS_DISTRO" in
                    ubuntu16|ubuntu18)
                        curl https://dl.eff.org/certbot-auto -o /usr/local/bin/certbot-auto
                        chmod +x /usr/local/bin/certbot-auto
                        /usr/local/bin/certbot-auto --install-only
                        ;;
                    ubuntu20|ubuntu22)
                        apt update
                        apt install -y certbot python3-certbot-nginx
                        ;;
                esac
                ;;
            centos7)
                curl https://dl.eff.org/certbot-auto -o /usr/local/bin/certbot-auto
                chmod +x /usr/local/bin/certbot-auto
                /usr/local/bin/certbot-auto --install-only
                ;;
            centos8)
                dnf install -y certbot python3-certbot-nginx
                ;;
        esac

        echo "Certbot 安装完成"
    else
        echo "Certbot 已安装"
    fi
}

# 开放防火墙端口
open_firewall_ports() {
    detect_os_version
    if [[ "$OS_TYPE" == "debian" || "$OS_TYPE" == "ubuntu" ]]; then
        ufw allow 80
        ufw allow 443
        ufw reload
    elif [[ "$OS_TYPE" == "redhat" ]]; then
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

# 主菜单
echo "====== Nginx 一键管理 v$SCRIPT_VERSION ======"
echo "1) 安装 Nginx"
echo "2) 安装 Certbot"
echo "3) 退出"
read -p "请选择操作 [1-3]: " choice

case "$choice" in
    1) install_nginx ;;
    2) install_certbot ;;
    3) exit 0 ;;
    *) echo "无效选择"; exit 1 ;;
esac
