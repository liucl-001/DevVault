---
title: "系统总览与架构"
date: 2026-10-16T09:30:00+08:00
draft: false
tags: ["FFmpeg", "HEVC", "RTP", "桌面串流", "Windows", "架构"]
series: ["低延迟桌面串流全栈实战"]
weight: 1
summary: "先把链路、分层、取舍立起来，后面每章才有上下文"
---

# 01 · 系统总览与架构

> 先建立全局：整条链路怎么走、工程怎么分层、为什么做了这些取舍。
>
> **本文自包含**：不依赖任何特定工程的源码。文中的分层、代码片段均为可直接照抄或
> 改编的**参考实现**，你可以完全按本文从头写出一套可运行的系统。
> **术语约定**：RTP/RTCP、IDR、硬件上下文等术语统一见本系列《导读与术语表》，不再逐一解释。

---

## 设计意图

这一篇回答三个"为什么"：

1. **为什么是"采集→编码→传输→解码→显示"这条链**——桌面串流的本质，就是被控机的帧
   变成字节在网络上走一圈，再在当前机还原成帧。顺序即数据流，理解它等于理解全部。
2. **为什么分层这么切**——每一层只认"上层需要的抽象"，不认"下层长什么样"，
   这是后面"加采集方式/换编码器/换显示"都能只动一处的根本。
3. **为什么做了这些反直觉的取舍**——延迟预算逼出来的每个决定，都不是偏好而是必然。

---

## 1. 一条链路，四个节点

```
被控机（capture / 采集端）
  屏幕 → [采集] → [硬件编码] → [RTP muxer] ──UDP 8554──►
                                                          │
当前机（viewer / 接收端）                                  │
  ◄──────UDP 9560 (RTCP PLI)──────────────────────────────┘
  [SDP demuxer 收流] → [硬件解码] → [SDL 渲染] → Qt 窗口 / 独立窗口
```

三张网（端口划分是这套系统最容易踩坑的地方）：

| 通道 | 端口 | 方向 | 内容 |
|---|---|---|---|
| 数据面 RTP/UDP | **8554** | capture → viewer | HEVC over RTP（PT=96，FU-A 分片，pkt_size=1200） |
| 标准媒体反馈 RTCP | **9560** | 双向 | viewer → capture 的 **PLI**（请求立即出 IDR）；capture → viewer 的 SR（ffmpeg 自动发） |
| 私有控制面 UDP | **8555** | 双向 | 心跳、帧率协商、OSD/光标上报、暂停/恢复 |

> **端口设计的关键教训**：RTP 数据口 + 1（8555）正好撞上私有控制口。ffmpeg rtp muxer
> 默认把 RTCP 放在"数据口 + 1"，所以必须用 URL 查询串显式 `rtcp_port=9560`，否则 RTCP
> 会挤占私有控制口。把 RTCP 挪到 9560（8554+406），两个控制通道各归其位。
> —— 设计意图：**一个端口只服务一种协议**，避免"两个协议撞一个口"的定位噩梦。

## 2. 工程分层（推荐这样切，依赖只允许自上而下）

```
入口层        统一入口：子命令 run|capture|viewer|viewer-qt|selftest
公共层        common：日志、RAII、Winsock、私有控制面(UDP 8555)、SEI 时间戳
平台层        platform：会话/锁屏(WTS)、显示器枚举/DPI  ← 唯一直接调平台 API 的层
采集层        capture：IScreenCapturer + 自动降级链 + windows/{dxgi,gdi}
编解码层      codec：hw_codec(厂商→编码器映射/低延迟旗标) + hevc_encoder
传输层        transport：rtp_pusher(RTP/UDP) + rtcp(PLI)
应用层        app：stream_app(状态机) + capture_main + run_main(常驻/托盘)
接收端        viewer：命令行接收端，RTP 收流 + 硬件解码 + SDL 显示
产品化接收端  viewer_qt：Qt6 界面 + SDL 渲染嵌入 + 屏幕切换 SDK 门控
```

分层约束，每条都是设计意图：

- **common 不依赖任何层**（只依赖 ffmpeg/spdlog/Winsock）——最底层工具，谁都能用。
- **platform 只依赖 common**，且是唯一允许直接调 Win32 会话/显示 API 的地方——
  把"平台特定"关在一个笼子里，其余层不碰平台 API，换平台只换这一层。
- **capture 依赖 platform**（锁屏状态决定降级顺序）与 common——采集器知道"现在锁没锁屏"，
  但不知道也不关心编码器是谁。
- **codec 依赖 common**，只认 `AVFrame`/`AVCodecContext`，不认识采集实现——
  所以同一套编码器既能吃 DXGI 硬件帧，也能吃 GDI 软帧。
- **app 是组合根**，唯一同时知道 采集→编码→传输 三者，负责把它们串成状态机。

> 依赖图是"严格自上而下、不允许环"。设计意图：**新增一个后端/编码器/接收端时，只需在
> 归属层加代码 + 在组合根登记一行**，其它层零改动。

## 3. 依赖与构建（vcpkg 严格锁版）

`vcpkg.json` 关键点：**ffmpeg 用 features 裁剪，关掉 default-features**。

```json
{ "name": "ffmpeg",
  "version>=": "8.1.2",
  "default-features": false,
  "features": ["amf","qsv","avcodec","avformat","swscale","nvcodec"] }
{ "name": "sdl2",     "version>=": "2.32.10" }
{ "name": "sdl2-ttf", "version>=": "2.22.0" }
{ "name": "qtbase",   "version>=": "6.8.2" }
```

- `nvcodec` 编进来才有 `hevc_nvenc`/`hevc_cuvid`/`hevc_nvdec`；`qsv` 才有 `hevc_qsv`；
  `amf` 才有 `hevc_amf`；`swscale` 用于解码后 NV12→RGB24（SDL 与 Qt 上屏都用）。
- `overrides` 锁死 ffmpeg 8.1.2 / sdl2 2.32.10 / qtbase 6.8.2，保证可复现。
- 构建：`cmake --preset release && cmake --build --preset release`，产物为单个
  可执行文件（子命令分发），运行库由 vcpkg 自动部署到同目录。

> 设计意图：**features 裁剪**让每个库只带需要的能力，二进制小、启动快、编译面小；
> **overrides 锁版**让"换台机器能编出一样的东西"，可复现是工程底线。

## 4. 延迟优先的取舍（理解本工程设计的钥匙）

| 取舍 | 原因 / 设计意图 |
|---|---|
| 只支持 Windows x64（`platform.h` 里 `#error`） | 跨平台折中必然抬高延迟与复杂度；先做一个平台做极致 |
| 只走硬件编解码，**无软件回退** | 软编一帧几十毫秒，直接击穿延迟预算；宁可启动即失败，不悄悄变卡 |
| 编码标准：**只用 HEVC（H.265）** | 同画质码率比 H.264 省 30~50%——局域网/WiFi 流量更省、更抗丢包；VP9/AV1 桌面端硬编不成熟，H.264 码率偏高。详见第 5 篇 |
| 采集侧 DXGI 主路径，GDI 锁屏专用 | 锁屏/安全桌面 DXGI 不可用，只能 GDI 采集（CPU 拷贝 10-30ms） |
| 数据面 RTP/UDP，不做重传 | 重传=排队=延迟；丢包靠 PLI+IDR 恢复（≤1 GOP 自愈） |
| 解码 `thread_count=1` | 多线程解码用延迟换吞吐 |
| 静止画面降帧 + 缓存帧重推 | 静态桌面不必 60fps 空推；恢复变化时强制 IDR |

> 这串取舍的共同主线：**每一环都在用"确定性的低延迟"换"吞吐/花哨"**。理解这一点，
> 后面每一章的代码都有了解释。

## 5. 运行命令（快速上手）

```bat
:: 以下用 <app> 代指你的程序可执行文件名
:: 采集端（被控机）
<app> capture --url rtp://0.0.0.0:8554 --control-port 8555
::   可选：--fps 60 --bitrate 8000 --encoder auto|nvenc|qsv|amf --gop 60
::          --cbr --no-dpi-scale --capture-backend auto|dxgi|gdi

:: 接收端（当前机）
<app> viewer --url rtp://<被控机IP>:8554 --remote-screen <屏幕名>
::   可选：--control-port 8555 --window-title TITLE --no-gating

:: 产品化接收端（Qt + SDL 嵌入）
<app> viewer-qt --conn rtp://<被控机1>:8554 --screen PC-A [--conn ...] ...
```

## 6. 部署要点（装到目标机要满足什么）

**端口与防火墙**（被控端=采集端，显示端）：

| 端口 | 协议/用途 | 绑定方 |
|---|---|---|
| 8554 | RTP 数据面 | 采集端监听，显示端收流 |
| 8555 | 私有控制面（心跳/fps/osd/status/cursor） | 采集端监听，viewer 以 `--control-port 8555` 连接 |
| 9560 | RTCP（标准 PLI 关键帧请求，RFC 4585） | 采集端监听，显示端发 PLI |

- 采集端需**入站 UDP 放行** `8554-8558 / 9560`（覆盖数据面 8554、控制面 8555），否则显示端收不到画面/控制面。
- 显示端 viewer 的控制面是 `bind(0)` 随机端口 + `recvfrom`（未 connect），采集端回发的
  status/cursor 走临时 socket——**必须为程序添加程序级 UDP 入站放行规则**（覆盖所有端口），
  否则防火墙一开就收不到 OSD/光标上报（状态段缺失、光标停在 0,0）。

**锁屏采集必须用"服务"部署**：锁屏后进程掉入 Session 3、普通权限拿不到 winlogon 桌面句柄，
必须由 SYSTEM 服务克隆令牌到 Session 3 采集登录界面。便携包（无服务）锁屏场景不可用。

**目标机要求**：Windows x64（Win10/11+）；编码 hevc_qsv/hevc_amf 需对应 Intel/AMD 核显；
VC++ 2015-2022 Redist。

## 7. 新增平台与可扩展点（分层的验收标准）

新增一个平台（例如 Linux）只需动两层，**上层零改动**：

1. 新建平台层，实现会话/锁屏（如 logind D-Bus `LockedHint`）与显示器枚举/DPI 等价物；
2. 新建采集层后端（如 PipeWire portal / X11 XShm），在后端目录注册；
3. 顶层 CMake 按平台 `add_subdirectory` 链接对应平台库；
4. 放开平台门控（编译期 `#error`）。

> 验收标准：**新增平台时 app/codec/transport 不需要任何改动**。这正是分层"依赖只允许
> 自上而下"的直接收益。

---

