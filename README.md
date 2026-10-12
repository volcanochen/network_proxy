# network_proxy —— 局域网无网服务器借道 Windows 联网一键脚本

给没有互联网出口的 Linux 服务器（默认 `buildserver@192.168.137.2`）在 Windows 本机一键搭好"借网"通道：SOCKS 代理 + SSH 反向隧道 + 服务器 HTTP 中继。搭好后服务器上 apt、浏览器等支持代理的程序即可联网。

**LM Studio 相关功能是可选的**：默认不启用；加 `-LmStudio` 参数打通 LM Studio 下载链路（带代理配置重启其守护进程），加 `-Model <模型名>` 进一步在服务器后台开始下载模型。

## 快速开始

```powershell
cd C:\VOLCANO\myws\bs001

.\network_proxy.ps1 start                    # 通用联网（不触碰 LM Studio）
.\network_proxy.ps1 start -LmStudio          # 通用联网 + 配置 LM Studio 下载链路
.\network_proxy.ps1 start -Model qwen/qwen3.5-9b   # 隐含 -LmStudio + 后台开始下载
.\network_proxy.ps1 status                   # 查看链路状态（LM Studio 启用时含通路/模型目录检测）
.\network_proxy.ps1 stop                     # 用完清理（会中断未完成的下载）
```

- 启用 `-LmStudio` 后，服务器上直接 `lms get <模型名>` 即可，**无需 export 任何变量**（链路已配置进守护进程）。
- 服务器地址与端口可参数化：`-RemoteHost user@10.0.0.5 -SocksPort 10801 -RelayPort 10809`（提示 10800 被占用时换端口）。

## 通用入口：服务器上怎么用

会话运行期间，服务器本机有两个代理入口（Windows 端 stop 后都会失效）：

| 入口 | 地址（服务器侧） | 适用 |
|---|---|---|
| SOCKS5 | `127.0.0.1:10800`（默认，`-SocksPort` 可调） | curl 的 `--socks5h` / `all_proxy=socks5h://`、Chromium 系浏览器、支持 SOCKS 的程序 |
| HTTP | `127.0.0.1:10808`（默认，`-RelayPort` 可调） | apt、GNOME 系统代理、只认 HTTP 代理的程序（llmster 也是） |

**注意**：HTTP 中继（10808）跑在服务器上；Windows 本机的浏览器要用代理，指向的是本机 SOCKS 口 `127.0.0.1:10800`。

### Windows 本机浏览器

- **Edge**：设置 → 系统 → 打开你系统的代理 → 手动设置：`127.0.0.1` + SOCKS 口（默认 10800），**类型必须选 SOCKS**。
- **Chrome / Firefox**：用扩展（SwitchyOmega / FoxyProxy）建 SOCKS5 方案指向 `127.0.0.1:10800`，或直接用同目录 `proxy.pac`。
- `socks_proxy.py` 曾有 IPv6 缺陷（浏览器本地解析域名常优先 IPv6），**已修复**；修复前启动的旧代理进程需结束并重新 `start` 才生效。

### Ubuntu 服务器上的 Edge（三种方式均实测 HTTP/HTTPS 全通）

```bash
# 方式一 · 环境变量
all_proxy=socks5h://127.0.0.1:10800 microsoft-edge

# 方式二 · 启动参数（须先完全退出 Edge：pkill microsoft-edge）
microsoft-edge --proxy-server="socks5://127.0.0.1:10800"

# 方式三 · GNOME 系统代理（用 HTTP 中继，勿用 SOCKS——见下）
gsettings set org.gnome.system.proxy mode 'manual'
gsettings set org.gnome.system.proxy.http  host '127.0.0.1'
gsettings set org.gnome.system.proxy.http  port 10808
gsettings set org.gnome.system.proxy.https host '127.0.0.1'
gsettings set org.gnome.system.proxy.https port 10808
gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '::1']"
# 恢复：gsettings set org.gnome.system.proxy mode 'none'
```

系统代理为什么用 HTTP 中继而不是 SOCKS 口：服务器本机 DNS 不通，GNOME 配 SOCKS 时 Chromium 会先在本机解析域名 → `ERR_NAME_NOT_RESOLVED`；HTTP 代理以 CONNECT 携带域名、解析交给 Windows 端，不受影响。命令行里若报找不到设置，先在 SSH 会话执行 `export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`（桌面终端不需要）。

### 用 apt 安装软件（需 sudo）

`export all_proxy=...` 对 apt **永远无效**，两个实测原因：① apt 不读 `all_proxy`、不支持 SOCKS，只认自己的 `Acquire::http(s)::Proxy` 配置；② `sudo` 默认清空环境变量（`env_reset`）。

```bash
# 方案 A · 单条命令，免配置免清理（推荐）
sudo apt-get -o Acquire::http::Proxy="http://127.0.0.1:10808" \
             -o Acquire::https::Proxy="http://127.0.0.1:10808" \
             update
# install 同样带上这两个 -o

# 方案 B · 常驻配置（用完记得删）
sudo tee /etc/apt/apt.conf.d/99network_proxy > /dev/null <<'EOF'
Acquire::http::Proxy  "http://127.0.0.1:10808";
Acquire::https::Proxy "http://127.0.0.1:10808";
EOF
sudo apt-get update
sudo rm /etc/apt/apt.conf.d/99network_proxy   # Windows 会话 stop 后务必删除
```

## LM Studio 可选功能（-LmStudio / -Model）

启用后脚本额外做两件事：**带 HTTP 代理环境变量重启 `llmster` 守护进程**，并可选**后台代跑 `lms get`**。为什么必须这样，实测踩过三个坑：

1. **下载不发生在 `lms` 命令里**。`lms get` 只是发起请求，真正下载的是后台守护进程——shell 里 export 的变量它看不到，只能重启它注入环境。
2. **守护进程内置的 Node 网络栈不认 `socks5h://`**，只认 HTTP 代理——所以走的是中继口 10808 而非 SOCKS 口。
3. `lms get` 支持断点续传：链路中断后重新 `start -Model` 同一模型会从断点继续。

其他常用操作：

```powershell
# 进度
ssh buildserver@192.168.137.2 "tail -c 200 ~/lms_get.log"     # 速度与剩余时间
ssh buildserver@192.168.137.2 "du -sh ~/.lmstudio/models"     # 已下载体量
```

```bash
# 停止一次未完成的下载（lms 没有 cancel 子命令，用重启守护进程的方式中止）
lms server stop     # 下载中止，已传部分保留为 .part 断点
lms server start    # 之后重新 lms get 即续传（不影响代理隧道本身）
```

## 与 tun_vpn（原仓库方案）的区别

原 https://github.com/volcanochen/tun_vpn 方案的本质是**网络层透明代理**：在服务器用 root 创建内核 TUN 设备 `tun0`，把默认路由指过去，让**所有应用的流量**无感进入它，再由 `tun2socks` 把 IP 包转成 SOCKS 连接、经 SSH 隧道送到 Windows 出网；系统 DNS 用 UDP→TCP DNS 桥 + 改写 `/etc/resolv.conf` 解决。整体效果相当于"服务器凭空多了一张网卡"。

本方案只保留了原仓库的**出网半段**（Windows SOCKS5 代理 + SSH 反向隧道，`socks_proxy.py` 原样使用），服务器端把 TUN 网关那套换成了应用层代理配置：

| 维度 | tun_vpn 原方案 | network_proxy 本方案 |
|---|---|---|
| 联网方式 | 透明：全部应用自动联网 | 显式：每个应用各自配代理（守护进程 env / Edge 系统代理 / apt -o） |
| 权限 | 需要 sudo（建 TUN、改路由、改 resolv.conf） | 零 root |
| DNS | 系统级可用（nslookup / getent 正常） | 仅走代理的应用由代理端解析；系统级解析仍不可用 |
| 覆盖范围 | 任意程序（含不支持代理的） | 仅支持 HTTP/SOCKS 代理的程序 |
| 服务器端组件 | tun2socks + DNS 桥 + tun_gateway.sh | http_relay.py 一层（llmster 的 Node 只认 HTTP 代理，故加此层） |
| 停止与残留 | 须 root 拆 tun0、还原路由与 resolv.conf | stop 只重启守护进程；唯一持久项是 apt conf 需手删 |

**为什么换**：这台服务器的 `sudo` 需要交互密码，一键脚本拿不到 root，TUN 方案的第一步 `sudo tun_gateway.sh start` 无法自动化；而实际需要联网的 LM Studio、apt、Edge 三者都支持显式代理，应用层方案已经够用。

**何时换回原方案**：当需要给不支持代理的程序联网、或要求系统级 DNS（nslookup/getent/ping 域名可用）时，手动输入一次 sudo 密码跑通原仓库全流程（Windows `tun_vpn.ps1 start` → 服务器 `sudo /tmp/tun_gateway.sh start`），服务器即全局联网。两方案共同限制：ICMP（ping）都不转发，SSH 断开隧道即失效。

## 文件清单

| 文件 | 运行位置 | 作用 |
|---|---|---|
| `network_proxy.ps1` | Windows | 主控脚本（start / stop / status / help；`-LmStudio` `-Model` 可选） |
| `socks_proxy.py` | Windows | SOCKS5 代理（真正出网的一环；已修复 IPv6 目标连接） |
| `http_relay.py` | 服务器 /tmp | HTTP 代理 → SOCKS5 的转发中继（通用组件） |
| `network_proxy_on_start.sh` | 服务器 /tmp | 部署中继、验证；`LMP_LMSTUDIO=1` 时配置守护进程并代跑下载 |
| `network_proxy_on_stop.sh` | 服务器 /tmp | 清理中继；`LMP_LMSTUDIO=1` 时把守护进程恢复为无代理常态 |
| `proxy.pac` | Windows | 浏览器 PAC 自动代理脚本（可选） |

## 工作原理

```
服务器 (无外网)                                      Windows 本机 (有外网)
┌────────────────────────────────┐               ┌──────────────────────────┐
│ apt / Edge / 支持代理的程序      │               │  SOCKS5 代理              │
│   → 127.0.0.1:10800 (SOCKS)    │               │  127.0.0.1:10800          │──► 互联网
│   → 127.0.0.1:10808 (HTTP)     │  SSH 反向隧道  │        ↑                  │  (aliyun/hf 等)
│        ↓ 由 http_relay.py 转接 ═╪═══ TCP 加密 ══╪═ 域名在此解析、请求在此发出 │
│ [可选] llmster 守护进程 ← 下载   │               └──────────────────────────┘
│   HTTP_PROXY=127.0.0.1:10808   │
└────────────────────────────────┘
```

要点：SSH 反向隧道免 root、不改系统配置；中继与临时脚本只放在服务器 `/tmp`，`stop` 一并清除；域名统一由 Windows 代理端解析（服务器无 DNS 也能用）。

## 前提条件

- 到目标服务器（`-RemoteHost`）已配置 SSH 免密登录
- 本机有 `python`（3.x，仅标准库）和 `ssh`/`scp`（Windows 自带 OpenSSH）
- 本机与服务器上的对应端口未被占用（默认 10800/10808，可改）

## 故障排查

| 现象 | 处理 |
|---|---|
| 无法连接服务器（主机不可达或 SSH 服务未运行） | 确认服务器开机、ping 可达、SSH 服务在跑、免密可用；脚本会快速失败并自动回收本机进程 |
| 隧道建立失败（探测超时） | 多为上次残留隧道占服务器端口。先 `stop`；stop 不掉时换 `-SocksPort 10801 -RelayPort 10809` |
| `start` 报已有会话运行 | 先 `stop` 再 `start` |
| status 链路检测非 200 | 本机休眠/断网导致隧道断，`stop` 后重新 `start` |
| lms get 报 Network connection failed | 守护进程重启过但没带代理——重新 `start -LmStudio` 即可 |
| 浏览器设了代理打不开网页 | ① 类型/端口对应：SOCKS 选 10800，GNOME 系统代理用 10808（SOCKS 会因本机无 DNS 报 ERR_NAME_NOT_RESOLVED）；② 旧代理进程需重启会话加载修复；③ `ping` 不通属正常，用网页验证 |
| 下载速度 | 实测 0.5~1.3 MB/s（经本机转发+SSH 加密），6.5GB 模型约 1.5~3 小时 |

## 限制

- **隧道随 SSH 存亡**：Windows 休眠、断网或 stop，服务器即刻断网、下载中断（续传可恢复）。
- **stop 前确认下载已完成**，否则中断（重跑 `start -Model` 可续传）。
- **ping 不通属正常**：SOCKS5 不转发 ICMP。
