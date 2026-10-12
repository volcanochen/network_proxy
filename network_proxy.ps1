# network_proxy.ps1 —— 局域网无网服务器借道 Windows 联网的一键脚本（Windows 端）
#
# 用途：为没有互联网出口的 Linux 服务器（默认 buildserver@192.168.137.2）
#       搭建经本机出网的通用通道：SOCKS 代理 + SSH 反向隧道 + 服务器 HTTP 中继。
#       搭好后服务器上 apt、浏览器等支持代理的程序即可联网。
#       LM Studio 相关配置（守护进程代理、模型下载）是可选功能：
#       加 -LmStudio 开启，加 -Model 会隐含开启并在服务器后台开始下载。
#
# 用法：
#   .\network_proxy.ps1 start                  # 通用联网（不触碰 LM Studio）
#   .\network_proxy.ps1 start -LmStudio        # 通用联网 + 配置 LM Studio 下载链路
#   .\network_proxy.ps1 start -Model <模型名>  # 隐含 -LmStudio，并后台启动 lms get
#   .\network_proxy.ps1 stop                   # 停止全部（会中断未完成的下载）
#   .\network_proxy.ps1 status                 # 状态与通路检测
#
# 原理（默认启用三层，均已实测）：
#   ① 本机 SOCKS5 代理(127.0.0.1:$SocksPort, socks_proxy.py) —— 真正出网
#   ② SSH 反向隧道(-R) 把服务器同端口接到本机代理 —— 免 root
#   ③ 服务器 HTTP 中继(http_relay.py → SOCKS 隧道口) —— 供只认 HTTP 代理的
#      程序（apt、GNOME 系统代理等）使用；域名统一由本机代理端解析。
#   可选 ④：带 HTTP_PROXY 环境重启 llmster 守护进程，打通 LM Studio 下载。

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "help")]
    [string]$Action = "start",

    [Parameter(Position = 1)]
    [string]$Model = "",

    [string]$RemoteHost = "buildserver@192.168.137.2",
    [int]$SocksPort = 10800,
    [int]$RelayPort = 10808,
    [switch]$LmStudio
)

$ErrorActionPreference = "Stop"

$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$lockFile    = Join-Path $scriptDir ".network_proxy.lock"
$socksScript = Join-Path $scriptDir "socks_proxy.py"
$relayScript = Join-Path $scriptDir "http_relay.py"
$startSh     = Join-Path $scriptDir "network_proxy_on_start.sh"
$stopSh      = Join-Path $scriptDir "network_proxy_on_stop.sh"

function Log($msg, $color = "White") { Write-Host $msg -ForegroundColor $color }

function Get-Lock {
    if (Test-Path $lockFile) {
        try { return Get-Content $lockFile -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}
function Set-Lock($obj) { $obj | ConvertTo-Json | Set-Content $lockFile -Encoding UTF8 }

function Start-Proxy {
    $enableLms = ($LmStudio.IsPresent) -or ($Model -ne "")
    if (Get-Lock) {
        Log "[!] 已有会话在运行。先 .\network_proxy.ps1 stop，或 .\network_proxy.ps1 status 查看" Red
        return
    }
    foreach ($f in @($socksScript, $relayScript, $startSh)) {
        if (-not (Test-Path $f)) {
            Log "[!] 缺少配套文件：$(Split-Path $f -Leaf)（应与 network_proxy.ps1 同目录）" Red
            return
        }
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Log "[!] 本机未找到 python 命令（socks_proxy.py 需要 Python 3）" Red
        return
    }
    if ($Model -ne "" -and $Model -notmatch '^[A-Za-z0-9._/:\-]+$') {
        Log "[!] 模型名含非法字符：$Model" Red
        return
    }

    Log ""
    Log "=========================================" "Cyan"
    Log "  服务器联网代理（经本机转发）" "Cyan"
    Log ("  LM Studio 链路: " + $(if ($enableLms) { "启用" } else { "未启用（加 -LmStudio 开启）"})) "Cyan"
    Log "=========================================" "Cyan"

    # [1/4] 本机 SOCKS5 代理
    Log "[1/4] 启动本机 SOCKS5 代理 (127.0.0.1:$SocksPort) ..." Yellow
    $socksProc = Start-Process -FilePath "python" `
        -ArgumentList "`"$socksScript`"", $SocksPort `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if (-not (Get-NetTCPConnection -LocalPort $SocksPort -State Listen -ErrorAction SilentlyContinue)) {
        Log "[!] SOCKS 代理启动失败（端口 $SocksPort 可能被占用）" Red
        Stop-Process -Id $socksProc.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Log "    OK: SOCKS5 代理已监听 (PID $($socksProc.Id))" Green

    # [2/4] SSH 反向隧道
    Log "[2/4] 建立 SSH 反向隧道 -> $RemoteHost ..." Yellow
    $sshArgs = @("-N", "-R", "${SocksPort}:127.0.0.1:${SocksPort}",
                 "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                 "-o", "ServerAliveInterval=30", $RemoteHost)
    $tunnelProc = Start-Process -FilePath "ssh" -ArgumentList $sshArgs `
        -WindowStyle Hidden -PassThru
    # 主机可达性先探一次（不可达时快速失败，避免长时间挂起）
    # PS 5.1 会把 ssh/scp 的 stderr 转成终止错误，本段临时改用 Continue 靠退出码判断
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $alive = ssh -o BatchMode=yes -o ConnectTimeout=6 $RemoteHost "echo A" 2>$null
    if (($alive | Out-String) -notmatch "A") {
        Log "[!] 无法连接 $RemoteHost（主机不可达或 SSH 服务未运行）。排查：" Red
        Log "    ① 服务器是否开机、网络是否通（ping 可先试）" Yellow
        Log "    ② SSH 服务是否运行（服务器端 sudo systemctl status ssh）" Yellow
        Log "    ③ 免密登录是否可用：ssh $RemoteHost" Yellow
        Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
        Stop-Process -Id $socksProc.Id -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prevPref
        return
    }
    # 主机可达：轮询远端隧道口是否已建立（进程退出则提前判失败）
    $ready = $false
    for ($i = 0; $i -lt 6; $i++) {
        if ($tunnelProc.HasExited) { break }
        $probe = ssh -o BatchMode=yes -o ConnectTimeout=6 $RemoteHost `
            "timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/$SocksPort' && echo R" 2>$null
        if (($probe | Out-String) -match "R") { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($tunnelProc.HasExited -or -not $ready) {
        if (-not $tunnelProc.HasExited) { Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue }
        Log "[!] 隧道建立失败（退出码 $($tunnelProc.ExitCode) 或探测超时）。排查：" Red
        Log "    ① 免密登录：ssh $RemoteHost 能否直连" Yellow
        Log "    ② 服务器端口 $SocksPort 若被上次残留占用：ssh $RemoteHost 'ss -tln | grep $SocksPort'" Yellow
        Log "    ③ 换一个 -SocksPort（如 10801）重试" Yellow
        Stop-Process -Id $socksProc.Id -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prevPref
        return
    }
    Log "    OK: 反向隧道已建立 (PID $($tunnelProc.Id))" Green

    # [3/4] 推送服务器端组件
    Log "[3/4] 部署服务器端 HTTP 中继 ..." Yellow
    scp -o BatchMode=yes -q $relayScript "${RemoteHost}:/tmp/http_relay.py"
    scp -o BatchMode=yes -q $startSh "${RemoteHost}:/tmp/network_proxy_on_start.sh"
    if ($LASTEXITCODE -ne 0) {
        Log "[!] 文件推送失败（scp 退出码 $LASTEXITCODE）" Red
        Stop-Process -Id $socksProc.Id, $tunnelProc.Id -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prevPref
        return
    }

    # [4/4] 服务器端：起中继 + 验证 +（可选）LM Studio 链路与下载
    Log "[4/4] 配置服务器联网链路 ..." Yellow
    $lmsFlag = if ($enableLms) { "1" } else { "0" }
    $arg = if ($Model -ne "") { "'$Model'" } else { "" }
    $out = ssh -o BatchMode=yes $RemoteHost "LMP_SOCKS_PORT=$SocksPort LMP_RELAY_PORT=$RelayPort LMP_LMSTUDIO=$lmsFlag bash /tmp/network_proxy_on_start.sh $arg" 2>&1
    $ErrorActionPreference = $prevPref
    $out | ForEach-Object { Log "    $_" DarkGray }
    if (($out | Select-String "RELAY_FAIL|DAEMON_FAIL|DAEMON_PROXY_MISSING|RELAY_TEST=FAILED|RELAY_TEST=000") -or $LASTEXITCODE -ne 0) {
        Log "[!] 服务器端链路配置失败，详见上方输出。可 stop 后重试" Red
        Set-Lock @{ socksPid = $socksProc.Id; tunnelPid = $tunnelProc.Id
            socksPort = $SocksPort; relayPort = $RelayPort; lmStudio = $enableLms
            remoteHost = $RemoteHost; startTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        return
    }

    Set-Lock @{
        socksPid   = $socksProc.Id
        tunnelPid  = $tunnelProc.Id
        socksPort  = $SocksPort
        relayPort  = $RelayPort
        lmStudio   = $enableLms
        remoteHost = $RemoteHost
        startTime  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    Log ""
    Log "联网会话已就绪。服务器侧可用入口（均为 127.0.0.1）：" "Cyan"
    Log ("  SOCKS5  : " + $SocksPort + "   （浏览器/支持 SOCKS 的程序）") White
    Log ("  HTTP    : " + $RelayPort + "   （apt、GNOME 系统代理等只认 HTTP 的程序）") White
    Log ""
    if ($enableLms) {
        if ($Model -ne "") {
            Log (">>> 已在服务器后台开始下载: $Model（守护进程接管，保持本窗口打开）") Cyan
            Log "    查看进度: ssh $RemoteHost 'tail -c 200 ~/lms_get.log'" Yellow
        } else {
            Log ">>> LM Studio 链路已配好，服务器上直接 lms get <模型名>，无需 export。" Cyan
        }
        Log "完成后在窗口执行 .\network_proxy.ps1 stop。" Yellow
    } else {
        Log "提示：LM Studio 链路未启用；需要时 stop 后重新 .\network_proxy.ps1 start -LmStudio" Yellow
    }
    Log ""
}

function Stop-Proxy {
    $lock = Get-Lock
    if (-not $lock) {
        Log "[i] 当前没有运行中的会话" DarkGray
        return
    }
    if (Test-Path $stopSh) {
        Log "[停止] 清理服务器端中继 ..." Yellow
        $lmsEnv = if ($lock.lmStudio) { "LMP_LMSTUDIO=1 " } else { "" }
        scp -o BatchMode=yes -q $stopSh "$($lock.remoteHost):/tmp/network_proxy_on_stop.sh" 2>$null
        ssh -o BatchMode=yes "$($lock.remoteHost)" "${lmsEnv}bash /tmp/network_proxy_on_stop.sh" 2>&1 |
            ForEach-Object { Log "    $_" DarkGray }
    }
    foreach ($pidName in @("socksPid", "tunnelPid")) {
        $p = $lock.$pidName
        if ($p) {
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
            Log "    已结束本机进程 PID $p" Green
        }
    }
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    Log "[完成] 会话已停止（提醒：未完成的模型下载已中断）" Green
}

function Show-Status {
    $lock = Get-Lock
    Log ""
    Log "=== network_proxy 状态 ===" Cyan
    if (-not $lock) {
        Log "没有运行中的会话（执行 .\network_proxy.ps1 start 启动）" Yellow
        Log ""
        return
    }
    $socksRunning  = Get-Process -Id $lock.socksPid  -ErrorAction SilentlyContinue
    $tunnelRunning = Get-Process -Id $lock.tunnelPid -ErrorAction SilentlyContinue
    Log ("服务器:      " + $lock.remoteHost)
    Log ("SOCKS 代理:  " + $(if ($socksRunning) { "运行中 (口 " + $lock.socksPort + ")" } else { "已停止" })) $(if ($socksRunning) { "Green" } else { "Red" })
    Log ("SSH 隧道:    " + $(if ($tunnelRunning) { "运行中" } else { "已停止" })) $(if ($tunnelRunning) { "Green" } else { "Red" })
    Log ("LM Studio:   " + $(if ($lock.lmStudio) { "已启用" } else { "未启用" }))
    Log ("启动时间:    " + $lock.startTime)
    if ($tunnelRunning) {
        $remoteCmd = "curl -sS -m 25 -x http://127.0.0.1:$($lock.relayPort) -o /dev/null -w '%{http_code}' https://lmstudio.ai/ 2>/dev/null; echo; pgrep -x llmster >/dev/null && echo daemon=up || echo daemon=down"
        if ($lock.lmStudio) {
            $remoteCmd += "; pid=\$(pgrep -x llmster | head -1); tr '\0' '\n' < /proc/\$pid/environ 2>/dev/null | grep -c '^HTTPS_PROXY=' | xargs -I{} echo daemon_proxy={}"
            $remoteCmd += "; du -sh ~/.lmstudio/models 2>/dev/null | cut -f1"
        }
        $st = ssh -o BatchMode=yes $lock.remoteHost $remoteCmd 2>&1
        Log ("链路检测:    " + (($st | ForEach-Object { "$_" }) -join " | ")) Cyan
    }
    Log ""
}

function Show-Help {
    Log ""
    Log "network_proxy.ps1 — 局域网无网服务器借道 Windows 联网的一键脚本" Cyan
    Log ""
    Log "  start                    通用联网：SOCKS+隧道+HTTP中继（不动 LM Studio）"
    Log "  start -LmStudio          同上 + 配置 LM Studio 下载链路（带代理重启 llmster）"
    Log "  start -Model <名称>      隐含 -LmStudio，并在服务器后台 lms get <名称>"
    Log "  stop                     停止全部并恢复服务器常态（会中断未完成下载）"
    Log "  status                   查看状态与链路检测"
    Log ""
    Log "通用参数：-RemoteHost 用户@主机 / -SocksPort / -RelayPort（默认 10800/10808）"
    Log "配套文件（须同目录）：socks_proxy.py http_relay.py network_proxy_on_start.sh network_proxy_on_stop.sh"
    Log "前提：到目标服务器已配置 SSH 免密登录；本机有 python 与 ssh。"
    Log ""
}

switch ($Action) {
    "start"  { Start-Proxy }
    "stop"   { Stop-Proxy }
    "status" { Show-Status }
    "help"   { Show-Help }
}
