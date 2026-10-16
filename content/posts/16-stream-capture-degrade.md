---
title: "采集自动降级链"
date: 2026-10-16T11:00:00+08:00
draft: false
tags: ["FFmpeg", "桌面串流", "DXGI", "GDI", "屏幕采集", "Windows"]
series: ["低延迟桌面串流全栈实战"]
weight: 4
summary: "把 选后端/切换/自愈 从业务里剥离成一条自治链"
---

# 04 · 采集自动降级链：ScreenCapturerChain

> 讲清楚"锁屏自动切后端、解锁自动切回、失败自愈、无缝续流"这套机制。
> 涉及模块：**屏幕采集层的自动降级链**（`ScreenCapturerChain`）
> 术语约定：后端/降级/锁屏等见本系列《导读与术语表》。

---

## 设计意图

第 3 篇讲了两种后端各有能力边界（DXGI 最快但不支持锁屏，GDI 支持锁屏但慢）。
这一篇解决由此引出的**运维问题**：

1. **切换必须自动化**——用户锁屏/解锁时不该有任何人手工干预，系统要自己换后端。
2. **切换必须不断流**——锁屏瞬间若断流重建，体验是"画面卡死几秒"，不可接受。
3. **失败必须自愈**——分辨率变化、设备丢失、会话切换都会让当前后端失效，要么就地重建，
   要么降级，绝不能卡死或崩进程。
4. **对上层透明**——上层只面对一个 `IScreenCapturer`，后端怎么切是链内部的事。

一句话：**把"选后端/切换/自愈"从业务里剥离出来，做成一条自治的降级链。**

---

## 1. 为什么需要降级链

```
createScreenCapturer()
      │  按会话状态规划顺序：未锁屏 DXGI→GDI；锁屏 GDI
      ▼
ScreenCapturerChain ──captureFrame()──► [DXGI] ─失败/失效─┐
      ▲                                                   │
      └──────────── 降级、自愈、周期性重探 ◄───────────────┘
```

两种后端各有能力边界，如果每次锁屏都让上层重新选后端、重新初始化，锁屏瞬间会**断流**。
降级链把"选谁、什么时候切、切了要不要重建编码器"全部内聚到一层，上层永远无感。

## 2. 后端目录与顺序规划

`ScreenCapturerChain` 维护一张目录（顺序 = 默认优先级，延迟优先）：

```cpp
static const std::vector<CaptureBackendInfo> kCatalog = {
  {kDxgi, "DXGI", requires_gpu=true, works_when_locked=false, in_auto_chain=true,
   "Desktop Duplication：GPU 零拷贝，延迟最低；锁屏/切会话/UAC 时不可用"},
  {kGdi, "GDI", requires_gpu=false, works_when_locked=true, in_auto_chain=true,
   "BitBlt：为锁屏/登录界面（安全桌面）采集而生；CPU 拷贝，延迟 10-30ms"},
};
```

设计意图：目录里每个后端都**声明了两个能力位**——`requires_gpu` 和 `works_when_locked`。
这是让"顺序规划"能做静态裁剪的依据：锁屏时直接从目录里跳过 requires_gpu 的后端，
不必等到初始化失败才发现。

`planOrder()`：
- `--capture-backend auto`：遍历目录只取 `in_auto_chain=true`；**若已锁屏，直接跳过
  requires_gpu 的后端**（锁屏 DXGI 必然失败，省一次探测）→ 锁屏顺序 `[GDI]`，未锁屏 `[DXGI, GDI]`。
- 显式指定后端 + `auto_fallback`：该后端放第一位，再把 auto 链里其余追加在后面。

## 3. 暖备初始化：不是"第一个成功就停"

与直觉相反，`init()` **初始化全部规划顺序中的后端**，而不是只到第一个成功为止：
让较低优先级后端（GDI）成为"暖备常驻"，锁屏瞬间可直接切换，避免冷初始化阻塞断流。

```cpp
for (size_t i = 0; i < order_.size(); ++i) initBackend(i);  // 全初始化成暖备
active_ = first_usable;   // 取第一个可用后端
```

设计意图：**用一次冷启动的初始化成本，换所有后续切换的即时性**。锁屏事件一到，
GDI 早已就绪（暖备），`setSessionLocked` 只做一行"切 active 指针"，零等待。

## 4. 降级 / 自愈 / 重探：captureFrame()

一次调用内最多尝试"后端数量"次：

- **kFrame / kNoFrame**：直接返回；`kNoFrame` 时顺便 `maybeReprobeHigherTier()`（空闲帧才重探）。
  设计意图：**只在空闲帧重探高优先级后端**——高优先级后端（DXGI）恢复后要无感切回，
  但重探是有开销的，放进"反正这帧也没事"的空闲时隙，不影响吞吐。
- **kLost**：先 `reinit()` 就地自愈；但加了**重入风暴保护**——连续 4 次"reinit 成功又立刻丢"
  就停止自愈（典型是解锁瞬间 GDI BitBlt 拒绝访问），按会话状态升级/降级打断风暴。
  设计意图：自愈要防"抖"——如果 reinit 又立刻失败，说明当前后端在该状态下根本不可用，
  死循环自愈只会空转，应改走降级。
- **kFailed**：降级到下一个后端。
- **切换后不立即下发新后端的帧**：置 `backend_switched_` 标志，让上层先重建编码器
  （几何/像素格式可能已变），下一帧再出图。

```cpp
CaptureStatus ScreenCapturerChain::captureFrame(AVFrame* out, const FrameCallback& cb) {
  if (dxgi_pending_ && maybeInitPendingDxgi()) { /* 已切到 DXGI */ }
  for (size_t attempt = 0; attempt <= order_.size(); ++attempt) {
    const CaptureStatus status = active()->captureFrame(out, cb);
    if (status == kFrame || status == kNoFrame) return status;
    // kLost / kFailed → reinit 或 downgrade()
    ...
    if (!downgrade()) return kFailed;
    return kNoFrame;  // 等上层重建编码器后下一帧出图
  }
}
```

## 5. 锁屏事件驱动切换：setSessionLocked()

WTS 会话事件（`session_event_watcher`）驱动，**不等失败再降级**：

- **锁屏**：立即切到暖备 GDI，剔除 DXGI（锁屏不可能用 DXGI），并给活动后端设
  `setSecureDesktopCapture` 采集登录界面。若输出格式未变（DPI 开时 GDI/DXGI 同为
  NV12 同分辨率）则**无缝续流不关流**。
- **解锁**：保持当前后端继续出帧，置 `dxgi_pending=true`；采集循环里**机会性初始化 DXGI**，
  成功后无感切回（带指数退避：300ms 起步翻倍，上限 5s）。

```cpp
void ScreenCapturerChain::setSessionLocked(bool locked) {
  if (locked_ == locked) return;
  locked_ = locked;
  rebuildOrderPreservingWarm();   // 保留暖备后端，避免冷初始化
  if (locked) {
    active_ = findKindIndex(kGdi);      // 立即切 GDI
    ...
  } else {
    dxgi_pending_ = true;               // 机会性升级 DXGI
    ...
  }
}
```

`rebuildOrderPreservingWarm()` 的精髓：锁屏时把 DXGI 从顺序里剔除、GDI 顶上；
解锁时把 DXGI 放回顺序。**保留已初始化的后端（暖备复用），不整体清空再冷初始化**。

设计意图对比两种实现：

- **"等失败再降级"**：锁屏瞬间 DXGI 开始报 ACCESS_LOST → 才切 GDI，中间有断流窗口。
- **"事件驱动抢先切"**：WTS 锁屏事件一到就切 GDI，GDI 是暖备，秒切、无断流。
- 而**解锁走"机会性重探 + 指数退避"**：不打断当前流，DXGI 初始化好就无感切回，
  初始化失败就退避再试，不阻塞任何一帧。

## 6. 关键接口：consumeBackendSwitch()

后端切换会置位 `backend_switched_`。上层 `StreamApp` 调用 `consumeBackendSwitch()` 判断：

- **输出格式变化**（如 DXGI 硬件直通 vs GDI CPU）→ 关流回空闲、**重建编码器**；
- **输出格式没变**（DPI 开时同为 NV12 同分辨率）→ **无缝续流**，不关流不重建。

```cpp
bool ScreenCapturerChain::consumeBackendSwitch() {
  const bool changed = backend_switched_;
  backend_switched_ = false;
  return changed;
}
```

> 设计意图：这一层避免了一个隐性崩溃——降级后编码器还拿着旧帧池/旧分辨率，塞新尺寸帧
> 会出错。上层在切换后统一走"重建编码器"路径（第 10 篇），保证编码器与采集端格式永远
> 一致。`consume`（消费式读取）保证标志只被处理一次，不会因重复处理重建两次编码器。

### 6.1 降级链设计带来的收益（对应 WouldBlock 模式）

1. **解耦**：新增采集方式只需实现接口 + 在后端目录注册一行；
2. **首次尝试永远是最快的方式**（延迟优先，绝不从慢后端起手）；
3. **上层无感**：`ScreenCapturerChain` 本身就是一个 `IScreenCapturer`；
4. **可自愈**：`kLost` 先尝试重建同一后端，失败才降级；
5. **可回到快路径**：降级后周期性/空闲时重探更高优先级后端（默认约 5s），解锁后自动
   回到 DXGI 零拷贝，而不是整段会话停留在 10-30ms 的 GDI 路径。

## 7. 一句话总结

**降级链 = 后端目录 + 暖备 + 失败降级 + 空闲重探 + 锁屏事件驱动 + 格式变化才重建**。
上层永远只面对一个 `IScreenCapturer`，后端切换对业务透明——**这是"体验连续性"与
"实现解耦"两个目标同时满足的关键设计**。

---

