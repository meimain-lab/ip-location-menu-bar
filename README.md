# IP Location 菜单栏应用

一个 macOS 菜单栏小工具：通过 [ipapi.co](https://ipapi.co/) 查询当前公网 IP 的位置，在菜单栏显示「城市 · 地区」，点击后查看国家、邮编、经纬度、时区、IP、运营商等详情。

- 启动时、每小时、电脑从睡眠唤醒时，以及网络断开后恢复或切换（换 Wi-Fi、开关 VPN）时自动刷新
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

查看刷新日志（网络变化、重试、成功或失败）：

```bash
/usr/bin/log show --last 10m --predicate 'subsystem == "local.ip-location-menu-bar"' --style compact
```

## 安装

把 `build/IPLocationMenuBar.app` 拖到「应用程序」文件夹，再从那里打开。开启「登录时启动」后，macOS 可能会要求你在「系统设置 → 通用 → 登录项」中允许它。

## 关于 ipapi 免费额度

ipapi.co 免费使用无需 API key，官方标注每天最多约 1000 次请求，仅建议用于测试和个人用途。本应用每小时请求一次，加上手动刷新，远低于这个额度。

ipapi.co 会对通用的 User-Agent 更严格地限流，所以本应用会带上自己的 User-Agent。如果仍然看到「请求过于频繁」，稍等片刻再刷新即可。

## 项目结构

```
Package.swift
Sources/IPLocationMenuBar/
  main.swift          应用入口
  AppDelegate.swift   菜单栏图标、下拉菜单、定时刷新
  IPAPIClient.swift   调用 ipapi.co 并处理错误
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
