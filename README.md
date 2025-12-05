# 文件/目录结构

/var/www/                    <-- 网站根目录
 ├── example.com/             <-- example.com 网站目录
 │   └── index.html           <-- 首页 HTML

/etc/nginx/sites-available/   <-- 可用 Nginx 配置
 ├── example.com.conf
 /etc/nginx/sites-enabled/     <-- 已启用配置（符号链接）
 ├── example.com.conf -> ../sites-available/example.com.conf

# 自签证书

/etc/ssl/example.com/
 ├── example.com.crt           <-- 证书
 └── example.com.key           <-- 私钥

# Let’s Encrypt

/etc/letsencrypt/live/example.com/
 ├── fullchain.pem
 └── privkey.pem

### 1.安装

```
bash -c "$(curl -L https://raw.githubusercontent.com/SumMoonYou/Nginx_Manage/refs/heads/main/nginx_manage.sh)" @ install
```

### 2. 主菜单操作说明

1. **安装 Nginx**
    自动安装 Nginx、Certbot、开放防火墙端口并设置开机自启
2. **添加单个网站**
   - 输入域名
   - 选择端口（80 或 443）
   - 如果选择 443，选择证书类型（自签 / Let’s Encrypt）
   - 添加完成后输出网站信息
3. **批量添加网站**
   - 输入多个域名（空格分隔）
   - 同样支持 80/443、证书选择
   - 每个网站添加完成后输出信息
4. **删除网站**
   - 删除网站根目录、Nginx 配置、证书
5. **卸载 Nginx**
   - 停止并卸载 Nginx
   - 删除所有网站目录、证书和配置
   - 移除自动续期任务

------

## 📌 注意事项

- 脚本需要 **root 权限** 执行
- 自签证书仅用于测试或内网环境
- Let’s Encrypt 证书需要域名解析到本机公网 IP
- 添加网站后可以在 `/var/www/<域名>` 上传 HTML 文件

------

## 🔧 依赖

- Nginx
- OpenSSL
- Certbot (用于自动申请 Let’s Encrypt 证书)
- ufw / firewalld（防火墙自动开放 80/443 端口）
