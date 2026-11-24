# IP Location 菜单栏应用

一个 macOS 菜单栏小工具：通过免费的 IP 查询服务（默认 [ipapi.co](https://ipapi.co/)）查询当前公网 IP 的位置，在菜单栏显示「城市 · 地区」，点击后查看国家、邮编、经纬度、时区、IP、运营商等详情。

- 启动时、每小时、电脑从睡眠唤醒时，以及网络断开后恢复或切换（换 Wi-Fi、开关 VPN）时自动刷新
- 可在菜单「数据源」里切换查询服务；默认开启「出错时自动切换」：首选服务限流或出错时，自动依次换用其他服务，出错的服务暂停一段时间（限流 30 分钟，其他错误 5 分钟）后再优先用回首选
- 刷新失败时按 5、15、30、60、120 秒自动重试；断网期间菜单栏显示断网图标，不会报错
- 菜单里点「立即刷新」（⌘R）手动刷新
- 点任意一行详情即可复制该值
- 可收藏「正确的」IP 档案：之后刷新时，如果国家、地区或 ASN 和所有收藏都对不上（比如代理掉线、出口变了），菜单栏会变成红底提醒，下拉菜单标出哪几项不同，并发一条系统通知。每个档案可单独「锁定 IP」；也可以「暂时忽略」，直到 IP 信息再次变化
- 可开启「登录时启动」

## 环境要求

- macOS 14 及以上
- Swift 5.9+（装 Xcode 或 Command Line Tools 都可以：`xcode-select --install`）

## 构建与运行

```bash
./scripts/build-app.sh
open build/IPLocationMenuBar.app
```

开发时也可以直接运行（不打包成 `.app`，此时「登录时启动」不可用）：

```bash
swift run
```

调试自动刷新时，可以用环境变量缩短间隔（单位：秒，最小 10）：

```bash
REFRESH_INTERVAL=60 build/IPLocationMenuBar.app/Contents/MacOS/IPLocationMenuBar
```

模拟出口变化、测试不符提醒（改为查询指定 IP 的信息）：

```bash
IPAPI_LOOKUP_IP=8.8.8.8 build/IPLocationMenuBar.app/Contents/MacOS/IPLocationMenuBar
```

模拟数据源故障、测试自动切换（数据源名称见上表，GeoJS 写作 `geojs`）：

```bash
IPAPI_FAIL_PROVIDERS=ipapi.co,geojs build/IPLocationMenuBar.app/Contents/MacOS/IPLocationMenuBar
```

查看刷新日志（网络变化、重试、成功或失败）：

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "local.ip-location-menu-bar"' --style compact
```

## 安装

把 `build/IPLocationMenuBar.app` 拖到「应用程序」文件夹，再从那里打开。开启「登录时启动」后，macOS 可能会要求你在「系统设置 → 通用 → 登录项」中允许它。

## 数据源与免费额度

都是免费、无需 API key 的服务，额度按你的公网 IP 计算。

| 数据源 | 免费额度 | 说明 |
|---|---|---|
| [ipapi.co](https://ipapi.co/)（默认） | 约每天 1000 次 | 字段最全；对通用 User-Agent 限流更严，本应用会带自己的 User-Agent |
| [GeoJS](https://www.geojs.io/) | 未标注上限 | 没有邮编 |
| [ip-api.com](https://ip-api.com/) | 每分钟 45 次，仅限非商业用途 | 免费版只有 HTTP，`Info.plist` 只为这一个域名放行 HTTP |
| [ipapi.is](https://ipapi.is/) | 每天 1000 次 | 没有邮编、国家代码 |
| [ipinfo.io](https://ipinfo.io/) | 每月 5 万次 | 不带 token 时限流较严 |

本应用每小时只请求一次。如果同一个出口 IP 上还有别人在用这些服务（比如共用的代理节点），额度可能被别人用掉，这时自动切换会接手。

各数据源返回的格式不同，应用会统一成同一种格式：ASN 写成 `AS7018`，美国州名写成两位缩写。所以换数据源不会让收藏档案误报不符。

## 项目结构

```
Package.swift
Sources/IPLocationMenuBar/
  main.swift          应用入口
  AppDelegate.swift   菜单栏图标、下拉菜单、定时刷新
  IPAPIClient.swift   发请求、处理错误、按首选和自动切换选择数据源
  IPProvider.swift    各数据源的地址和响应解析
  IPInfo.swift        响应数据模型
  FavoriteProfile.swift 收藏档案、比对规则与存储
Resources/Info.plist  应用包信息（LSUIElement：不显示 Dock 图标）
Resources/AppIcon.icns 应用图标（由 scripts/make-icon.sh 生成）
assets/icon-source.png 图标原图（满版方形，由 Codex 生成）
scripts/build-app.sh  构建并打包 .app
scripts/make-icon.sh  把原图套上 macOS 圆角遮罩，生成各尺寸的 .icns
```

## 许可证

[MIT](LICENSE)
