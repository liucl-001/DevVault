---
title: "FFmpeg 基础：对象模型与数据流"
date: 2026-10-16T10:00:00+08:00
draft: false
tags: ["FFmpeg", "HEVC", "桌面串流", "Windows"]
series: ["低延迟桌面串流全栈实战"]
weight: 2
summary: "用最少篇幅建立 对象 + send/receive + hw上下文 心智模型"
---

# 02 · FFmpeg 基础：对象模型、数据流与硬件加速机制

> 为后面的采集、编码、解码、显示打地基。
> 术语约定：AVFrame/AVPacket、hw 上下文等术语见本系列《导读与术语表》。

---

## 设计意图

后面五篇全是 FFmpeg API 的拼装，看不懂这套对象模型，代码就是一堆陌生函数名。
这篇用最少篇幅建立三个心智模型：

1. **对象模型**：六个核心对象各管什么、谁归谁所有。
2. **数据流**：帧/包怎么在 send/receive 两对调用里流转。
3. **硬件加速**：`hw_device_ctx` / `hw_frames_ctx` 各管什么——这是理解硬件编解码的钥匙。

---

## 1. 六大核心对象

| 对象 | 头文件 | 含义 | 生命周期管理 |
|---|---|---|---|
| `AVFormatContext` | `libavformat/avformat.h` | **容器/格式**：封装一个流（文件或网络），管理若干 AVStream | `avformat_alloc_context` / `avformat_free_context` |
| `AVStream` | 同上 | 一条流（一路视频/音频），携带 codecpar（编码参数） | 归 FormatContext 所有 |
| `AVCodecContext` | `libavcodec/avcodec.h` | **编解码上下文**：真正干活的"引擎"，含 width/height/pix_fmt/hw_device_ctx 等 | `avcodec_alloc_context3` / `avcodec_free_context` |
| `AVCodec` | 同上 | 编解码器描述（哪个厂商、哪个格式） | 全局静态，`avcodec_find_*` 取 |
| `AVFrame` | `libavutil/frame.h` | **解码后/待编码的原始图像**：多平面 YUV/RGB，可带 GPU 硬件帧引用 | `av_frame_alloc` / `av_frame_free` / `av_frame_unref` |
| `AVPacket` | `libavcodec/packet.h` | **已编码的压缩数据**（编码输出、解码输入） | `av_packet_alloc` / `av_packet_unref` |

核心关系：

```
AVFormatContext  (1)──(n)── AVStream ──codecpar──► AVCodecParameters
                                              │
                              匹配查找 ──► AVCodec ──创建──► AVCodecContext ──► 编解码
                                              │                      │
                                     AVHWDeviceType ──创建──► AVHWDeviceContext ──► (AVCodecContext.hw_device_ctx)
```

容易混的三个点（设计意图在此）：

- **AVCodec 是"说明书"，AVCodecContext 是"实例"**：一个解码器描述被 `avcodec_open2`
  后变成可用的引擎；所以可复现的工程一定会用 RAII 包住 context，绝不让它裸泄漏。
- **AVStream 归 FormatContext 所有**：不要手动 free 单个 stream，`avformat_free_context`
  一并回收。
- **AVFrame 引用计数**：`av_frame_unref` 只减引用，多线程共享帧时靠引用计数避免
  "A 线程还在读、B 线程已释放"。

## 2. 数据流模型

```
                编码方向（采集 → 推流）
原始像素(AVFrame) ──avcodec_send_frame──► [编码器] ──avcodec_receive_packet──► 压缩包(AVPacket)
                                                                                │
                                                              av_write_frame(AVFormatContext) ──► 网络/文件

                解码方向（收流 → 上屏）
av_read_frame(AVFormatContext) ──► AVPacket ──avcodec_send_packet──► [解码器]
                                          ──avcodec_receive_frame──► AVFrame(NV12) ──sws_scale──► RGB24 → SDL 上屏
```

两条铁律（写实时链路必踩）：

- **send/receive 是异步对**：`avcodec_send_frame` 返回 `EAGAIN` 表示编码器缓冲未就绪
  （需继续喂帧才输出），返回 `0` 表示入队成功；`avcodec_receive_packet` 返回 `EAGAIN`
  表示暂时无输出。**把 EAGAIN 当失败处理 = 丢帧/卡死**，详见第 5 篇。
- **PTS/DTS**：`AVPacket.pts`（显示时间戳）、`dts`（解码时间戳）。有 B 帧时两者不同
  （要先解后才能显示，需重排）。本项目无 B 帧，DTS=PTS 单调，所以 `av_write_frame`
  直接写无需重排——**设计意图：关掉 B 帧换来"写包不用排队"**。

## 3. 硬件加速对象模型（理解第 5、8 篇的关键）

```
AVHWDeviceType        // 硬件类型枚举：AV_HWDEVICE_TYPE_D3D11VA / QSV / CUDA / ...
        │
av_hwdevice_ctx_alloc / av_hwdevice_ctx_create
        ▼
AVHWDeviceContext     // 硬件设备上下文（一个 GPU 设备，如 D3D11 device）
        │
av_hwframe_ctx_alloc
        ▼
AVHWFramesContext     // 硬件帧池：format(如 AV_PIX_FMT_D3D11) + sw_format(内部软件格式 BGRA/NV12) + 尺寸 + 池大小
        │
av_hwframe_get_buffer / av_hwframe_transfer_data / av_hwframe_map
        ▼
AVFrame.data[0]       // 硬件路径下是 GPU 纹理指针（如 ID3D11Texture2D*），不是 CPU 数据
```

三个必须分清的概念：

1. **hw_device_ctx**（挂在 `AVCodecContext.hw_device_ctx`）：告诉编码/解码器用哪个 GPU 设备。
2. **hw_frames_ctx**（挂在 `AVCodecContext.hw_frames_ctx` 或 `AVFrame.hw_frames_ctx`）：
   定义帧的硬件格式（容器 format + 内部 sw_format）。**编码校验要求输入帧的 hw_frames_ctx
   与编码器的是同一个 `data`**——所以本项目让编码器直接复用采集器的帧池（零拷贝的关键）。
3. **硬件帧的 data[0]**：D3D11 路径下是 `ID3D11Texture2D*`，不是 CPU 指针；要读像素必须
   `av_hwframe_transfer_data` 下载到 CPU，或在 GPU 内用 VideoProcessor 转换。

`av_pix_fmt_desc_get(frame->format)` 的 `AV_PIX_FMT_FLAG_HWACCEL` 标志可判断帧是否硬件帧。

> 设计意图：把"硬件"抽象成**两级**（设备级 + 帧池级），好处是——同一个设备可以被
> 采集器、编码器、解码器共享（第 3、5 篇），帧池可以被多个消费者复用（零拷贝），
> 而每一级都各自有 RAII 管理。

## 4. 资源 RAII

ffmpeg 所有对象统一用 `std::unique_ptr<T, 自定义 deleter>` 管理，替代手写 `av_*_free`。
关键设计：**用一个通用 deleter 模板 + 宏覆盖全部对象**，而不是每个对象手写一个释放结构体。

ffmpeg 的释放函数有两种签名：
- `void f(T**)`：`av_packet_free` / `av_frame_free` / `avcodec_free_context` /
  `avcodec_parameters_free` / `avformat_close_input` / `av_buffer_unref`；
- `void f(T*)`：`avformat_free_context` / `sws_freeContext`。

用一个模板 + 编译期特征区分两者（C++17 `auto` 非类型模板参数绑定释放函数，
`if constexpr` 按"参数是否为指针的指针"选择调用方式；deleter 无状态、零开销，
`unique_ptr` 空基类优化）：

```cpp
template <typename T, auto FreeFn>
struct AvDeleter {
  template <typename F> struct FnArgType;
  template <typename R, typename A> struct FnArgType<R (*)(A)> { using Type = A; };
  using Arg = typename FnArgType<decltype(FreeFn)>::Type;

  void operator()(T* p) const {
    if constexpr (std::is_pointer_v<std::remove_pointer_t<Arg>>) {
      FreeFn(&p);      // T**：如 av_frame_free，传 &p（顺带置空指针）
    } else {
      FreeFn(p);       // T* ：如 avformat_free_context，直接传 p
    }
  }
};

// 把 unique_ptr 类型包装成具名嵌套别名，让编译错误/调试符号显示可读名
template <typename T, auto FreeFn>
struct AvDeleterDecl { using AvPtr = std::unique_ptr<T, AvDeleter<T, FreeFn>>; };

#define AVDeleter(t, f) AvDeleterDecl<t, f>::AvPtr
```

然后一行声明一个对象类型：

```cpp
using AvPacketPtr         = AVDeleter(AVPacket, av_packet_free);
using AvFramePtr          = AVDeleter(AVFrame, av_frame_free);
using AvCodecContextPtr   = AVDeleter(AVCodecContext, avcodec_free_context);
using AvCodecParametersPtr = AVDeleter(AVCodecParameters, avcodec_parameters_free);
using AvFormatContextPtr  = AVDeleter(AVFormatContext, avformat_close_input);   // demuxer
using AvMuxContextPtr     = AVDeleter(AVFormatContext, avformat_free_context);  // muxer
using AvBufferRefPtr      = AVDeleter(AVBufferRef, av_buffer_unref);
using SwsContextPtr       = AVDeleter(SwsContext, sws_freeContext);

inline AvPacketPtr makeAvPacket() { return AvPacketPtr(av_packet_alloc()); }
inline AvFramePtr  makeAvFrame()  { return AvFramePtr(av_frame_alloc()); }
```

> 两个注意点：① 释放函数 `T**` 与 `T*` 的区别由模板里 `if constexpr` 自动处理，使用者
> 不用关心，但新增对象只加一行 `using` 即可；② 两种"格式上下文"别混——**demuxer**
> （`avformat_open_input` 打开）用 `AvFormatContextPtr`（`avformat_close_input`），**muxer**
> （`avformat_alloc_context` + 写头）用 `AvMuxContextPtr`（`avformat_free_context`）。

设计意图：ffmpeg 手动管理极容易在异常路径上漏 unref（编码器异步持有帧时尤其致命）。
统一 RAII 后，**无论正常返回还是中途 return，资源都必然释放**，这是"长时间跑的守护进程
不泄漏"的保障。用"模板 + 宏"而非逐对象手写释放结构体，是为了新增对象零成本、deleter
无状态零开销。

## 5. 一句话总结

**FFmpeg = 一堆对象 + send/receive 异步编解码 + hw_device/hw_frames 两套硬件上下文**。
搞清 `AVFrame`/`AVPacket` 的流转，以及 `hw_device_ctx`/`hw_frames_ctx` 各管什么，
后面五篇的代码就都能看懂了。

---

