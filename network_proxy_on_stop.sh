#!/usr/bin/env bash
# network_proxy_on_stop.sh —— 在目标服务器上清理联网链路（由 network_proxy.ps1 stop 推送执行）
# 注意：若模型下载尚未完成，stop 会中断它（隧道断开后下载必失败）。
# 环境变量：LMP_LMSTUDIO（1 时把守护进程恢复为无代理常态，默认 0 不触碰）
set -u
ENABLE_LMSTUDIO="${LMP_LMSTUDIO:-0}"

pkill -f http_relay.py 2>/dev/null
rm -f /tmp/http_relay.py /tmp/http_relay.log \
      /tmp/network_proxy_on_start.sh /tmp/network_proxy_on_stop.sh

if [ "$ENABLE_LMSTUDIO" = "1" ]; then
    LMS="$HOME/.lmstudio/bin/lms"
    if [ -x "$LMS" ]; then
        # 不带代理环境重启守护进程，恢复服务器常态
        "$LMS" server stop 2>/dev/null
        pkill -TERM -x llmster 2>/dev/null
        sleep 2
        "$LMS" server start
        sleep 2
        echo "DAEMON_RESTARTED=$(pgrep -x llmster | head -1)"
    fi
fi
echo STOP_DONE
