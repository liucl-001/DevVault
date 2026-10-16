# 05 · 硬件编码：把 GPU 编码器（NVENC/QSV/AMF）接进 FFmpeg

> 系列第 5 篇。核心：怎么把采集到的帧喂给 GPU 编码器，做到零拷贝、低延迟。
> 涉及模块：**编解码层**（策略 `hw_codec`，编码器 `hevc_encoder`）
> 术语约定：NVENC/QSV/AMF、hw_device_ctx/hw_frames_ctx、EAGAIN 等见 《系列导读 · 术语表》。

---

## 设计意图

**先回答一个前置问题：为什么码流只用 HEVC（H.265），不引入其他编码标准？**

桌面串流对"流量"极敏感——同一块画面，标准越新，同画质下码率越低。HEVC 在同画质下
约比 H.264 省 30~50% 码率；局域网/WiFi 带宽有限且天然抖动，码率越低越稳、越抗丢包，
也越能留出 RTCP PLI 等反馈的余量。VP9/AV1 压缩率虽更高，但**硬编在桌面端不成熟**
（AV1 硬编要 2023+ 显卡，VP9 几乎没有硬编），串流要的是低延迟硬编硬解，不能用软编兜底。
所以最终**只锁定 HEVC**：三大家（NVENC/QSV/AMF）都支持 HEVC 硬编，2016+ 的独显/核显
普遍 HEVC 硬解，硬编硬解生态最成熟。代价是**硬解门槛**——解码端必须有 HEVC 硬解，
纯软解/老显卡用不了。这正是后面"按厂商绑定硬编 + 接收端 HEVC 硬解（无软解回退）"整套
设计的由来。H.264 不是不能做（三大家的 H.264 硬编同样成熟），只是同画质码率更高，
不符合"更低流量"这个首要目标。

---

延迟预算里，编码是除采集外最大的开销。这一篇要解决三个问题：

1. **编码器是显卡决定的，软件不做"选择"**——一台机器用哪张显卡，硬件就只支持它那
   一家的编码器（NVIDIA→NVENC / Intel→QSV / AMD→AMF），这是死的、软件改不了。
   软件唯一能做的，是探测 GPU 厂商（vendor），把"这张卡"映射到**它唯一支持的编码器名**，
   再配上统一的低延迟参数。编码端与接收端共用这张"厂商→编码器/解码器"映射，是为了
   **解码端一定能解出编码端选的格式**（格式对齐），而不是软件去"挑"编码器。
2. **怎么把采集帧喂进去还保持零拷贝**——DXGI 抓到的是 D3D11 纹理，NVENC/AMF 原生就吃
   这种纹理，QSV 只吃 NV12 表面，GDI 抓到的是 CPU 像素。三种输入，三种接法。
3. **怎么应对异步编码的边界**——`EAGAIN`/`EINVAL` 的语义不搞清，要么丢帧要么卡死。

---

## 1. 硬件能力探测：hw_codec（编解码共用一张"厂商→编码器"映射）

这张表不是"可选的候选"，而是"**厂商 → 编码器/解码器名 + 统一低延迟参数**"的固定映射：
探测到哪个 vendor，就绑定到它唯一支持的编码器。**编码端与接收端解码共用同一张表**，
保证解码端能解编码端用的格式——这是"格式对齐"，不是"挑编码器"。

```cpp
// 厂商→编码器名映射（按 vendor 匹配，非遍历择优），绝不回退 libx265
encoderCandidates() → {{"hevc_nvenc", kNvidia, "NVENC"},
                       {"hevc_qsv",   kIntel,  "QSV"},
                       {"hevc_amf",   kAmd,    "AMF"}};
// 厂商→解码器名映射（同一张表给接收端用）
decoderCandidates() → {{"hevc_cuvid",  AV_HWDEVICE_TYPE_CUDA,   "CUVID"},
                       {"hevc_nvdec",  AV_HWDEVICE_TYPE_CUDA,   "NVDEC"},
                       {"hevc_qsv",    AV_HWDEVICE_TYPE_QSV,    "QSV"},
                       {"hevc_d3d11va",AV_HWDEVICE_TYPE_D3D11VA,"D3D11VA"}};
```

统一低延迟旗标（编解码共用）：

```cpp
void applyLowLatencyFlags(AVCodecContext* ctx, bool decoding) {
  ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;  // 不允许为吞吐做帧级缓冲
  ctx->has_b_frames = 0;                  // 无 B 帧 → 无重排序 → 解码端无需 reorder
  if (decoding) { ctx->thread_count = 1; ctx->thread_type = 0; }  // 单线程解码
}
```

设计意图：**一张映射表两端共用**——采集端按本机显卡绑定到唯一编码器，接收端用同一张表
选对应的解码器，保证"编码端用什么格式，解码端就能解什么"；改一处即全同步。
**LOW_DELAY + 无 B 帧 + 单线程解码**是贯穿全系统的三条延迟红线。

## 2. 编码器厂商匹配

**硬件直通要求抓屏与编码在同一 GPU**，编码器必须匹配设备厂商。通过 DXGI 读 GPU VendorId：

```cpp
// 共享 D3D11VA 设备路径：d3d->device → IDXGIDevice → GetAdapter → GetDesc
// 软路径：CreateDXGIFactory1 → EnumAdapters1(0) → GetDesc1
switch (vendor_id) {
  case 0x10DE: want = "hevc_nvenc"; break;  // NVIDIA
  case 0x1002: want = "hevc_amf";   break;  // AMD
  case 0x8086: want = "hevc_qsv";   break;  // Intel
}
```

显式传 `--encoder libx265` 之类软件编码器会被拒绝（只接受 hw_codec 登记的硬件编码器），
实现"只走硬件、无软回退"对用户输入的覆盖。

设计意图：**编码器必须和抓屏同一家 GPU**——NVENC 不能编码 AMD 的 D3D11 纹理。
而软件编码器被拒绝，是因为软编一帧几十毫秒，直接击穿延迟预算，宁可启动即失败，
也不悄悄变卡（符合第 1 篇的取舍表）。

## 3. 三条输入路径（本系列最核心的编码知识点）

`HevcEncoder::init(opts, shared_hw_ctx, shared_frames_ctx)` 按输入来源分流：

| 路径 | 触发条件 | 输入帧 | pix_fmt | 说明 |
|---|---|---|---|---|
| **A. DXGI 硬件直通** | `shared_hw_ctx != nullptr` 且非 QSV | D3D11 BGRA 纹理 | `AV_PIX_FMT_D3D11` | NVENC/AMF 原生消费 B8G8R8A8，**零转换零拷贝** |
| **B. QSV 硬件直通** | `shared_hw_ctx != nullptr` 且 QSV | D3D11 纹理(BGRA/NV12) | `AV_PIX_FMT_QSV` | QSV 只吃 NV12，需 GPU 内 BGRA→NV12 |
| **C. GDI 软路径** | `shared_hw_ctx == nullptr` | CPU NV12 | `AV_PIX_FMT_NV12` / `AV_PIX_FMT_QSV` | 硬件编码器原生支持 CPU NV12 输入 |

设计意图：路径由"采集器是否共享了硬件上下文"自动决定——采集是 DXGI 就走硬件直通
（A/B），是 GDI 就走软路径（C）。**编码器不感知采集后端，只看有没有共享 hw 上下文。**

### 3.1 路径 A：NVENC/AMF 直接消费 D3D11 帧

```cpp
hw_ctx_ = AvBufferRefPtr(av_buffer_ref(shared_hw_ctx));   // 复用采集器的 D3D11VA 设备
ctx_->hw_device_ctx = av_buffer_ref(hw_ctx_.get());
// 优先复用采集器的帧池——ffmpeg 校验输入帧的 hw_frames_ctx 与编码器的是同一 data
if (shared_frames_ctx) {
  hw_frames_ref_ = AvBufferRefPtr(av_buffer_ref(shared_frames_ctx));
} else {
  hw_frames_ref_ = AvBufferRefPtr(av_hwframe_ctx_alloc(hw_ctx_.get()));
  AVHWFramesContext* fc = ...;
  fc->format = AV_PIX_FMT_D3D11;
  fc->sw_format = AV_PIX_FMT_BGRA;   // 与抓屏帧同格式，免 GPU 格式转换
  fc->width = opts.width; fc->height = opts.height;
  av_hwframe_ctx_init(hw_frames_ref_.get());
}
ctx_->hw_frames_ctx = av_buffer_ref(hw_frames_ref_.get());
```

> 关键：**swscale 不支持 D3D11 hw 帧作为输入**，所以硬件直通绝不能走 sws 转格式，
> 必须靠编码器原生消费 BGRA，或走下面的 GPU VideoProcessor。
> 设计意图：零拷贝不是"少一次 memcpy"这么简单，而是**避免 CPU/GPU 之间任何往返**——
> 从采集帧池到编码器输入，全在 GPU 上。

### 3.2 路径 B：QSV 硬件直通（最精巧的部分）

QSV 编码器只吃 NV12 表面，且**只认自家帧池里的表面**（绝不能用 `av_hwframe_map` 映射
外部纹理，会 `MFX_ERR_UNSUPPORTED=-3`）。方案：

1. **从采集器共享的 D3D11VA 设备派生 QSV 设备**（底层复用同一 D3D11 device、同一 GPU
   显存，无跨设备拷贝）：
   ```cpp
   AVDictionary* qsv_opts = nullptr;
   av_dict_set(&qsv_opts, "child_device_type", "d3d11va", 0);
   av_hwdevice_ctx_create_derived_opts(&qsv_dev, AV_HWDEVICE_TYPE_QSV,
                                       shared_hw_ctx, qsv_opts, 0);
   ```
   设计意图：`create_derived_opts` 让 QSV 设备**长在采集器的 D3D11 设备之上**，
   等于"同一个 GPU、同一块显存"，没有跨设备拷贝。
2. **建立 NV12 QSV 帧池**（`format=AV_PIX_FMT_QSV`，`sw_format=NV12`）。一个实测坑：
   `initial_pool_size` 设 >0 在 Intel 核显上会触发 `0x80070057(E_INVALIDARG)`，必须用 `0`
   （动态池，av_buffer_pool 按需扩容）。
3. **用 D3D11 VideoProcessor 在 GPU 内把抓屏纹理渲染进 QSV 池表面**：
   ```cpp
   // encode() 中：先取一帧 QSV 池表面
   av_hwframe_get_buffer(hw_frames_ref_.get(), qsv_frame.get(), 0);
   // 再用 VideoProcessor 把 BGRA 抓屏帧渲染进去（BGRA→NV12 转换 / NV12→NV12 纯拷贝）
   qsv_conv_->convertInto(d3d11_bgra, qsv_frame.get());
   ```
   `QsvGpuConverter` 用 `ID3D11VideoDevice/Context` 创建 `VideoProcessor`，
   `VideoProcessorBlt` 把 src 纹理渲染进 dst（QSV 池 surface 的 d3d11 子纹理），全程 GPU。
   并显式设 `VideoProcessorSetStreamColorSpace`：`Nominal_Range=0`(有限范围)、
   `YCbCr_Matrix=0`(BT.601)。
   设计意图：**格式转换也用 GPU 做**（VideoProcessor 是硬件颜色转换器），
   BGRA→NV12 不落 CPU；同时显式指定色彩空间，避免默认值导致偏色/黑位错误。

### 3.3 路径 C：GDI 软路径（CPU NV12）

- NVENC/AMF：直接送 CPU NV12 帧，**不需要** `hw_device_ctx/hw_frames_ctx`
  （ffmpeg 编码器内部自动上传 GPU）。
- QSV 软路径例外：**必须有** `hw_device_ctx`(MFX 会话) + `hw_frames_ctx`，否则 open2 虽成功
  但编码空转无输出（Intel 核显实测 `pushed` 恒为 0）。用 `av_hwdevice_ctx_create(QSV, d3d11va)`
  建独立 QSV 设备，然后 `av_hwframe_transfer_data` 把 CPU NV12 上传到 QSV 表面。
  设计意图：QSV 对"软输入"也要 MFX 会话 + 帧池，缺一个就静默无输出——
  **这是硬件编码器里最容易"看起来成功实则白跑"的坑，必须专门记住**。

## 3.4 零拷贝的真义：与"显示器绑定 GPU"的硬前提

Intel Media SDK 语境下，**零拷贝 = 避免 D3D 表面 ↔ 系统内存的往返**；在**显存内**做一次
格式转换（由 GPU 完成）**仍算零拷贝**——它不是"免拷贝"，而是"用 GPU 拷贝代替 CPU 拷贝
（sws_scale）"。所以 QSV 的正确做法不是"像 NVENC/AMF 那样免转换直通"，而是"必须做一次
GPU 内 NV12 转换再喂给编码器，但全程零 CPU、零跨设备"。

**D3D11 零拷贝直通只在"与显示器绑定的那块 GPU"上成立**，且与编码器厂商无关：

- 桌面纹理由**主显卡（接显示器的那块）**产生；
- NVENC/AMF 要绑定到**它自己的 D3D11 设备**做零拷贝；
- 若桌面纹理来自核显、编码器在独显 → 采集纹理与编码器**跨 GPU**，NVENC 直接报
  `OpenEncodeSessionEx failed: no encode device (1)`，无法打开编码会话；
- 即便强行走通也只能**跨 GPU 拷贝**（核显纹理→显存→NVIDIA 编码），退化为 CPU 软路径，
  回到 ~27ms 级别，测不到零拷贝收益。

真机三机对照（同一工程实测）：

| 机器 | 主显卡（接显示器） | 编码器 | 零拷贝 | 采集实测 |
|---|---|---|---|---|
| AMD 核显机 | AMD 核显 | AMF | ✅ | capture ≈ 1.6~2.0ms（D3D11 直通，降 93%） |
| Intel QSV 机（DPI 开） | Intel 核显 | QSV | ❌（CPU 软路径） | capture ≈ 27ms（拷贝 + sws） |
| 混合显卡笔记本 | AMD 核显 | NVENC | ❌（编码器打不开） | 启动即失败 |

> 结论：要测 NVENC/AMF 零拷贝收益，需**显示器直接接在该编码器所在 GPU** 上
> （台式机独显输出 / 笔记本外接屏并设独显为主输出）。

> **三家验证状态（如实标注，避免把外推当实测）**：
> - **AMD AMF：完整验证**——在"零拷贝硬前提满足"（显示器直连 AMD 核显）的环境下跑通，
>   有实测数据（capture 1.6~2.0ms）。**这是唯一完整验证过的零拷贝路径**。
> - **Intel QSV：已实测，但受条件限制**——在核显 + 该驱动组合下 GPU 直通失败，走 CPU
>   NV12 软路径（见 3.6、3.5）；不是"没测"，是条件不满足。
> - **NVIDIA NVENC：受条件限制，未能在零拷贝前提满足下验证**——缺一台"显示器直接接
>   NVIDIA 独显"的主机，故 NVENC 的 D3D11 直通零拷贝尚未在本工程实测；当前唯一相关实测是
>   混合显卡笔记本（显示器接核显、编码器在独显）**跨 GPU 打不开编码会话**。因此文中关于
>   "NVENC 原生消费 D3D11、可零拷贝"的表述**基于厂商能力 + AMD 类比推断，非本工程实测**，
>   若照抄需先在你自己的 NVIDIA 独显直连主机上验证。


## 3.5 为什么 QSV 绝不能用 av_hwframe_map

QSV 编码器只认**自己帧池里分配的表面**。ffmpeg 的 `qsv_map_to` 只在自己池
`hwctx->surfaces[]` 里按 `data[0]` 纹理指针逐个匹配；抓屏/独立中转纹理不在池里 →
匹配不到 → **`MFX_ERR_UNSUPPORTED`（=-3）**。NVENC/AMF 能消费任意外部纹理，QSV 不行。

两个最小复现实测：
- `av_hwframe_map(D3D11 NV12 → QSV surface)`：返回 0、`data[3]` 有 MemId，但 send 5 帧
  receive 0 帧——编码器不认 map 出来的外部表面，encode() 恒 EAGAIN（pushed=0、viewer
  收不到视频帧）；
- `av_hwframe_transfer_data(D3D11 hw 源 → QSV)`：返回 **-22（EINVAL）**，不支持该方向。

**对策**：不再 map/transfer 外部纹理，而是用 **D3D11 VideoProcessor 把抓屏纹理直接
`VideoProcessorBlt` 渲染进「QSV 帧池自己的 d3d11 子纹理」**（`av_hwframe_get_buffer(QSV池)`
取得的表面，其 `data[0]` 即该纹理），随后直接送编码。该表面本就是 QSV 自家池成员，
绕开池内匹配问题——这正是 3.2 路径 B 的设计根因。

## 3.6 真机结论与回退决策（Intel 核显实测）

- **两个根因已修复**：① QSV `derive` 返回 -16 = 采集器 D3D11 设备缺多线程保护
  （oneVPL 要求 `SetMultithreadProtected(TRUE)` 才能绑定，否则 `MFX_ERR_INVALID_HANDLE`）；
  ② QSV NV12 帧池 `initial_pool_size>0` 在 Intel 核显触发 `0x80070057`，必须用 `0`（动态池）。
- **本机 QSV 最终只接受 CPU NV12 输入**：GPU 直通（map/render）在该组合
  （FFmpeg 8.x + Intel 核显 + 该驱动）上只能出首帧 IDR、P 帧不消费/卡死，属**硬限制**。
- **保底决策**：QSV 走 CPU NV12 软路径（稳定出帧，非零拷贝）；真正跑通的零拷贝硬编路径
  是 **AMF（D3D11 直通）**——已在 AMD 核显机实测 capture 1.6~2.0ms、enc+push 2.1~2.3ms、
  dropped 0%。

> 教训：**"零拷贝"是有硬前提的（同 GPU、同设备、自家帧池）**，不是换个编码器名就成立。

> **补充实测（Intel N150 入门级主机）**：在 Intel N150（Alder Lake-N 平台，Gracemont 4 核 +
> Intel UHD 核显，Xe-LP 24 EU）主机上，抓屏 → QSV 编码同样**无法建立 GPU 直通零拷贝**，
> 与前述核显机结论一致，最终走 CPU NV12 软路径（capture 含拷贝 + sws）。
>
> **原因归类**：按现有证据**倾向"平台/机器组合限制"而非单一因素**，但**根因尚未最终定位**，
> 这里如实标注，不做武断结论。可能叠加的诱因包括：
> 1. 入门级核显（Alder Lake-N）与显示绑定的 D3D11 设备在 oneVPL/QSV 驱动下的 enablement
>    覆盖不全，未必满足 3.4 的"同 GPU、同设备"零拷贝前提；
> 2. 桌面纹理来源（合成器/DPI 路径）与该 GPU 的绑定关系，未进入编码器可消费的帧池；
> 3. FFmpeg 版本 + Intel 驱动 + oneVPL 的组合问题——QSV 只认自家帧池，map/render 常表现为
>    "只出首帧 IDR、P 帧不消费/卡死"（见 3.5），N150 上同样复现。
>
> 若要进一步定位，建议从"该核显上 `qsv_map` / `VideoProcessorBlt` 的结果是否真正进入编码器
> 消费"逐段抓取 trace 入手，而不是直接归因硬件。

## 4. 按后端设置编码参数

```cpp
if (encoder_name_ == "hevc_nvenc") {
  av_opt_set(ctx_->priv_data, "preset", "p1", 0);       // 最低延迟档
  av_opt_set(ctx_->priv_data, "tune", "ull", 0);
  av_opt_set(ctx_->priv_data, "zerolatency", "1", 0);
  av_opt_set(ctx_->priv_data, "repeat_headers", "1", 0);// 每 IDR 重复 SPS/PPS（in-band）
  ctx_->max_b_frames = 0;
  // cbr ? "rc=cbr" : "rc=vbr + cq=23"（静态自动降码率省资源）
} else if (encoder_name_ == "hevc_qsv") {
  av_opt_set(ctx_->priv_data, "preset", "medium", 0);
  ctx_->global_quality = 20;                            // ICQ 智能恒定质量
  av_opt_set(ctx_->priv_data, "forced_idr", "1", 0);    // 手动 I 帧输出真 IDR
  ctx_->max_b_frames = 0;
} else if (encoder_name_ == "hevc_amf") {
  av_opt_set(ctx_->priv_data, "usage", "lowlatency", 0);
  av_opt_set(ctx_->priv_data, "quality", "speed", 0);
  av_opt_set(ctx_->priv_data, "lookahead", "0", 0);     // 显式关 lookahead
  av_opt_set(ctx_->priv_data, "frame_skipping", "0", 0);
  av_opt_set(ctx_->priv_data, "forced_idr", "1", 0);
  av_opt_set(ctx_->priv_data, "header_insertion_mode", "2", 0); // 每帧插参数集
  ctx_->max_b_frames = 0;
}
```

> AMF 的 `header_insertion_mode=2`（每帧插 SPS/PPS）是关键坑的解药：WiFi 乱序下参数集包
> 与 IDR 分片乱序到达，接收端 cuvid 报 "PPS id out of range" 解不出帧。每帧插参数集使
> 任何时刻可解，带宽开销 ~100B/帧 @25fps ≈ 2.5KB/s，可忽略。
> 设计意图：**接收端何时都能入解** 比省那 2.5KB/s 重要得多——这就是"健壮性优先于带宽"。

## 5. 编码一帧 encode()：强制 IDR 与 EAGAIN/EINVAL

```cpp
int HevcEncoder::encode(AVFrame* d3d11_bgra, AVPacket* out_packet) {
  d3d11_bgra->pict_type = AV_PICTURE_TYPE_NONE;
  if (keyframe_requested_) { d3d11_bgra->pict_type = AV_PICTURE_TYPE_I; keyframe_requested_ = false; }
  // ... QSV 路径：先取 QSV surface 再送
  int sret = avcodec_send_frame(ctx_.get(), frame_to_send);
  if (sret == AVERROR(EINVAL)) {
    // AMF 同步编码：上一帧仍在编码中时 send 返回 EINVAL 而非 EAGAIN。
    // Drain 已完成帧并等待 50ms 后重试同一帧（上限 20 次）。重试期间若编码器
    // 输出了帧（含强制 IDR），必须 av_packet_move_ref 交付——此前直接 unref 丢弃，
    // 导致静止重推场景视频帧永远推不出去、viewer 等不到 IDR 黑屏。
    for (int tries = 0; tries < 20 && sret == AVERROR(EINVAL); ++tries) {
      AVPacket tmp{};  // 必须零初始化
      int rret = avcodec_receive_packet(ctx_.get(), &tmp);
      if (rret == 0) { av_packet_move_ref(out_packet, &tmp); return 1; }
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      sret = avcodec_send_frame(ctx_.get(), frame_to_send);
    }
  }
  if (sret < 0 && sret != AVERROR(EAGAIN)) return -1;
  int ret = avcodec_receive_packet(ctx_.get(), out_packet);
  if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) { av_packet_unref(out_packet); return 0; }
  return 1;
}
```

要点：

- **外部强制关键帧**：置 `pict_type=AV_PICTURE_TYPE_I` 触发编码器输出 IDR。
  设计意图：丢包/首连/静止恢复都需要"立刻来一帧可解码的关键帧"，这是全系统唯一的
  高效恢复手段（配合第 6 篇的 PLI）。
- **EAGAIN ≠ 失败**：表示编码器内部缓冲未就绪（AMF/NVENC 首帧入队后需继续喂帧才输出），
  视为入队成功继续。设计意图：**把 EAGAIN 当错误 = 把正常缓冲当故障**，实时流会丢帧抖动。
- **EINVAL 重试**：AMF（尤其核显驱动）同步编码，上一帧仍在编码中时 send 返回 EINVAL，
  需要 drain + 重试，且**重试期间产出必须交付**。设计意图：这个坑的教训是"编码器在
  重试中吐出的帧（含强制 IDR）也是有效输出"，曾因直接 unref 丢弃导致 viewer 一直
  等不到 IDR 而黑屏。

## 6. 一句话总结

**编码器 = 显卡决定、按厂商映射绑定（软件不"选"）；喂帧 = 三路输入（硬件直通 / QSV 派生 /
软路径）按共享 hw 上下文自动分流；编码 = 强制 IDR + 把 EAGAIN 当正常、把 EINVAL 当需要
drain**。所有设计都指向同一个目标：**帧从采集到编码只待在 GPU 上，且异步语义被正确消费。**

---

