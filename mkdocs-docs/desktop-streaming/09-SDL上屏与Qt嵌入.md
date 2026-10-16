# 09 · SDL 上屏与 Qt 嵌入

> 系列第 9 篇。讲清楚解码出来的帧怎么用 SDL 画上屏，以及怎么嵌进 Qt 窗口。
> 涉及模块：**接收端显示**（`SdlDisplay` 独立窗口，`VideoWidget` + SDL 渲染线程的 Qt 嵌入）
> 术语约定：SDL/HWND/QWidget 属性/三缓冲等见 《系列导读 · 术语表》。

---

## 设计意图

解码出的 NV12 帧，怎么又快又稳地变成屏幕上的像素？这一篇的三个核心设计：

1. **用 SDL 做渲染，而不是 Qt 直接画——这是引入 SDL 的根本原因**。SDL 提供 GPU 加速的
   D3D11 渲染器，把"缩放 + 合成（叠加光标/OSD）+ 跨平台"一并搞定。注意：**颜色转换
   NV12→RGB24 仍由 CPU `sws_scale` 完成**（当前实现上屏纹理就是 RGB24，没有 NV12 直传）；
   SDL 的 GPU 负责的是 RenderCopy 时的缩放与 overlay 合成，不是颜色转换。即便嵌进 Qt
   （`SDL_CreateWindowFrom`），渲染仍是 SDL 引擎，Qt 只当壳。
2. **渲染线程与界面线程解耦**——渲染放独立线程，且 present（耗时 ~24ms）不持锁，
   界面/解码线程不被渲染背压。
3. **嵌入 Qt 要解决"SDL 收不到 WM_SIZE"的尺寸同步坑**——绑定外部窗口后，必须手动把
   Qt 客户区尺寸换算成 SDL 物理尺寸再同步。

一句话：**SDL 负责画，Qt 负责壳；两者通过原生窗口句柄 + DPI 尺寸同步打通。**

---

## 1. 独立窗口模式：SdlDisplay

### 1.1 窗口与渲染器创建

```cpp
SDL_InitSubSystem(SDL_INIT_VIDEO);
window_ = SDL_CreateWindow(title, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                           width, height, SDL_WINDOW_HIDDEN | SDL_WINDOW_RESIZABLE);
// 强制 D3D11 渲染器：D3D9(direct3d) 在外部窗口 resize 时交换链重建不稳定，
// 表现为窗口缩放期间长时间黑屏、恢复首帧绿色残留。direct3d11 走 DXGI ResizeBuffers。
SDL_SetHint(SDL_HINT_RENDER_DRIVER, "direct3d11");
renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_ACCELERATED);
// 不可用时依次回退：清除 hint 再试加速 → 软件渲染
```

设计意图：**为什么优先 D3D11 渲染器**——D3D9 交换链在窗口 resize 时重建不稳定，
会黑屏/绿屏；D3D11 走 DXGI `ResizeBuffers`，稳定得多。这是"缩放不断裂"的第一道保障。

### 1.2 纹理与渲染

- **STREAMING 纹理**：`SDL_CreateTexture(renderer_, SDL_PIXELFORMAT_RGB24,
  SDL_TEXTUREACCESS_STREAMING, width, height)`，用 `SDL_UpdateTexture` 上传 RGB24——
  显示层已先用 `sws_scale` 把解码输出的 NV12 转成 RGB24（第 8 篇）。
- **高质量缩放**：`SDL_SetTextureScaleMode(texture_, SDL_ScaleModeBest)` 抗锯齿，
  避免缩小时摩尔纹。
- **present**：`RenderClear → RenderCopy(铺满窗口) → 叠加层 → RenderPresent`。

设计意图：**STREAMING 纹理**是"每帧更新内容"的正确选择（区别于 STATIC 的一次性纹理）；
**ScaleModeBest** 保证缩放质量——远程画面常被缩到窗口大小，劣质缩放一眼可见摩尔纹。

### 1.3 resize 限流（关键体验点）

D3D 交换链重建开销大（~90ms），resize 消息风暴期间每帧重建会拖死窗口主线程。处理：
**resize 活跃时每 100ms 放行一次重建+贴图，其余尺寸变化帧直接跳过**；尺寸稳定后自动恢复全速。

```cpp
if (ww != last_win_w_ || wh != last_win_h_) {
  last_win_w_ = ww; last_win_h_ = wh;
  if (now - last_resize_present_ < 100ms) return true;  // 限频
  last_resize_present_ = now;
  SDL_SetWindowSize(window_, pw, ph);   // 物理像素
  SDL_RenderSetLogicalSize(renderer_, ww, wh);  // 逻辑尺寸对齐
}
```

设计意图：**交换链重建是"贵"操作**（~90ms），拖拽窗口时 resize 消息一帧接一帧，若每帧
都重建，主线程直接卡死。限频（100ms 放行一次）让"拖拽中"的每一帧都先跳过，只在
节奏点重建——**用短暂的不跟随换不卡死**，松手后自动恢复全速。

### 1.4 叠加层：远程光标 + 状态 OSD

- **远程光标**：优先用 Windows 系统光标（`LoadCursor(IDC_ARROW/IDC_CROSS)` → `GetIconInfo`
  → `DrawIconEx` 渲染成 SDL 纹理），关键是要 **`SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)`**
  否则透明区域（alpha=0）会以黑色直接覆盖成黑框。正常版先画 8 方向偏移 1px 的纯黑底
  （描边）再画原图，任何底色上都清晰。加载失败回退自绘（十字/箭头/圆点）。
- **状态 OSD**：SDL_ttf 渲染（`C:\Windows\Fonts\msyh.ttc` 微软雅黑支持中文），多行文本
  每行 `TTF_RenderUTF8_Blended` 合成一张透明底纹理，`SDL_SetTextureAlphaMod(tex, 235)` 半透明。

设计意图：**远程光标是"手动叠加"而非"抓进画面"**——因为光标移动不产生新帧，必须
每轮用 `cursorInfo` 单独画。而透明光标必须开 `BLENDMODE_BLEND`，否则 alpha=0 的透明
区域被当成黑色直接盖成"黑框光标"；加黑描边则让任何底色上的光标都清晰可辨。

## 2. 嵌入 Qt：SDL_CreateWindowFrom

Qt viewer 的渲染是 **SDL 绑定 Qt 窗口**（不是 QOpenGLWidget），界面/托盘/全屏归 Qt，
画面由 SDL 渲染线程直接写进原生窗口表面。

### 2.1 关键第一步：VideoWidget 必须是原生窗口

`VideoWidget`（Qt 侧的承载控件）定义如下：

```cpp
VideoWidget::VideoWidget(QWidget* parent) : QWidget(parent) {
  setAttribute(Qt::WA_PaintOnScreen);      // 渲染直接写原生表面，Qt 不合成
  setAttribute(Qt::WA_NoSystemBackground); // 不画系统背景，避免覆盖
  setAttribute(Qt::WA_OpaquePaintEvent);
  setAttribute(Qt::WA_NativeWindow);       // 强制成为原生窗口
  setFocusPolicy(Qt::StrongFocus);
}
void* VideoWidget::nativeHandle() {
  return reinterpret_cast<void*>(winId());  // winId() 确保原生 HWND 已创建
}
```

`paintEvent` 为空（画面由 SDL present 到窗口表面），`resizeEvent` 把客户区尺寸发布给
SDL 渲染线程（画面铺满/缩放目标）：

```cpp
void VideoWidget::resizeEvent(QResizeEvent* event) {
  QWidget::resizeEvent(event);
  g_video_widget_w.store(event->size().width());
  g_video_widget_h.store(event->size().height());
}
```

设计意图：**`WA_PaintOnScreen` + `WA_NativeWindow` 是"让 SDL 能接管画布"的开关**——
`WA_PaintOnScreen` 让渲染直写原生表面、Qt 不拦截合成；`winId()` 才拿到真正的 HWND
给 `SDL_CreateWindowFrom`。四个 attribute 缺一不可，否则 SDL 画的东西会被 Qt 合成层
覆盖。

### 2.2 SDL 绑定外部窗口

```cpp
window_ = SDL_CreateWindowFrom(native_handle);   // SDL 不拥有窗口，只建渲染器与纹理
SDL_SetHint(SDL_HINT_RENDER_DRIVER, "direct3d11");
renderer_ = SDL_CreateRenderer(window_, -1, SDL_RENDERER_ACCELERATED);
disp.show();   // 绑定外部窗口后必须标记可见：present() 只在 visible_ 时真正 RenderClear/Copy/Present
```

设计意图：`SDL_CreateWindowFrom` 让 SDL **不拥有窗口、只接管其表面渲染**——
窗口生命周期归 Qt（GUI 线程），渲染归 SDL（渲染线程）。`disp.show()` 是必需的：
SDL 只渲染"可见"窗口，忘了 show 会静默不画。

### 2.3 Qt 窗口尺寸 → SDL 物理尺寸同步（最大的嵌入坑）

绑定外部 Qt 窗口后 **SDL 收不到 WM_SIZE**，内部窗口尺寸恒为绑定时的初始值 →
renderer 物理输出区域不变，画面永远被裁剪在初始尺寸内。解决：present 里检测到 Qt 客户区
尺寸变化时，把 SDL 内部窗口尺寸强制同步到 Qt 客户区（换算 DPI）：

```cpp
// SDL 内部尺寸是物理像素，Qt 客户区是逻辑像素（本机 125% DPI：sdl≈1.25× qt）。
float hdpi = 96.0f, vdpi = 96.0f;
SDL_GetDisplayDPI(SDL_GetWindowDisplayIndex(window_), nullptr, &hdpi, &vdpi);
int pw = (int)(ww * hdpi / 96.0f + 0.5f);
int ph = (int)(wh * vdpi / 96.0f + 0.5f);
SDL_SetWindowSize(window_, pw, ph);
SDL_RenderSetLogicalSize(renderer_, ww, wh);   // 逻辑尺寸对齐 Qt 客户区
```

同时渲染线程必须**轮询 SDL 事件**（`SDL_PollEvent`），否则 SDL 不更新内部尺寸且事件队列
持续堆积——不处理业务，只让内部状态随之更新。

设计意图：**这是 Qt 嵌入最大的坑**——绑定外部窗口后 SDL 监听不到窗口尺寸变化，必须
"反向喂"：从 Qt 拿客户区尺寸 → 按 DPI 换算物理像素 → 显式 `SDL_SetWindowSize` 同步。
忽略 DPI 换算（125% 屏）会让画面被裁剪/留黑边。渲染线程轮询事件是为让 SDL 内部
尺寸/状态随之更新。

### 2.4 三缓冲帧槽：解码线程与渲染线程解耦

`Conn` 结构体持有三块缓冲 + 指针轮转，**整帧零拷贝**：

```
解码线程 sws 输出 RGB24 到 back → swap 到 front（无 memcpy）→ notify
渲染线程锁内 swap(front, present) 拿走最新帧 → 解锁 → 锁外 present(present)
```

- present（GPU 上传+渲染，实测 ~24ms/帧）**不持锁**：解码线程不再被渲染背压；
- 渲染只显示最新帧（自然丢旧帧），端到端延迟保持低。

设计意图：**三缓冲 + 锁外 present 是"渲染慢但不拖累解码"的关键**。如果 present 持锁，
渲染耗时 24ms 会让解码线程一起卡；现在渲染拿走"最新帧"后在锁外慢慢传 GPU，解码线程
可继续产出下一帧。渲染只显示最新帧 = 故意丢旧帧，换来低延迟。

### 2.5 Qt 端多连接 + SDK 门控

- **多数据连接**：`--conn rtp://host:8554 --screen NAME` 可重复，全部保持连接，
  只渲染激活的那一路；`active_idx` 决定渲染哪路，非激活连接走 `keepAliveRead()`（读包丢弃）。
- **屏幕切换门控**：连接本机屏幕切换服务的命名管道（如 `\\.\pipe\screenswitch.sdk`），
  订阅 `screenSwitched` / `machineConnected` / `machineDisconnected` 事件。切屏事件驱动
  切换显示目标，切到被控机才解码上屏，切回本机即隐藏/停解码。
- **GUI 线程 = 主线程**：`QApplication` 在主线程，渲染线程用 `SDL_CreateWindowFrom(hwnd)`
  （hwnd 必须 GUI 线程通过 `winId()` 预创建）。
- **托盘常驻**：关闭窗口 = 隐藏到托盘（`setQuitOnLastWindowClosed(false)`）。
- **F11 全屏**：Qt 窗口 `showFullScreen()`，SDL 渲染区随窗口自动缩放。

设计意图：**多连接常驻 + SDK 事件门控**让这台机器能同时挂着多台被控机，按屏幕切换事件
决定"现在显示谁"——这是"一个接收端管多台设备"的产品化能力，而画面渲染始终只有一个
激活连接在跑。

## 3. 一句话总结

**独立窗口 = SDL 建窗/渲染器/STREAMING 纹理 + resize 限流 + 光标 OSD；嵌入 Qt = 原生
widget + SDL_CreateWindowFrom + DPI 尺寸同步 + 三缓冲零拷贝 + 渲染线程锁外 present**。
SDL 负责画得快又稳，Qt 负责壳和交互，二者在原生句柄上无缝衔接。

---

