# Nginx 一键管理脚本

轻量、高效、跨平台的 Nginx 一键管理脚本，支持一键安装、创建网站（IPv4+IPv6）、HTTPS 配置（自签证书 / Let’s Encrypt）、防火墙放行、自动续期等功能。

适用于：

- Debian / Ubuntu
- CentOS / RHEL / AlmaLinux / RockyLinux
- Fedora

------

## ✨ 功能特性

### ✅ 一键安装 Nginx（官方稳定版）

- 自动检测系统
- 添加官方 Nginx 仓库
- 开机自启 + 自动启动
- 自动开放 80/443 防火墙端口（UFW / firewalld / iptables）

### ✅ 单站部署（含 IPv6）

- 支持端口选择：
  - 80
  - 443（自签证书 或 Let's Encrypt）
  - 80+443（完整 HTTPS）
- 自动生成网站根目录与 index.html
- 自动创建 Nginx 配置（含 IPv6：`listen [::]:80` / `listen [::]:443`）

### ✅ HTTPS 证书支持

- 自签证书自动生成
- Let’s Encrypt 自动申请（certbot）
- 自动设置续期任务（每天 02:00）

### ✅ 防火墙自动配置

- 自动放行 80 / 443
- 支持 UFW、firewalld、iptables

### ✅ 开箱即用的管理菜单

- 安装 Nginx
- 添加单个网站
- 批量添加网站（若你后续补全函数）
- 删除站点（需补全函数）
- 卸载 Nginx（需补全函数）

------

## 📥 安装方式

```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/Nginx_Manage/refs/heads/main/nginx_manage.sh)" @ install
```

> 请确保以 **root 用户** 运行，否则脚本会自动退出。

------

## 📌 使用截图（示例）

```
====== Nginx 一键管理 v2.1 ======
1) 安装 Nginx
2) 添加单个网站
3) 批量添加网站
4) 删除网站
5) 卸载 Nginx
6) 退出
请选择操作 [1-6]:
```

------

## 📂 网站配置结构

示例：

```
/etc/nginx/sites-available/example.com.conf
/etc/nginx/sites-enabled/example.com.conf
/var/www/example.com/
    └── index.html
/etc/ssl/example.com/example.com.crt
/etc/ssl/example.com/example.com.key
```

------

## 🔐 HTTPS 配置示例

### 自签证书

脚本会自动执行：

```
openssl req -x509 -nodes -days 365 ...
```

### Let’s Encrypt（自动）

脚本会执行：

```
certbot --nginx -d yourdomain.com
```

并自动写入续期任务：

```
0 2 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'
```

------

## 🛠 常用命令（脚本自动提示）

```
systemctl start nginx
systemctl stop nginx
systemctl restart nginx
systemctl reload nginx
nginx -t
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/access.log
```

------

## 📜 License

MIT License
