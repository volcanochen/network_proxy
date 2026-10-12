// proxy.pac —— Edge/Chrome 走本机 SOCKS5 代理的自动配置脚本
// 配合 network_proxy.ps1 使用：代理会话运行期间，浏览器流量经此 SOCKS5 端口出网。
// 端口说明：network_proxy.ps1 默认 SOCKS 口是 10800；若启动时被占用改用了其他端口
// （如 -SocksPort 10801），请对应修改下面的端口。
// 用法：Windows 设置 → 网络和 Internet → 代理 → 自动代理设置 →
//       "使用安装脚本"打开，地址填：file:///C:/VOLCANO/myws/bs001/proxy.pac

function FindProxyForURL(url, host) {
    return "SOCKS5 127.0.0.1:10800";
}
