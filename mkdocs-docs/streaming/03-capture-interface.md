---
title: "屏幕采集：接口与两种后端"
date: 2026-10-16T10:30:00+08:00
draft: false
tags: ["FFmpeg", "桌面串流", "DXGI", "GDI", "屏幕采集", "Windows"]
series: ["低延迟桌面串流全栈实战"]
weight: 3
summary: "用统一接口封装两种抓屏后端，向上层屏蔽差异"
---

# 03 · 屏幕采集：接口与两种后端

> 讲清楚"怎么把屏幕变成 FFmpeg 能编码的帧"，以及两种后端各自的能力与坑。
> 涉及模块：**屏幕采集层**（接口 `IScreenCapturer`，后端 DXGI / GDI 两个实现）
> 术语约定：DXGI/GDI、D3D11、NV12 等见本系列《导读与术语表》。

---

## 设计意图

采集是整条链的**第一环**，也是差异最大的一环：Windows 上抓屏有两条主流路（DXGI 合成器
复制、GDI 位图拷贝），能力、延迟、适用场景天差地别。这一篇要立住
三个设计点：

1. **用统一接口 `IScreenCapturer` 把两种后端包装成同一个东西**——上层（编码、状态机）
   永远只对着一个接口说话，不关心底下是谁在抓。
2. **接口天生为"延迟优先 + 降级"设计**：返回状态里就带"这帧怎么了"，把"该不该切换"的
   判断权留给上层（降级链），后端只负责老实回答。
3. **后端优先打通"GPU 零拷贝直通"**：DXGI 直接把 D3D11 纹理交给编码器，CPU 零往返。

---

## 1. 采集抽象：IScreenCapturer

核心设计：**后端只回答"这一帧怎么了"，不做降级决策**。接口返回四种状态：

```cpp
enum class CaptureStatus {
  kFrame,    // 成功出一帧
  kNoFrame,  // 正常空转（桌面没变化，对应 WouldBlock 语义）
  kLost,     // 链路失效（ACCESS_LOST/设备丢失/切会话）→ 可重建自愈
  kFailed,   // 后端不可用 → 应降级到下一个后端
};
```

接口方法（要点）：

- `bool init(const CaptureOptions& opts)` —— 统一参数（显示器名、DPI 缩放、等待超时）。
- `CaptureStatus captureFrame(AVFrame* out, const FrameCallback& cb)` —— 非阻塞轮询模型。
- `bool reinit()` —— 重建链路（分辨率变化、设备丢失、锁屏恢复）。
- `const AVFrame* lastFrame()` —— **持久引用最近一帧**，供静止桌面重推。
- `bool isHwDirect()` / `AVBufferRef* hwCtx()` / `AVBufferRef* framesCtx()` —— 标识 GPU
  零拷贝路径并共享 D3D11 硬件设备/帧池给编码器（这是"零拷贝"的关键接口）。
- `cursorInfo(x, y, visible)` —— 光标状态（输出分辨率坐标）。
- `setSecureDesktopCapture(bool)` —— 是否采集安全桌面（锁屏/登录界面）。

> **设计意图 · 为什么要 WouldBlock 模式**：
> ① 静态桌面占用户时间的大头，若没有"没变化"这一档，采集会为毫无意义的重复帧持续
> 占用 CPU/GPU；
> ② 新增采集方式只需实现接口 + 在 `win_backends.cpp` 注册一行，上层永远无感
> （降级链本身也是一个 `IScreenCapturer`，见第 4 篇）。

## 2. 两种后端的能力边界（先看结论）

| 后端 | 锁屏 | 延迟 | 路径 | 参与 auto 链 |
|---|---|---|---|---|
| DXGI Desktop Duplication | ❌ | < 5ms | D3D11 纹理 → NVENC/QSV/AMF 零拷贝 | ✅ 首选 |
| GDI BitBlt | ✅ | 10-30ms | CPU BGRA →（可选 sws）→ 编码器 | ✅ 降级 |
设计意图小结：**DXGI 快但锁屏就断；GDI 正是为锁屏采集而生**——安全桌面（锁屏/登录界面）
只有 GDI 能采，虽慢但锁屏能扛。所以主路径 + 锁屏专用两条腿。

## 3. 后端一：DXGI Desktop Duplication（主路径）

目标：**D3D11 纹理直接喂编码器，全程 GPU，零 CPU 往返**。

### 3.1 初始化四步

1. **创建 D3D11 设备**（`BGRA_SUPPORT | VIDEO_SUPPORT` 旗标，失败回退 WARP 软渲染），
   并启用多线程保护（QSV/oneVPL 复用设备必需）：
   ```cpp
   ComPtr<ID3D10Multithread> mt;
   if (SUCCEEDED(device_->QueryInterface(IID_PPV_ARGS(&mt)))) mt->SetMultithreadProtected(TRUE);
   ```
   设计意图：这个设备要被**采集器 + 编码器（+ 派生 QSV 设备）共享**，所以必须开多线程
   保护，否则 GPU 资源跨线程访问会偶发崩溃。
2. **组装 FFmpeg D3D11VA 硬件设备上下文**（要共享给编码器）：
   ```cpp
   hw_ctx_.reset(av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA));
   AVHWDeviceContext* hwdev = (AVHWDeviceContext*)hw_ctx_->data;
   AVD3D11VADeviceContext* d3d = (AVD3D11VADeviceContext*)hwdev->hwctx;
   d3d->device = device_;           // 必填：ffmpeg 释放时统一 Release
   d3d->device_context = ctx_;
   d3d->BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
   av_hwdevice_ctx_init(hw_ctx_.get());
   ```
3. **选择要复制的 DXGI 输出**：按 `CaptureOptions::display_name` 匹配显示器设备名，
   遍历所有 adapter 的 output，找不到则退回第一个可用 output。
   设计意图：支持多显示器——指定哪台就抓哪台，这是"被控机多屏远程切换"的基础。
4. **创建输出复制 + 硬件帧池**：
   - 先试 `IDXGIOutput5::DuplicateOutput1` 请求 **NV12**（桌面合成器直接输出 NV12，
     QSV 编码器原生消费、免转换，"源头零拷贝"最简路径）；不支持则回退 `DuplicateOutput`（BGRA）。
   - 硬件帧池与抓屏帧同格式：
   ```cpp
   frames_ctx_.reset(av_hwframe_ctx_alloc(hw_ctx_.get()));
   AVHWFramesContext* fc = (AVHWFramesContext*)frames_ctx_->data;
   fc->format = AV_PIX_FMT_D3D11;
   fc->sw_format = dup_nv12_ ? AV_PIX_FMT_NV12 : AV_PIX_FMT_BGRA;
   fc->width = width_; fc->height = height_;
   fc->initial_pool_size = 8;   // 采集器与编码器共享此池，池太小会导致异步编码持有帧被覆盖
   av_hwframe_ctx_init(frames_ctx_.get());
   ```
   设计意图：**帧池是共享的**——采集器从池里拿一帧拷贝屏幕，编码器再从同一个池拿同一帧
   编码，二者共用一块显存，没有第二次拷贝。`initial_pool_size=8` 给异步编码留余量，
   池太小会出现"编码还没读完，帧已被覆盖"。

### 3.2 每帧采集 captureFrame()

```cpp
dup_->AcquireNextFrame(wait_ms, &info, &res);   // wait_ms=8ms，静止立刻返回
if (hr == DXGI_ERROR_WAIT_TIMEOUT) return kNoFrame;   // 桌面没变化，正常空转
if (hr == DXGI_ERROR_ACCESS_LOST || DXGI_ERROR_DEVICE_REMOVED) {
  if (!recreateDuplication()) return kLost;      // 就地重建输出复制，重试一次
}
// 从帧池分配合法 D3D11 帧（必须带 hw_frames_ctx，裸指针帧编码器不接受）
f->hw_frames_ctx = av_buffer_ref(frames_ctx_.get());
av_hwframe_get_buffer(frames_ctx_.get(), f.get(), 0);
// GPU→GPU 拷贝到池帧纹理（零拷贝直通编码器）
ctx_->CopySubresourceRegion((ID3D11Texture2D*)f->data[0], 0,0,0,0, tex.Get(), 0, &box);
dup_->ReleaseFrame();
f->pts = frame_counter_++;
```

- **DPI 缩放模式**：硬件路径下池帧先 `hwdownload` 到 CPU，再 sws 缩放到逻辑分辨率 NV12。
  一个坑——**不能用 `av_hwframe_transfer_data` 直接下载**，其内部 staging 的 Copy 与 Map
  之间没有 Flush，会读到旧内容（全黑帧）。代码里显式 `Copy → ctx_->Flush() → Map`。
  设计意图：**拷贝完必须 Flush 再 Map**，这是 D3D11 命令队列异步语义的直接后果。
- **光标**：统一用 `GetCursorInfo`（位置+可见性一次获取），因为光标单独移动不触发桌面帧，
  每轮轮询保证光标跟手；且相对 `PointerPosition.Visible` 不会在移动瞬间跳变。

## 3.5 锁屏状态检测（WTS API，降级的前提）

采集端必须**主动知道"现在锁没锁屏"**，才能决定用哪个后端、要不要采集安全桌面。
用 Windows Terminal Services（WTS）API 检测会话锁定状态（需链接 `wtsapi32.lib`）：

```cpp
BOOL IsSessionLocked(DWORD sessionId) {
  PWTSINFOEXW pInfo = nullptr; DWORD bytes = 0;
  if (sessionId == 0xFFFFFFFF) return FALSE;
  if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, sessionId,
      WTSSessionInfoEx, (LPWSTR*)&pInfo, &bytes) && pInfo && pInfo->Level == 1)
    return pInfo->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK;
  return FALSE;
}
```

还有配套的**会话类型判断**（`WTSClientProtocolType` 判 RDP/ICA）与**活动会话/用户名获取**
（`WTSGetActiveConsoleSessionId`、`WTSEnumerateSessionsA`、`WTSUserName`）。通常封装成
一个 `SessionManager`（`IsLocked` / `GetCurrentSessionId` / `GetActiveUsername`）供采集链查询。

> 设计意图：**锁屏检测是"事件驱动降级"的前提**——只有先知道锁没锁，降级链才能
> "事件抢先切"而不是"等失败再降级"（见第 4 篇）。

## 3.6 两种后端的失败场景（选型依据）

| 后端 | 失败场景 |
|---|---|
| DXGI | 用户锁屏（Win+L）、RDP 会话断开、Ctrl+Alt+Del 桌面切换、显示器睡眠、无 D3D11 显卡 |
| GDI | 某些虚拟机环境、极低权限进程（需 SeDebugPrivilege）、完全禁用 DWM |

GDI 性能优化方向（参考）：部分区域更新（只捕获变化区）、降低捕获频率、先降分辨率再放大、
多线程并行处理多个显示器。

## 4. 后端二：GDI BitBlt（锁屏降级路径）

- `CreateDCW(display_name)` → `GetDeviceCaps(HORZRES, VERTRES)` 取桌面尺寸 →
  `CreateCompatibleDC` + `CreateCompatibleBitmap`。
- 每帧：`BitBlt(mem_dc_, ..., screen_dc_, SRCCOPY | CAPTUREBLT)`（`CAPTUREBLT` 捕获
  分层窗口/光标）→ `GetDIBits` 取 BGRA 到缓冲区。
- 输出：DPI 缩放时 `sws_scale(BGRA → NV12)`；非缩放时输出 BGRA CPU 帧（**独立分配 +
  逐行拷贝**，避免与成员缓冲生命周期耦合——硬件编码器可能异步持有输入帧）。
  设计意图：编码器可能异步持有输入帧，所以**绝不能复用成员缓冲**，否则下一帧会改掉
  编码器还在读的旧帧。
- **SEH 兜底**：`captureFrame` 外层 `__try/__except`，GDI 位图/DC 异常（如会话切换中访问
  失效句柄）不崩溃进程，降级为 `kFailed` 交给采集链。
  设计意图：守护进程最怕"一个瞬间异常就整进程崩"。GDI 句柄在会话切换时最容易失效，
  SEH 兜住 = 最多降级一帧，不炸进程。

### 安全桌面采集（锁屏/登录界面）

锁屏/登录界面的实际 UI 运行在**当前输入桌面**（锁屏壁纸阶段是 Default，密码界面变成
Winlogon 桌面）。进程需以 SYSTEM 运行在本会话、由特权 host 注入 winlogon 令牌，
然后把采集线程切到当前输入桌面再 BitBlt：

```cpp
HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS|...);
SetThreadDesktop(input);              // 跟随真正显示安全 UI 的桌面
screen_dc_ = CreateDCW(L"DISPLAY", ...);
```

设计意图：安全桌面（锁屏/登录）UI 不在普通桌面，要抓到它必须**切到当前输入桌面**再
GDI 抓——这正是"锁屏后仍能看到登录画面"的原因，也是本系列"锁屏降级"的价值所在。

## 5. 两种后端怎么选（设计决策）

- **默认 auto**：未锁屏 `[DXGI, GDI]`，锁屏 `[GDI]`——DXGI 主路径 + GDI 锁屏专用两条腿（第 4 篇详解）。
- **多显示器**：`--capture-backend dxgi --display <名>` 指定抓哪台。
- **DPI 缩放**：硬件直通 + `sws` 缩放到逻辑分辨率，保证远程看到的尺寸与本地一致。

---

