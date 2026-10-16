---
title: "RTP 推流与 RTCP 反馈"
date: 2026-10-16T12:00:00+08:00
draft: false
tags: ["FFmpeg", "HEVC", "RTP", "RTCP", "UDP", "桌面串流"]
series: ["低延迟桌面串流全栈实战"]
weight: 6
summary: "复用标准 muxer 推流，用标准 RTCP 做关键帧反馈"
---

# 06 · RTP 推流与 RTCP 反馈

> 讲清楚数据面怎么用 ffmpeg rtp muxer 推流，以及关键帧反馈怎么走标准 RTCP PLI。
> 涉及模块：**传输层**（`rtp_pusher` 推流，`rtcp` 关键帧反馈）
> 术语约定：RTP/RTCP/PLI/PT/FU-A 等见本系列《导读与术语表》。

---

## 设计意图

编码出 `AVPacket` 后，怎么把它送到接收端？这一篇的两个核心决策：

1. **数据面用 ffmpeg 标准 rtp muxer，而不是自研 RTP 打包**——HEVC over RTP 的
   FU-A 分片、封包、SSRC/序号这些琐碎而极易出错的活，交给经过验证的标准实现。
   我们只负责：选对 URL/选项、把参数拷进流、直接写包。
2. **关键帧反馈走标准 RTCP PLI（RFC 4585），而不是私有消息**——PLI 是"我画面坏了，
   请立刻给 IDR"的标准语义，12 字节一包、与 RTP 同链路、少一跳。丢包恢复因此既快又标准。

一句话：**用标准协议做媒体，把自研精力省下来做私有控制面**（第 7 篇）。

---

## 1. 数据面：ffmpeg RTP muxer over UDP

发送端**用 ffmpeg 标准 rtp muxer**。要点：

```cpp
// 统一 URL：udp:// 转 rtp://（rtp muxer 内部经 udp protocol 发送）
std::string out_url = opts.url;                    // "rtp://0.0.0.0:8554"
avformat_alloc_output_context2(&raw, nullptr, "rtp", out_url.c_str());
stream_ = avformat_new_stream(ctx_.get(), nullptr);
avcodec_parameters_from_context(stream_->codecpar, codec_ctx);  // 拷贝编码器参数（带 extradata SPS/PPS）
stream_->time_base = time_base;

// 传输层参数统一经 URL 查询串交给 rtp:// → 内部 udp 协议
std::string query;
query += "rtcp_port=9560";          // RTCP 端口静态映射 9560，避开 8555 私有控制口
query += "&buffer_size=1048576";    // 1MB UDP 内核收发缓冲，抗 WiFi 抖动
query += "&connect=1";              // 连接式 UDP（性能更好、对端不可达可检测）
if (out_url.find('?') != std::string::npos) out_url += "&" + query;
else out_url += "?" + query;
avio_open2(&ctx_->pb, out_url.c_str(), AVIO_FLAG_WRITE, nullptr, nullptr);

// muxer 选项
av_dict_set(&mux_opts, "payload_type", "96", 0);   // 动态 PT=96，HEVC
av_dict_set(&mux_opts, "pkt_size", "1200", 0);     // RTP 分片粒度（FU-A），MTU 安全
avformat_write_header(ctx_.get(), &mux_opts);
```

写包：

```cpp
pkt->stream_index = stream_->index;
av_write_frame(ctx_.get(), pkt);   // 直接写，不经 interleave 重排缓冲
```

> 为什么能 `av_write_frame` 直接写？单流 HEVC、无 B 帧（DTS=PTS 单调），RTP 是流式封装
> 无需重排。close 时只有 `write_header` 成功才 `av_write_trailer`，再 `avio_closep`。

设计意图逐个拆解 URL 查询参数：

- **`rtcp_port=9560`**：rtp muxer 默认把 RTCP 放在"数据口 + 1"（8555），会撞上私有控制口。
  显式挪到 9560，**一个端口只服务一种协议**（呼应第 1 篇）。
- **`buffer_size=1048576`（1MB）**：UDP 内核收发缓冲，抗 WiFi 突发抖动导致的丢包，
  是"少花屏"的物理前提。
- **`connect=1`**：连接式 UDP。性能更好（内核直发），且对端不可达时可立即检测到，
  而不是静默丢包。但副作用是目标不能是 0.0.0.0——所以采集端要从控制面拿到显示端真实 IP。
- **`payload_type=96`**：动态 PT，HEVC 没有静态 PT，协商/约定用 96。
- **`pkt_size=1200`**：RTP 分片粒度，小于典型 MTU（1500）留余量，避免 IP 分片。

## 2. 媒体反馈：标准 RTCP PLI（RFC 4585）

PLI（Picture Loss Indication）的语义就是"我这边画面坏了/等不到可解码帧，请立刻给 IDR"。
走标准 RTCP 而不走私有消息的理由：12 字节一包即达、语义标准、与数据同链路（RTCP 口），
且采集端无需自定义状态机。

### 2.1 发送（接收端，viewer）

```cpp
// RFC 4585 §6.3.1：PSFB / FMT=1 / length=2（字，不含 4 字节头）
// 载荷 = sender SSRC + media source SSRC（不做 SSRC 协商，置 0）
const uint8_t pkt[12] = {
    0x80 | 1,      // V=2 P=0 FMT=1 (PLI)
    206,           // PT=206 (PSFB)
    0x00, 0x02,    // length = 2 words
    0,0,0,0,       // sender SSRC
    0,0,0,0,       // media source SSRC
};
sendto(s, pkt, sizeof(pkt), 0, &addr, sizeof(addr));   // UDP 直达采集端 9560
```

设计意图：12 字节手工组包就够了——RTCP 头 4 字节（V/P/FMT/PT/len）+ 两个 SSRC 各 4 字节。
我们不做 SSRC 协商（置 0），是因为只跑单流单点，协商没有价值；**为不必要的东西买单
是违背低延迟原则的**。

### 2.2 接收（采集端）

`RtcpPliReceiver` 绑定 9560，后台线程收包。RTCP 复合包可能含多个 RTCP 包，按 4 字节头逐段解析：

```cpp
bool rtcpPacketHasPli(const uint8_t* buf, size_t len) {
  size_t off = 0;
  while (off + 4 <= len) {
    const uint8_t pt = buf[off + 1];
    const size_t word_len = (buf[off+2] << 8) | buf[off+3];
    const size_t pkt_len = (word_len + 1) * 4;
    if (pkt_len < 4 || off + pkt_len > len) break;
    if ((buf[off] >> 6) == 2 && pt == 206 && (buf[off] & 0x1f) == 1) return true;  // PLI
    off += pkt_len;
  }
  return false;
}
```

采集端收到 PLI → `pli_pending_.store(1)`，主循环 `consumePli()` 非阻塞消费 →
`force_idr_left_ = 10`（强制连发 10 帧 IDR，抗 WiFi 丢包）。

设计意图：
- **逐段解析**：RTCP 常复合发送（如 SR + 几个反馈包），不能只看第一段，要按 `length`
  字段跳过每段，直到找到 PLI 或越界。
- **`force_idr_left_ = 10` 而非 1**：WiFi 丢包通常是突发，一帧 IDR 也可能被丢，
  连发 10 帧 IDR 显著提高"接收端拿到至少一个完整 IDR"的概率。
- **原子标志 + 非阻塞消费**：收包线程只置标志，主循环消费，避免跨线程锁。

## 2.3 数据面与反馈的标准细节（RFC 3550 / RFC 7798 / RFC 4585）

**RTP 基本头（12 字节）**：V=2；M 标记位（HEVC：IDR 帧最后一包可置 1，参考用）；
PT=96；**sequence number**（16 位，乱序检测/重排依据）；**timestamp**（32 位，
90000Hz 时钟，一帧内所有包同时间戳）；SSRC（同步源标识）。帧间隔 @60fps=1500 tick、
@25fps=3600 tick。

**HEVC over RTP（RFC 7798）Payload 头（2 字节）**：`|F| Type | LayerId | TID|`。
Type：1=单 NAL；2=**STAP-A**（聚合，小 NAL 如 SPS/PPS/SEI 通常这样聚合省开销）；
49=**FU-A**（分片，大 NAL 如 IDR）。FU-A 用 FU 头 `|S|E|FuType|`：S=1 首片、E=1 尾片，
一个 NAL 的所有分片同一时间戳、序列号连续，重组按序列号拼回 NAL。

**接入单元（AU）** = 同一时间戳的全部 NAL。解码器要求**参数集先于 VCL 帧**（同一 AU 内
VPS/SPS/PPS 在前）。

**关键帧请求的两种标准消息**：
- **PLI（RFC 4585 §6.3.1）**：FMT=1、PT=206（PSFB），12 字节。语义="画面损坏/无法解码，
  请给 IDR"。本工程用它。
- **FIR（RFC 5104，FMT=4）**：更强（带 FCI 目标 SSRC 列表）；PLI 已够用，未采用。

**低延迟接收端标准实践（jitter buffer）**：接收端必须容忍网络乱序（WiFi 常见 0.5%~5%）：
- 按 RTP 序列号维护固定小窗口（8~32 包），窗口内按序交付；
- 乱序包等待 ≤ 窗口上限，超时（如 20ms）未齐 → 丢最老包/整帧；
- 大乱序（序列号跳跃 > 窗口）→ 立即刷新，等下一关键帧；
- **绝对不能**用"等所有乱序包齐了再播"的全缓冲——这正是 ffmpeg sdp demuxer 的
  reorder 行为，是延迟元凶（见第 8 篇）。

> 为什么关键帧反馈走 RTCP 而非私有：RTCP 与数据同链路（RTCP 口 9560），少一跳、语义
> 标准、与 RTP/RTCP 生态对齐；私有 requestKeyframe 走 8555 多一跳且语义私有，已作兼容
> 路径废弃，统一走 RTCP PLI。

## 3. 端口与职责小结

| 端口 | 方向 | 职责 |
|---|---|---|
| 8554 | capture→viewer | RTP 数据（HEVC，PT=96，FU-A 1200B） |
| 9560 | 双向 | RTCP：capture 发 SR；viewer 发 **PLI** |
| 8555 | 双向 | 私有控制（心跳/帧率/OSD/暂停——见第 7 篇） |

> 为什么关键帧不走私有控制面：私有 requestKeyframe 走 8555，多一跳且语义私有；
> RTCP PLI 与数据同链路（RTCP 口），少一跳、语义标准、与 RTP/RTCP 生态对齐。

> 绑定 9560 前要 `SO_REUSEADDR`——同机 ffmpeg rtp muxer 也占用 RTCP 端口发 SR，
> 不设置会 bind 失败。

## 4. 一句话总结

**发送 = ffmpeg rtp muxer over UDP（PT=96、pkt_size=1200、rtcp_port 显式避开控制口）**；
**反馈 = 12 字节标准 RTCP PLI，收 PLI → 强制连发 IDR 恢复**。数据面无重传、无排队，
丢包靠 PLI+IDR（≤1 GOP 自愈）——**这是低延迟与自愈的平衡点**。

---

