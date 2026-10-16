# 07 · 私有控制面与自定义 SEI 时间戳

> 系列第 7 篇。讲"自己的协议"：心跳、帧率协商、OSD/光标上报，以及把时间戳塞进 HEVC 流。
> 涉及模块：**公共层**（私有控制面 `control_channel`、SEI 时间戳 `sei_timestamp`）
> 术语约定：SEI/NAL/annexb、控制面/墙钟等见 《系列导读 · 术语表》。

---

## 设计意图

第 6 篇讲媒体面全走标准（RTP + RTCP）。这一篇回答"剩下那些标准协议不管的事怎么办"：

1. **策略类消息与媒体反馈分离**——心跳、帧率协商、OSD、暂停这些是"控制策略"，
   不该混进媒体面，也不该为了它们把 RTCP 复杂化。于是有一条**私有的、独立的控制面**。
2. **测量帧级延迟需要一个"自己的"时间戳**——标准 SEI 里没有现成的端到端测量字段，
   我们用 `user_data_unregistered` SEI 塞自定义时间戳，还因此踩了 annexb 起始码的坑。
3. **协议自洽**——二进制定长消息 + magic/version/seq 头，防串包、可扩展、可丢包检测。

一句话：**媒体走标准，策略走私有；私有协议要能自解释、抗错、可演进。**

---

## 1. 私有控制面：UDP 8555 二进制定长消息

报文格式：

```cpp
struct ControlHeader {
  uint32_t magic;    // kControlMagic，防串包
  uint8_t  version;  // 协议版本
  uint8_t  type;     // 消息类型
  uint16_t seq;      // 进程内原子递增序号（丢包检测）
  uint16_t length;   // payload 长度
  uint8_t  reserved;
};
// 消息 = ControlHeader + payload（定长小结构体）
```

构建 / 解析（一对可对称的函数，头尾共用）：

```cpp
std::vector<uint8_t> buildControlMessage(ControlType type, const void* payload, uint16_t len);
bool parseControlMessage(const uint8_t* buf, size_t len, ControlHeader* header,
                         const uint8_t** payload, size_t* payload_len);
// parse 校验：magic/version 必须匹配；sizeof(Header)+h.length <= len 才放行
```

设计意图逐个字段：
- **magic**：UDP 无连接，可能收到陌生/串包数据，magic 是"这不是我们协议的包"的一票否决。
- **version**：协议可演进，两端版本不一致时优雅拒绝而非解析错乱。
- **seq**：进程内原子递增，接收端可据此做丢包统计（本项目不据此重传，仅观测）。
- **length + 定长小 payload**：一个 socket 收一个消息，避免粘包/半包问题。
- **build/parse 对称**：发送端和接收端共用同一对函数，协议定义只有一处。

## 2. 消息类型一览

| 类型 | 方向 | 负载 | 用途 |
|---|---|---|---|
| `kControlHeartbeat` | viewer→capture | 无 | 在线心跳（capture 据此判断显示端是否在，8s 超时停流） |
| `kControlFpsInfo` | viewer→capture | uint32 hz | 上报显示端刷新率，协商 min(两端) 推流帧率 |
| `kControlOsd` | viewer→capture | uint8 on | 请求采集端周期上报状态/光标 |
| `kControlStatusInfo` | capture→viewer | 定长结构 | fps/编码器/分辨率/码率/已推帧数 |
| `kControlCursorInfo` | capture→viewer | x,y,visible | 远程光标坐标（OSD 叠加用） |
| `kControlPing` | viewer→capture→viewer | int64 | RTT 探测 / 时钟偏移估计 |
| `kControlStreamPause/Resume` | viewer→capture | 无 | 焦点切走/切回时暂停/恢复推流 |

设计意图：这组消息覆盖了"策略"三类场景——**在线判断**（心跳）、**参数协商**（帧率）、
**人机交互**（OSD/光标/暂停）。刻意没放"请求关键帧"——那是媒体的活，已在第 6 篇的 RTCP 里。

## 3. 时钟偏移估计（NTP/Cristian 算法）

做端到端延迟测量时，两端墙钟不一致会污染结果。用控制面做 RTT 探测：

- viewer 发 `{t1}`（发包端墙钟 ms）；
- capture 回 `{t1, t2, t3}`（t2=收包时刻，t3=回发时刻，近似同一时刻）；
- viewer 在 `t4` 收到后用 **offset = ((t2-t1)+(t3-t4))/2** 估计两端时钟偏差。

这样 e2e 延迟 = `本地now - SEI墙钟 + offset`，把跨机墙钟差异扣掉，不依赖两端时间一致。

设计意图：**没有时钟偏移估计，端到端延迟测量就是错的**——两台机器的墙钟可能差几分钟，
直接相减会把真实延迟淹没。Cristian 算法用往返时间的不对称来近似偏移，是极低成本、
够用的做法。

## 4. 自定义 SEI 时间戳

在 HEVC 流里塞自定义帧时间戳，做**帧级端到端延迟测量**。用 `user_data_unregistered` SEI：

```
annexb 布局：00 00 00 01 | 0x4E(SEI) | 0x05(payload_type=user_data_unregistered)
  | 0x18(payload_size=24) | uuid[16] | ms[8B 大端 XOR 0x55] | 0x80(rbsp_trailing)
```

**一个非常隐蔽的坑**：墙上时钟毫秒（~1.7e12）的大端 8 字节**高 3 字节恒为 `00 00 01`**，
而 annexb 里任意位置出现 `00 00 01` 都会被 ffmpeg 的 NAL 起始码扫描误判为分界，导致
SEI 被切断。所以时间戳 8 字节**逐字节 XOR 0x55 扰码**后再写入，解析端同样 XOR 还原：
扰码后字节序列不再含 `00 00 01`，SEI 在打包/重组过程中保持完整。

```cpp
void buildTimeSei(int64_t wall_ms, std::vector<uint8_t>& out) {
  out.insert(out.end(), {0x00, 0x00, 0x00, 0x01, 0x4E, 0x05});
  out.push_back(16 + 8);                 // payload_size = uuid + 8B ms
  out.insert(out.end(), kTimeSeiUuid, kTimeSeiUuid + 16);
  for (int i = 7; i >= 0; --i)
    out.push_back((uint8_t)(((wall_ms >> (i * 8)) & 0xFF) ^ 0x55));  // XOR 扰码
  out.push_back(0x80);                   // rbsp_trailing_bits
}
```

解析端：扫 annexb start code → 取 NAL type（39/40 才是 SEI）→ 校验 payload_type=5、
psz=24、uuid 匹配 → 8 字节 XOR 还原成 `int64_t ms`。

设计意图：
- **为什么用 user_data_unregistered 而非其它**：它有 16 字节 UUID 可识别"这是我的 SEI"，
  语义上是给应用自定义数据用的，且解码器自动忽略，不影响画面。
- **为什么 XOR 扰码**：这是"自定义二进制塞进 annexb"的经典坑——字节流里不能出现
  起始码 `00 00 01`，XOR 是保持字节数不变、又能打散这种模式的最简手段。
- **uuid 匹配**：防止误把别人的 user_data 当自己的时间戳。

> 采集端 `onFrame` 每帧写一条 SEI 独立 AU 到流（先于视频包），接收端用它算 e2e。
> 纯 SEI 小包在接收端被单独消耗不送解码器；与视频 AU 合并的大包则整包进解码器
> （HEVC 解码器自动忽略 SEI），避免吞掉视频 NAL 导致黑屏。
> 设计意图：**小包单独走（不进解码器）、大包合并走（解码器自己忽略 SEI）**，
> 是为了"SEI 既到达又绝不影响视频 NAL 的完整性"。

## 5. 控制面 server 端（采集端）实现要点

```cpp
bool ControlChannelServer::start(int port) {
  sock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  bind(sock_, ..., port);      // 传 0 时用 getsockname 查询系统分配的实际端口
  running_ = true;
  thread_.start([this] { run(); });   // 后台线程收包
}
```

`run()` 里 `recvfrom` → `parseControlMessage` → 按 `h.type` 分发：心跳只刷新
`last_peer_ms_`（在线判定）；FpsInfo 存 `fps_pending_`；Ping 回 pong；Pause/Resume 置标志。
`stop()` 用 `shutdown(SD_BOTH)` 解除 `recvfrom` 阻塞。

> 控制面还有一个隐藏作用：**记录对端来源地址**（peer），采集端推流时数据面目标 =
> 显示端真实 IP（UDP `connect=1` 不能连 0.0.0.0）。

设计意图：**控制面是"先导"通道**——它在数据面之前建立，让采集端知道显示端真实 IP，
数据面才敢用 `connect=1` 连接式 UDP。这解决了"采集端 listen 0.0.0.0，但真正要发给谁"
的问题。

### 5.1 控制面安全与演进

- **关键帧请求的历史**：早期曾用私有 `sendKeyframeRequest`（走 8555），后因"语义标准 +
  少一跳"改为标准 RTCP PLI（第 6 篇）；私有 requestKeyframe 仅保留作旧显示端兼容路径，
  新代码一律走 RTCP。**控制面只留策略类消息**。
- **安全（当进程以 SYSTEM 权限运行时尤其重要）**：命名管道/门控来源需**对端鉴权 + 会话
  随机数**，防止任意本地进程冒充 server 触发"屏幕已切换"。控制报文自带 magic/version，
  已是第一道防线。
- **时钟偏移实测**：真实双机 NTP/Cristian 探测 offset ≈ -10 ~ -18ms，正负均能量准；
  RTT 探测含应用层调度（8~54ms），offset 公式对对称延迟鲁棒，故 e2e 补偿后为真实值。

## 6. 一句话总结

**私有控制面 = UDP 二进制定长消息（magic/type/seq 头）承载心跳、帧率协商、OSD、暂停**；
**SEI 时间戳 = user_data_unregistered + XOR 扰码**，让时间戳在 annexb 里不被误切，
从而支持帧级端到端延迟测量。**媒体走标准，策略走私有，两者各归其位。**

---

