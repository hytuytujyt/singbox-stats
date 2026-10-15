#!/bin/sh
# =====================================================================
#  singbox-stats：sing-box 域名访问统计（一键安装 / 卸载）
#  兼容 Debian 11/12/13、Ubuntu 22.04、Alpine 3.23（systemd 或 OpenRC）
#  仅适用于 sing-box 内核（xray 分支的日志格式不同，不适用）
#
#  安装：sh singbox-stats-install.sh
#        LOG_FILE=/var/log/sing-box.log KEEP_DAYS=7 sh singbox-stats-install.sh
#  卸载：sh singbox-stats-install.sh --uninstall
#
#  前提：sing-box 已安装并有配置文件（可先用 install_reality.sh 部署节点）
#  环境变量：
#    SINGBOX_CONFIG  sing-box 配置路径（默认 /etc/sing-box/config.json）
#    LOG_FILE        sing-box 日志路径（默认读取配置里的 log.output）
#    KEEP_DAYS       日志和统计报告保留天数（默认 7）
#    NO_RESTART=1    修改配置/时区后不自动重启 sing-box，需要手动重启
# =====================================================================

# ---------- 引导段：确保 bash 可用（POSIX sh，可在 ash/busybox 下运行） ----------
if [ -z "${BASH_VERSION:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    echo "[*] 缺少 bash，自动安装 ..."
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache bash
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y bash
    elif command -v yum >/dev/null 2>&1; then
      yum install -y bash
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install bash
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Sy --noconfirm bash
    else
      echo "[!] 请先手动安装 bash" >&2
      exit 1
    fi
  fi
  command -v bash >/dev/null 2>&1 || { echo "[!] bash 安装失败" >&2; exit 1; }
  if [ -f "$0" ]; then
    exec bash "$0" "$@"
  fi
  echo "[!] 请先把脚本下载到本地再执行：sh singbox-stats-install.sh" >&2
  exit 1
fi

# =====================================================================
#  正文段（bash）
# =====================================================================
set -euo pipefail

info() { printf '%s\n' "[*] $*"; }
ok()   { printf '%s\n' "[✓] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
die()  { printf '%s\n' "[!] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/sing-box/config.json}"
KEEP_DAYS="${KEEP_DAYS:-7}"
NO_RESTART="${NO_RESTART:-}"
case "$KEEP_DAYS" in
  ''|*[!0-9]*) die "KEEP_DAYS 必须是正整数，当前值: $KEEP_DAYS" ;;
esac

DATA_DIR=/var/lib/singbox-stats
APPS_CONF=/etc/singbox-stats/apps.conf
STATS_BIN=/usr/local/bin/singbox-stats.sh
NOTE_BIN=/usr/local/bin/note
LOGROTATE_CONF=/etc/logrotate.d/sing-box

MODE=install
if [ "${1:-}" = "--uninstall" ]; then
  MODE=uninstall
fi

# ---------- 卸载 ----------
if [ "$MODE" = uninstall ]; then
  info "卸载 singbox-stats（sing-box 本身、配置和日志轮转都不动）"
  if [ -d /run/systemd/system ]; then
    systemctl disable --now singbox-stats-collect.service singbox-stats-report.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/singbox-stats-collect.service \
          /etc/systemd/system/singbox-stats-report.service \
          /etc/systemd/system/singbox-stats-report.timer
    systemctl daemon-reload || true
  else
    rc-service singbox-stats-collect stop >/dev/null 2>&1 || true
    rc-update del singbox-stats-collect default >/dev/null 2>&1 || true
    rm -f /etc/init.d/singbox-stats-collect
    if [ -f /etc/crontabs/root ]; then
      sed -i '/singbox-stats.sh report/d' /etc/crontabs/root
    fi
    rc-service crond restart >/dev/null 2>&1 || true
  fi
  rm -f "$STATS_BIN" "$NOTE_BIN"
  ok "已卸载。统计数据 $DATA_DIR 和 $APPS_CONF 保留，需要删除请手动 rm -rf"
  exit 0
fi

# ---------- 识别系统和 init ----------
. /etc/os-release
info "系统: ${PRETTY_NAME:-${ID:-unknown}}"

if [ -d /run/systemd/system ]; then
  INIT=systemd
else
  INIT=openrc
fi

# ---------- 包管理器与依赖 ----------
if command -v apk >/dev/null 2>&1; then
  PM=apk
  PKGS="bash gawk coreutils findutils logrotate tzdata jq openrc"
elif command -v apt-get >/dev/null 2>&1; then
  PM=apt
  PKGS="gawk logrotate tzdata findutils coreutils jq"
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf
  PKGS="gawk logrotate tzdata findutils coreutils jq"
elif command -v yum >/dev/null 2>&1; then
  PM=yum
  PKGS="gawk logrotate tzdata findutils coreutils jq"
elif command -v zypper >/dev/null 2>&1; then
  PM=zypper
  PKGS="gawk logrotate timezone findutils coreutils jq"
elif command -v pacman >/dev/null 2>&1; then
  PM=pacman
  PKGS="gawk logrotate tzdata findutils coreutils jq"
else
  die "不支持的包管理器，请手动安装: gawk logrotate tzdata findutils coreutils jq"
fi

pm_update() {
  case "$PM" in
    apk)    apk update ;;
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update ;;
    dnf)    dnf makecache ;;
    yum)    yum makecache ;;
    zypper) zypper --non-interactive refresh ;;
    pacman) pacman -Sy --noconfirm ;;
  esac
}

pm_install() {
  case "$PM" in
    apk)    apk add --no-cache "$@" ;;
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf)    dnf install -y "$@" ;;
    yum)    yum install -y "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
  esac
}

info "安装依赖：$PKGS"
pm_update || warn "包索引刷新有错误（镜像可能暂时不同步），继续尝试安装"
if ! pm_install $PKGS; then
  warn "依赖安装失败，刷新包索引后重试一次 ..."
  pm_update || true
  pm_install $PKGS || die "依赖安装失败。如果是 404 错误，等几分钟后重新运行本脚本"
fi

for c in gawk logrotate jq tail sort tac date find uniq wc; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done
ok "依赖就绪"

if [ "$INIT" = openrc ]; then
  command -v rc-service >/dev/null 2>&1 || die "未找到 rc-service（OpenRC），也没有 systemd，无法注册服务"
fi

# ---------- 检查 sing-box 和配置 ----------
command -v sing-box >/dev/null 2>&1 || die "未找到 sing-box，请先安装并配置（可先运行 install_reality.sh）"
[ -f "$SINGBOX_CONFIG" ] || die "找不到 sing-box 配置: $SINGBOX_CONFIG（可用 SINGBOX_CONFIG=路径 指定）"
jq empty "$SINGBOX_CONFIG" >/dev/null 2>&1 || die "sing-box 配置不是合法 JSON: $SINGBOX_CONFIG"

CFG_OUTPUT=$(jq -r '.log.output // ""' "$SINGBOX_CONFIG")
LOG_FILE="${LOG_FILE:-${CFG_OUTPUT:-/var/log/sing-box.log}}"
info "sing-box 配置: $SINGBOX_CONFIG"
info "sing-box 日志: $LOG_FILE"

# ---------- 时区：统计窗口按北京时间切分 ----------
info "设置时区为 Asia/Shanghai"
TZ_CHANGED=0
if [ "$(date +%z)" != "+0800" ]; then
  if [ "$INIT" = systemd ] && command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Shanghai
  else
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo Asia/Shanghai > /etc/timezone
  fi
  TZ_CHANGED=1
fi
[ "$(date +%z)" = "+0800" ] || die "时区设置失败"

# ---------- sing-box 日志配置：统计需要 info 级别 + 时间戳 + 输出到文件 ----------
info "检查 sing-box 日志配置（统计需要 info 级别、时间戳和日志文件输出）"
LEVEL=$(jq -r '.log.level // ""' "$SINGBOX_CONFIG")
OUTPUT=$(jq -r '.log.output // ""' "$SINGBOX_CONFIG")
TS=$(jq -r '.log.timestamp // false' "$SINGBOX_CONFIG")
NEED=0
case "$LEVEL" in
  info|debug|trace) ;;
  *) NEED=1 ;;
esac
[ "$OUTPUT" = "$LOG_FILE" ] || NEED=1
[ "$TS" = true ] || NEED=1

CONFIG_CHANGED=0
if [ "$NEED" = 1 ]; then
  BACKUP="$SINGBOX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$SINGBOX_CONFIG" "$BACKUP"
  TMP="$SINGBOX_CONFIG.tmp"
  jq --arg out "$LOG_FILE" '
    .log = ((.log // {})
      | .level = (if (.level == "debug" or .level == "trace") then .level else "info" end)
      | .output = $out
      | .timestamp = true)
  ' "$SINGBOX_CONFIG" > "$TMP"
  # 配置里有私钥，临时文件必须是 600，不能用默认的 644
  chmod 600 "$TMP"
  if ! sing-box check -c "$TMP" >/dev/null 2>&1; then
    rm -f "$TMP"
    die "修改后的配置未通过 sing-box check，原配置未改动（备份: $BACKUP）"
  fi
  mv "$TMP" "$SINGBOX_CONFIG"
  CONFIG_CHANGED=1
  ok "已修改 sing-box 日志配置（备份: $BACKUP）"
else
  ok "sing-box 日志配置已满足要求，无需修改"
fi

# 修改了日志配置或时区后，需要重启 sing-box 才会生效（会断开几秒连接）
if [ "$CONFIG_CHANGED" = 1 ] || [ "$TZ_CHANGED" = 1 ]; then
  if [ -n "$NO_RESTART" ]; then
    warn "已修改配置/时区，但设置了 NO_RESTART，请手动重启 sing-box 才能生效"
  else
    info "重启 sing-box 让配置和时区生效（会断开几秒连接）"
    if [ "$INIT" = systemd ]; then
      systemctl restart sing-box
    else
      rc-service sing-box restart
    fi
    ok "sing-box 已重启"
  fi
fi

# ---------- 写入脚本和配置 ----------
info "写入统计脚本、note 命令和配置"
mkdir -p "$DATA_DIR/raw" "$DATA_DIR/reports" /etc/singbox-stats /etc/logrotate.d

cat > "$STATS_BIN" <<'EOF'
#!/bin/bash
# sing-box 域名访问统计：按北京时间每 3 小时一个窗口，只统计域名，丢弃 IP 目标
# 用法: singbox-stats.sh collect | report
set -u

LOG=__LOG_FILE__
BASE=/var/lib/singbox-stats
RAW=$BASE/raw
REPORTS=$BASE/reports
APPS=/etc/singbox-stats/apps.conf

mkdir -p "$RAW" "$REPORTS"

collect() {
  if [ "$(date +%z)" != "+0800" ]; then
    echo "WARNING: 系统时区不是 Asia/Shanghai，统计窗口不是北京时间" >&2
  fi
  # -n 0：只读新增内容，不回放历史日志
  tail -n 0 -F "$LOG" | awk -v raw="$RAW" '
    / inbound connection to / {
      host = tolower($NF)
      sub(/:[0-9]+$/, "", host)
      # 跳过 IP 目标（IPv4 或 [IPv6]）
      if (host ~ /^\[/ || host ~ /^[0-9.]+$/) next
      split($3, t, ":")
      bucket = $2
      gsub(/-/, "", bucket)
      bucket = sprintf("%s_%02d", bucket, int((t[1] + 0) / 3) * 3)
      if (bucket != cur) {
        if (cur != "") close(out)
        cur = bucket
        out = raw "/" bucket ".raw"
      }
      print host >> out; fflush(out)
    }'
}

report() {
  local f name day hour end_epoch start end out
  for f in "$RAW"/*.raw; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .raw)
    day=${name%_*}; hour=${name#*_}
    day=${day:0:4}-${day:4:2}-${day:6:2}
    end_epoch=$(( $(date -d "$day $hour:00" +%s) + 10800 ))
    # 窗口结束后再等 2 分钟，避免还有迟到的日志行
    [ "$(date +%s)" -lt $((end_epoch + 120)) ] && continue
    start="$day $hour:00"
    end=$(date -d "@$end_epoch" '+%H:%M')
    out=$REPORTS/$name.txt
    awk -v label="$start - $end (北京时间)" -v apps="$APPS" '
      FILENAME == apps {
        if ($0 ~ /^[ \t]*(#|$)/) next
        n++; suf[n] = tolower($1); app[n] = $2
        next
      }
      { total++; cnt[$0]++ }
      END {
        for (h in cnt) {
          hl = length(h)
          for (i = 1; i <= n; i++) {
            sl = length(suf[i])
            if (h == suf[i] || (hl > sl && substr(h, hl - sl + 1) == "." suf[i])) {
              appcnt[app[i]] += cnt[h]
              break
            }
          }
        }
        print "==== " label " ===="
        print "连接总数: " (total + 0)
        print ""
        print "-- 应用汇总 --"
        fflush()
        for (a in appcnt) print appcnt[a], a | "sort -rn"
        close("sort -rn")
        print ""
        print "-- 域名（次数降序）--"
        fflush()
        for (h in cnt) print cnt[h], h | "sort -rn"
        close("sort -rn")
      }' "$APPS" "$f" > "$out.tmp" && mv "$out.tmp" "$out" && rm -f "$f"
  done
  # 保留报告 __KEEP_DAYS__ 天
  find "$REPORTS" -name '*.txt' -mtime +__KEEP_DAYS__ -delete
}

case "${1:-}" in
  collect) collect ;;
  report)  report ;;
  *) echo "用法: $0 collect|report" >&2; exit 1 ;;
esac
EOF
sed -i -e "s|__LOG_FILE__|$LOG_FILE|" -e "s|__KEEP_DAYS__|$KEEP_DAYS|" -e 's/awk -v/gawk -v/g' "$STATS_BIN"
chmod 755 "$STATS_BIN"

cat > "$NOTE_BIN" <<'EOF'
#!/bin/bash
# 用法:
#   note      列出所有报告（最新的在前），输入序号查看
#   note now  显示当前窗口（还没结束）的实时统计
REPORTS=/var/lib/singbox-stats/reports
RAW=/var/lib/singbox-stats/raw

if [ "${1:-}" = "now" ]; then
  f=$RAW/$(date +%Y%m%d)_$(printf '%02d' $(( 10#$(date +%H) / 3 * 3 ))).raw
  if [ ! -e "$f" ]; then
    echo "当前窗口还没有任何记录"
    exit 0
  fi
  echo "==== 当前窗口实时统计（截至 $(date '+%H:%M')）===="
  echo "连接总数: $(wc -l < "$f")"
  sort "$f" | uniq -c | sort -rn
  exit 0
fi

# 文件名是 日期_小时.txt，倒序排列即为最新的在前
mapfile -t files < <(ls -1 "$REPORTS"/*.txt 2>/dev/null | sort -r)
if [ "${#files[@]}" -eq 0 ]; then
  echo "还没有任何报告（第一份报告会在 21:00 窗口结束后生成）"
  exit 0
fi

echo "最近的报告（共 ${#files[@]} 份，1 是最近的）："
for i in "${!files[@]}"; do
  label=$(sed -n 1p "${files[$i]}" | sed 's/^==== //; s/ ====$//')
  total=$(sed -n 2p "${files[$i]}")
  printf "%2d) %s   %s\n" $((i + 1)) "$label" "$total"
done

read -r -p "输入序号查看（直接回车退出）: " choice
[ -z "$choice" ] && exit 0
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
  echo "无效序号: $choice" >&2
  exit 1
fi
echo
cat "${files[$((choice - 1))]}"
EOF
chmod 755 "$NOTE_BIN"

if [ ! -f "$APPS_CONF" ]; then
  cat > "$APPS_CONF" <<'EOF'
# 域名后缀 应用名，先匹配先生效
telegram.org Telegram
t.me Telegram
wechat.com WeChat
weixin.qq.com WeChat
youtube.com YouTube
googlevideo.com YouTube
EOF
fi

cat > "$LOGROTATE_CONF" <<EOF
$LOG_FILE {
    daily
    rotate $KEEP_DAYS
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# ---------- 服务和定时任务 ----------
if [ "$INIT" = systemd ]; then
  info "注册 systemd 服务和定时器"
  cat > /etc/systemd/system/singbox-stats-collect.service <<'EOF'
[Unit]
Description=sing-box 域名访问统计采集
After=sing-box.service

[Service]
ExecStart=/usr/local/bin/singbox-stats.sh collect
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/singbox-stats-report.service <<'EOF'
[Unit]
Description=sing-box 域名访问统计报告生成

[Service]
Type=oneshot
ExecStart=/usr/local/bin/singbox-stats.sh report
EOF
  cat > /etc/systemd/system/singbox-stats-report.timer <<'EOF'
[Unit]
Description=每 10 分钟生成已结束窗口的报告

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable singbox-stats-collect.service singbox-stats-report.timer
  systemctl restart singbox-stats-collect.service
  systemctl start singbox-stats-report.timer
else
  info "注册 OpenRC 服务，并用 crond 定时生成报告"
  cat > /etc/init.d/singbox-stats-collect <<'EOF'
#!/sbin/openrc-run
name="singbox-stats-collect"
description="sing-box 域名访问统计采集"
command="/usr/local/bin/singbox-stats.sh"
command_args="collect"
supervisor="supervise-daemon"
respawn_delay=5

depend() {
  need net
  after sing-box
}
EOF
  chmod 755 /etc/init.d/singbox-stats-collect
  rc-update add crond default >/dev/null 2>&1 || true
  rc-update add singbox-stats-collect default >/dev/null 2>&1 || true
  rc-service singbox-stats-collect restart

  mkdir -p /etc/crontabs
  touch /etc/crontabs/root
  grep -q 'singbox-stats.sh report' /etc/crontabs/root ||
    echo '*/10 * * * * /usr/local/bin/singbox-stats.sh report' >> /etc/crontabs/root
  rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
fi

# 日志轮转：systemd 下由系统自带的 logrotate.timer 每天执行；OpenRC 下由 crontab 每天 0 点执行
if [ "$INIT" = openrc ]; then
  grep -q 'logrotate /etc/logrotate.d/sing-box' /etc/crontabs/root ||
    echo "0 0 * * * $(command -v logrotate) /etc/logrotate.d/sing-box >/dev/null 2>&1" >> /etc/crontabs/root
  rc-service crond restart >/dev/null 2>&1 || true
fi

# ---------- 检查 ----------
bash -n "$STATS_BIN" && bash -n "$NOTE_BIN" && ok "脚本语法检查通过"
if [ "$INIT" = systemd ]; then
  systemctl is-active singbox-stats-collect.service || true
else
  rc-service singbox-stats-collect status || true
fi

ok "安装完成"
echo "    查看报告：note"
echo "    查看当前窗口实时统计：note now"
echo "    统计数据：$DATA_DIR    报告保留 $KEEP_DAYS 天，sing-box 日志保留 $KEEP_DAYS 天"
echo "    应用映射表：$APPS_CONF（可以自己增删）"
echo "    第一份报告要等当前 3 小时窗口结束后才会出现"
