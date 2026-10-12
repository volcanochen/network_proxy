#!/usr/bin/env bash
# network_proxy_on_start.sh —— 在目标服务器上配置联网链路（由 network_proxy.ps1 推送到 /tmp 执行）
# 步骤：起 HTTP 中继 → 验证通路 → 可选：配置 LM Studio 守护进程代理并代跑下载
# 位置参数 $1：模型名（如 qwen/qwen3.5-9b），仅在启用 LM Studio 时生效
# 环境变量：LMP_RELAY_PORT（默认 10808）、LMP_SOCKS_PORT（默认 10800）、
#           LMP_LMSTUDIO（1 启用 LM Studio 链路，默认 0）
set -u
RELAY_PORT="${LMP_RELAY_PORT:-10808}"
SOCKS_PORT="${LMP_SOCKS_PORT:-10800}"
ENABLE_LMSTUDIO="${LMP_LMSTUDIO:-0}"
RELAY_URL="http://127.0.0.1:${RELAY_PORT}"

# 1) HTTP 中继：通用入口（apt、GNOME 系统代理等只认 HTTP 代理的程序走这里；
#    域名以 CONNECT 交给代理端解析，不受服务器本机无 DNS 影响）
pkill -f http_relay.py 2>/dev/null
sleep 1
nohup python3 /tmp/http_relay.py "$RELAY_PORT" "$SOCKS_PORT" > /tmp/http_relay.log 2>&1 &
sleep 1
if ss -tln | grep -q ":$RELAY_PORT "; then
    echo RELAY_UP
else
    echo RELAY_FAIL
    exit 1
fi

# 2) 可选：LM Studio 链路（llmster 内置 Node 只认 HTTP 代理，且必须带代理环境重启
#    守护进程才生效——shell 里 export 传不到已在后台的它）
if [ "$ENABLE_LMSTUDIO" = "1" ]; then
    LMS="$HOME/.lmstudio/bin/lms"
    if [ ! -x "$LMS" ]; then
        echo "LMSTUDIO_NOT_INSTALLED (跳过 LM Studio 配置)"
        ENABLE_LMSTUDIO=0
    fi
fi
if [ "$ENABLE_LMSTUDIO" = "1" ]; then
    "$LMS" server stop 2>/dev/null
    pkill -TERM -x llmster 2>/dev/null
    sleep 2
    export HTTP_PROXY="$RELAY_URL" HTTPS_PROXY="$RELAY_URL"
    export NO_PROXY=localhost,127.0.0.1 NODE_USE_ENV_PROXY=1
    "$LMS" server start
    sleep 2
    pid=$(pgrep -x llmster | head -1)
    if [ -z "$pid" ]; then
        echo DAEMON_FAIL
        exit 1
    fi
    echo "DAEMON_PID=$pid"
    if tr '\0' '\n' < "/proc/$pid/environ" | grep -q '^HTTPS_PROXY='; then
        echo DAEMON_PROXY_OK
    else
        echo DAEMON_PROXY_MISSING
        exit 1
    fi
fi

# 3) 端到端验证：中继 -> 隧道 -> Windows SOCKS -> 外网
curl -sS -m 30 -x "$RELAY_URL" -o /dev/null \
    -w 'RELAY_TEST=%{http_code}\n' https://lmstudio.ai/ || echo RELAY_TEST=FAILED

# 4) 可选：代跑模型下载（nohup 使其独立于本次 SSH 会话；实际下载由守护进程接管）
MODEL="${1:-}"
if [ -n "$MODEL" ] && [ "$ENABLE_LMSTUDIO" = "1" ]; then
    nohup "$LMS" get "$MODEL" > "$HOME/lms_get.log" 2>&1 &
    echo "GET_PID=$!"
    echo "GET_STARTED: $MODEL"
fi
echo START_DONE
