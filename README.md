# singbox-stats — sing-box 域名访问统计

单文件一键安装。统计 sing-box（VLESS Reality 等入站）里客户端访问过的**域名**，按北京时间每 3 小时一个窗口汇总，忽略 IP 直连目标（CDN 等），可选按域名后缀映射成应用名，报告保留 7 天。

兼容 **Debian 11/12/13、Ubuntu 22.04、Alpine 3.23**，systemd 与 OpenRC 均可。

> 前提：机器上已经装好 **sing-box** 并有配置文件（可先用 `install_reality.sh` 部署节点）。xray 内核不适用。

---

## 快速安装

把下面一行复制到服务器 SSH 里执行。脚本会先下载到 `/tmp`，再用 `sh` 执行（`sh` 能在 Alpine 上自举 bash）：

```bash
if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 10 -m 60 -o /tmp/singbox-stats-install.sh https://raw.githubusercontent.com/hytuytujyt/singbox-stats/main/singbox-stats-install.sh; elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O /tmp/singbox-stats-install.sh https://raw.githubusercontent.com/hytuytujyt/singbox-stats/main/singbox-stats-install.sh; elif command -v busybox >/dev/null 2>&1; then busybox wget -q -T 15 -O /tmp/singbox-stats-install.sh https://raw.githubusercontent.com/hytuytujyt/singbox-stats/main/singbox-stats-install.sh; else echo '需要 curl/wget/busybox 之一（Debian 最小系统可先执行 apt-get install -y curl）' >&2; exit 1; fi && sh /tmp/singbox-stats-install.sh
```

Alpine 默认已有 busybox wget，直接执行即可。

---

## 常用环境变量

| 变量 | 含义 | 默认 |
|------|------|------|
| `SINGBOX_CONFIG` | sing-box 配置路径 | `/etc/sing-box/config.json` |
| `LOG_FILE` | sing-box 日志路径 | 读取配置里的 `log.output`，没有则 `/var/log/sing-box.log` |
| `KEEP_DAYS` | 报告和 sing-box 日志保留天数 | `7` |
| `NO_RESTART=1` | 修改配置/时区后不自动重启 sing-box，需手动重启 | 自动重启 |

例：`LOG_FILE=/var/log/sing-box.log KEEP_DAYS=7 sh /tmp/singbox-stats-install.sh`

---

## 安装脚本会做什么

1. 自举 bash，按包管理器（apk / apt / dnf / yum / zypper / pacman）安装依赖：gawk、logrotate、tzdata、jq 等。
2. 系统时区设为 `Asia/Shanghai`，统计窗口按北京时间切分。
3. 检查 sing-box 日志配置：统计需要 `level` 为 `info`（或更详细）、`timestamp` 为 `true`、`output` 指向日志文件。不满足时自动修改，修改前备份为 `config.json.bak.<时间戳>`，并通过 `sing-box check` 才写入。
4. 修改了配置或时区后重启 sing-box（会断开几秒连接）。
5. 写入统计脚本 `/usr/local/bin/singbox-stats.sh`、命令 `/usr/local/bin/note`、映射表 `/etc/singbox-stats/apps.conf`（已存在则不覆盖）。
6. 写入 sing-box 日志轮转 `/etc/logrotate.d/sing-box`（每天切分，保留 `KEEP_DAYS` 天）。
7. 注册服务：
   - systemd：`singbox-stats-collect.service`（采集）+ `singbox-stats-report.timer`（每 10 分钟生成报告）
   - OpenRC：`/etc/init.d/singbox-stats-collect`（采集）+ crontab（每 10 分钟生成报告，每天 0 点轮转日志）

---

## 使用

```bash
note            # 列出最近的报告（1 是最新的），输入序号查看，回车退出
note now        # 查看当前窗口（还没结束）的实时统计
```

第一份报告要等当前 3 小时窗口结束后才会出现。

---

## 应用映射表

`/etc/singbox-stats/apps.conf`，每行一条：`域名后缀 应用名`，先匹配先生效，`#` 开头为注释。改完不需要重启，下一份报告生效。

```
telegram.org Telegram
t.me Telegram
youtube.com YouTube
```

---

## 卸载

```bash
sh /tmp/singbox-stats-install.sh --uninstall
```

只删除采集服务、定时任务和 `note`、统计脚本。统计数据 `/var/lib/singbox-stats`、映射表 `/etc/singbox-stats`、sing-box 日志轮转配置和 sing-box 本身都保留。

---

## 输出文件与路径

| 路径 | 内容 |
|------|------|
| `/var/lib/singbox-stats/raw/YYYYMMDD_HH.raw` | 窗口内的原始域名记录（每行一条，报告生成后删除）|
| `/var/lib/singbox-stats/reports/YYYYMMDD_HH.txt` | 生成后的报告（保留 `KEEP_DAYS` 天）|
| `/etc/singbox-stats/apps.conf` | 应用映射表 |
| `/usr/local/bin/singbox-stats.sh`、`/usr/local/bin/note` | 统计脚本与查看命令 |
| `/etc/logrotate.d/sing-box` | sing-box 日志轮转规则 |

---

## 故障排查

1. `note now` 一直没有记录：确认 Shadowrocket 在连接中，并打开几个网页；再看采集服务是否在运行：`systemctl status singbox-stats-collect`（OpenRC 用 `rc-service singbox-stats-collect status`）。
2. 报告时间对不上：`date` 应显示 `+0800`；如果不是，重新运行安装脚本，或 `timedatectl set-timezone Asia/Shanghai` 后重启 sing-box。
3. 安装报 404 或依赖失败：多半是镜像刚同步，等几分钟后重新运行即可。
4. 提示"未找到 sing-box"：先用 `install_reality.sh` 装好节点再运行本脚本。
