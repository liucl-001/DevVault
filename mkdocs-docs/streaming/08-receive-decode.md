---
title: "RTP 接收与硬件解码"
date: 2026-10-16T13:00:00+08:00
draft: false
tags: ["FFmpeg", "HEVC", "RTP", "硬件解码", "SDP", "桌面串流"]
series: ["低延迟桌面串流全栈实战"]
weight: 8
summary: "播放器式接收改成实时式，丢包靠同步窗口 + PLI 恢复"
---

# 08 · RTP 接收与硬件解码

> 讲清楚接收端怎么低延迟收流，以及怎么在 FFmpeg 里开启硬件解码。
> 涉及模块：**接收端**（RTP 收流 + 硬件解码，`TcpReceiver`）
> 术语约定：SDP/PLI/同步窗口/hw 上下文等见本系列《导读与术语表》。

---

## 设计意图

接收端是"体验的最后一公里"，这一篇要解决三个矛盾：

1. **播放器式收流默认"攒数据"，实时式必须"零缓冲"**——ffmpeg 的 demuxer 选项默认偏
   播放器（预读、攒包、大重排窗），不改成实时配置，延迟会堆积到几秒。
2. **"编入"不等于"可用"**——硬件解码器要真正能用，必须在**本机**创建出对应 GPU 设备。
3. **丢包不能白屏/绿屏**——同步窗口 + 标准 PLI 请求，是低延迟下唯一高效的恢复手段。

一句话：**收流做实时化改造，解码走硬件探测，恢复靠等干净关键帧 + 请求关键帧。**

---

## 1. 收流：SDP demuxer + 低延迟配置

接收端用 ffmpeg **sdp demuxer**（当前实现），并做了一堆"播放器式→实时式"的低延迟配置：

```cpp
// ffmpeg rtp demuxer 无 SDP 时无法从动态 PT 推断 HEVC，必须显式映射。
// 解析 rtp://<ip>:<port> 的端口，生成固定描述 SDP 写入临时文件：
//   m=video %d RTP/AVP 96
//   a=rtpmap:96 H265/90000
input_fmt = av_find_input_format("sdp");
avformat_open_input(&raw, sdp_path, input_fmt, &options);

// ===== 低延迟接收配置（延迟/白屏的根治点）=====
av_dict_set(&options, "reorder_queue_size", "4", 0); // 乱序容忍窗口（见下）
av_dict_set(&options, "fflags", "nobuffer", 0);      // 禁预读/攒包
av_dict_set(&options, "probesize", "1048576", 0);    // 参数集随 IDR in-band
av_dict_set(&options, "analyzeduration", "500000", 0);
av_dict_set(&options, "timeout", "3000000", 0);      // 3s 无包 → EOF，上层重连
av_dict_set(&options, "buffer_size", "4194304", 0);  // 4MB UDP socket 接收缓冲
```

设计意图逐个拆：

- **`reorder_queue_size=4`（延迟头号坑）**：大帧（2132×1332 HEVC 每帧 70+ RTP 分片）下，
  默认 32 包窗口实测造成固定 ~6s 积压（WiFi 乱序时 rtpdec 大量缓存重组，解码帧晚 5.9s
  才输出）。改 4 包窗口 = 一帧内小幅乱序容忍，正常序零缓冲，WiFi 常态乱序丢帧由 PLI 恢复。
  设计意图：**乱序容忍窗口是在"能解完整帧"与"低延迟"之间取的小值**——宁可丢一帧
  （靠 PLI 恢复），也不要为等它多攒几秒。
- **`nobuffer`**：禁掉 demuxer 的预读/攒包行为，这是实时性的总开关。
- **`probesize`/`analyzeduration`**：让"参数集随 IDR in-band"能被探测到（HEVC 无 extradata
  时依赖这个），否则找不到码流参数。
- **`timeout`**：UDP 无 EOF，靠它让"采集端没了"能被检测出来，转成上层重连。
- **`buffer_size`（4MB）**：加大 socket 接收缓冲，抗 WiFi 突发。

### 断流中断回调（AVIOInterruptCB）

RTP（UDP）数据面无 EOF，采集端崩溃/断网后 `av_read_frame` 会无限阻塞。用中断回调按
"最近收包时间"判定超时：

```cpp
fmt_->interrupt_callback.callback = &TcpReceiver::interruptCb;
int TcpReceiver::interruptCb(void* opaque) {
  self = (TcpReceiver*)opaque;
  return (nowMs() - self->last_pkt_ms_.load() > kNoPktTimeoutMs) ? 1 : 0;  // >1.5s 无包中断
}
```

采集端保活 SEI 每 1s 一条，正常链路不会误判。

设计意图：`AVIOInterruptCB` 是 ffmpeg 提供的"中断长阻塞"机制——否则 UDP 收不到包时
`av_read_frame` 永远卡住，无法感知采集端掉线。配合第 7 篇的保活 SEI（每秒一条），
"1.5s 无包 = 断流"既灵敏又不误杀。

## 2. 在 FFmpeg 里开启硬件解码

### 2.1 解码器选择：探测候选表

```cpp
for (const auto& candidate : decoderCandidates()) {   // cuvid→nvdec→qsv→d3d11va
  const AVCodec* cdec = avcodec_find_decoder_by_name(candidate.decoder_name);
  if (!cdec) continue;
  // 真正"可用" = 编入 + 本机能创建对应硬件设备
  AVBufferRef* hw_raw = nullptr;
  int hrc = av_hwdevice_ctx_create(&hw_raw, candidate.hw_type, nullptr, nullptr, 0);
  if (hrc == 0) { codec = cdec; hw_type = candidate.hw_type; break; }
}
if (!codec) { last_error = "no HEVC hardware decoder available"; return false; }
```

**编入 ≠ 可用**：`avcodec_find_decoder_by_name` 只说明 ffmpeg 编进了这个解码器，
必须再 `av_hwdevice_ctx_create` 创建硬件设备成功，才算真可用。这就是"本机没有硬件解码
就启动即失败"（无软解回退）的实现。

设计意图：**探测即验收**——"能不能硬件解码"用"能不能在本机创建 GPU 设备"来判定，
而不是看编译时有没有编入。这样本机没有对应 GPU/驱动时会诚实失败，而不是运行到一半
才崩。候选表顺序也是设计：cuvid/nvdec（NVIDIA）优先，qsv（Intel）次之，d3d11va 兜底。
> 注意这里与编码端不同（第 5 篇）：编码端一张卡只有一个硬件编码器，按厂商绑定即可；
> 解码端同一厂商可能有多个解码器（如 NVIDIA 的 cuvid/nvdec），且需 d3d11va 兜底，
> 所以按序探测"本机真正能打开的第一个"——这是软件在硬件能力集合内做可用性探测，
> 仍以硬件为准，不是凭空选择。

### 2.2 打开硬件解码器

```cpp
dec_ = AvCodecContextPtr(avcodec_alloc_context3(codec));
avcodec_parameters_to_context(dec_.get(), stream->codecpar);   // 从流参数填上下文
dec_->thread_count = 1;                                        // 低延迟单线程
applyLowLatencyFlags(dec_.get(), /*decoding=*/true);           // LOW_DELAY + 无B帧 + 单线程

if (strcmp(codec->name, "hevc_cuvid") == 0 || strcmp(codec->name, "hevc_nvdec") == 0) {
  av_opt_set(dec_->priv_data, "delay", "0", 0);   // 最小化解码缓冲
  av_opt_set(dec_->priv_data, "surfs", "4", 0);   // 解码器并行表面压到最小
}
dec_->hw_device_ctx = av_buffer_ref(hw_ctx_.get());   // 关键：把硬件设备挂到上下文
avcodec_open2(dec_.get(), codec, nullptr);
```

硬件解码的**唯一关键**就是 `dec_->hw_device_ctx = av_buffer_ref(hw_ctx_)`——
解码器通过它知道用哪个 GPU 设备做加速。

设计意图：**开启硬件解码 = 挂 hw_device_ctx**，就这么一步。其余（`thread_count=1`、
`delay=0`、`surfs=4`）都是低延迟参数的落实——解码线程少、缓冲小、表面池压到最小，
全是为了"解出第一帧越快越好"。

### 2.3 设备上下文跨重连复用（秒开的关键）

```cpp
if (hw_ctx_) {
  // CUDA/cuvid 的 av_hwdevice_ctx_create 实测阻塞 2.5s（驱动栈初始化）。
  // 同一 receiver 实例重连时 hw_ctx_ 保留（teardownDecoder 不释放），
  // 解码器重建但设备上下文复用，秒开。
} else {
  av_hwdevice_ctx_create(&hw_raw, hw_type, nullptr, nullptr, 0);
}
```

设计意图：**设备上下文是"重"资源，解码器是"轻"资源**。首次 2.5s 的驱动初始化成本
只付一次，之后每次重连只重建解码器（毫秒级）而复用设备——这就是"断线秒回"的底气。

### 2.4 解码器 lazy init（避免首帧积压黑洞）

不在 `open` 内初始化解码器——`av_hwdevice_ctx_create(CUDA)` 阻塞 2.7s，期间 RTP 包
在 socket/reorder 积压，消费时全被判 old 丢弃 → dropping 刷屏 + 首帧依赖下一次 IDR。
改为 open 返回后立即进入消费循环，**首个包到达时才创建硬件解码器**：

```cpp
decoder_ready_ = false;   // open 里
valid_ = true;
waiting_keyframe_ = true; // 等首个关键帧再解码，避免绿屏
// readAndDecode 里：
if (!ensureDecoder()) return -1;   // 首个包到达时 setupDecoder()
```

解码器就绪后立即刷新 `last_pkt_ms_`（否则 find_stream_info + 解码器初始化期间
`av_read_frame` 不在循环内，会被中断回调误判断流重连）。

设计意图：**把 2.7s 的初始化成本移到"首包到达后"**，而连接 / find_stream_info 本身
不阻塞——否则这 2.7s 内 RTP 包在缓冲里越积越多，消费时已全部过期，等于白等。这
是"秒连 + 秒首帧"的另一个关键。

## 3. 同步窗口与丢包恢复（waiting_keyframe）

连接/重连/丢包恢复后进入**同步窗口**：只送"参数集/IDR"给解码器，丢弃普通 VCL（P/B）帧——

```cpp
if (waiting_keyframe_.load()) {
  const bool pkt_is_key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
  const bool is_idr = pkt_is_key || isHevcIdrNal(pkt.get());   // NAL type 19/20
  const bool is_sync = isHevcSyncNal(pkt.get());               // 参数集(32-34)/IDR
  if (!is_idr && !is_sync) { av_packet_unref(pkt.get()); return 0; }  // 丢 P/B
  if (avcodec_send_packet(dec_.get(), pkt.get()) < 0) return -2;      // IDR 损坏，保持等待
  if (!is_idr) { ... receive 清空但不显示 ...; return 0; }
  idr_already_sent = true;   // IDR 已送入，走下方 receive/显示
}
```

- IDR 识别：KEY flag 优先，缺失时按 NAL 头（type 19/20）兜底。
- **为什么不能只看 KEY flag**：参数集是独立 RTP 包且不带 KEY flag，丢弃会导致 IDR 解码
  报 "PPS id out of range"；部分封装也不给 IDR 包设 KEY flag，故同步窗口必须显式保留
  参数集与 IDR，只丢弃普通 VCL（P/B 帧）。
- 同步期丢弃非 I 帧，从根上杜绝"无参考帧解出绿画面"。
- 解码出错（`avcodec_send_packet < 0`）返回 -2，上层**不重连**（数据面正常），
  重新进入同步窗口 + 请求关键帧。

设计意图：**绿屏的根因是"把没有参考的 P/B 帧喂给了解码器"**。同步窗口 = 在确认拿到
干净 IDR 之前，只放行参数集和 IDR，其余一律丢弃。这套"宁丢勿花"的策略配合 RTCP PLI，
是低延迟下唯一能同时满足"秒开"和"不花屏"的恢复机制。

## 4. 输出下载与转码

```cpp
int r = avcodec_receive_frame(dec_.get(), frame_.get());
if (r == 0) {
  if (waiting_keyframe_.load()) { waiting_keyframe_.store(false); }  // 首个 IDR 解出：解除同步
  // 硬件解码输出为 GPU 帧：先下载到 CPU（download_）
  AVFrame* yuv = frame_.get();
  if (av_pix_fmt_desc_get(frame_->format) && (desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
    av_hwframe_transfer_data(download_.get(), frame_.get(), 0);   // GPU → CPU
    yuv = download_.get();
  }
  cb(yuv);   // 回调把 NV12 帧交给显示层；显示层再 sws 转 RGB24 上屏（见第 9 篇）
}
```

设计意图：**硬件解码输出的是 GPU 帧，显示层要 CPU 像素**，所以必须
`av_hwframe_transfer_data` 下载到 CPU，得到 NV12。显示层（SDL/Qt）再用 `sws_scale`
把 NV12 转成 **RGB24** 交给 `SDL_UpdateTexture(RGB24)` 上屏——**颜色转换在 CPU 完成**；
SDL 的 GPU 渲染器只负责 RenderCopy 时的缩放与合成（光标/OSD overlay），不做颜色转换
（见第 9 篇）。

## 5. 现状与演进方向

**为什么 sdp demuxer 不适合实时链路（诊断结论）**：ffmpeg 的 rtp/sdp demuxer 定位是
"播放器/文件"——内部 reorder 缓冲会**等乱序包**（WiFi 下积压成秒级延迟），`dropping
old packet` 是缓冲满丢包，并非标准低延迟行为；且 open 探测（analyzeduration/probesize）
串行会拖慢首帧。当前工程用"小 reorder 窗口 + nobuffer + 关键帧门控"做了大量补丁，
把延迟压回目标，但这些是围绕 demuxer 的补丁而非其原生能力。

**演进方向：自研 `RtpReceiver`（RFC 7798 解包 + 可控 jitter buffer）**。结构建议：

```
RtpReceiver
├── UdpSocket      WinSock 收包（8554，内核缓冲 2MB）
├── RtpParser      RFC 3550 头解析（seq/timestamp/ssrc/PT）
├── HevcParser     RFC 7798：单 NAL / STAP-A / FU-A 解包
├── JitterBuffer   按序列号小窗口排序（≤16 包 / 20ms 超时）
├── AuAssembler    按时间戳组装完整 AU → 完整 NAL 帧
├── ParamSets      VPS/SPS/PPS 缓存 → 构建 extradata → avcodec
└── RtcpSession    周期 RR；PLI 请求（超时/解码错误/丢包）
```

接收流程：UDP 收包 → 解析 RTP 头（丢弃非目标 PT/SSRC）→ HevcParser 解出 NAL（分片先入
FU 缓冲按序列号拼）→ JitterBuffer 按序列号排序 → AuAssembler 组装完整 AU → 组装
AVPacket（extradata=ParamSets）→ send_packet → receive → 上屏。等待关键帧期间只收
IDR AU、超时发 PLI。

> 这样能从根上告别"为 demuxer 打补丁"，把低延迟接收做成原生能力。当前工程已把
> 厂商→解码器映射与低延迟旗标统一到 `hw_codec`，下一步把解码循环也抽到编解码层，与采集侧
> 完全对称。

## 6. 一句话总结

**收流 = SDP demuxer + 小乱序窗口 + 中断回调防死等；解码 = 候选表探测设备 → 挂
hw_device_ctx → open2 → 硬件帧下载到 CPU；恢复 = 同步窗口等干净 IDR + PLI 请求**。
接收端每一处配置都指向同一个目标：**首帧快、不花屏、掉线秒回。**

---

