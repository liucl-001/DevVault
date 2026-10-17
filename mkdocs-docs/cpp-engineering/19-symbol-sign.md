# 符号服务与签名网关：用 nginx 把调试闭环补全

> 本节解决：构建流水线产出的调试符号（第 10 章的 createSymbols）放哪、怎么下载、怎么配合签名——一套 nginx 符号网关，把"提取符号 → 上传归档 → 崩溃定位"完整闭环。

## 没有符号服务，崩溃定位等于裸奔

C++ 应用发布到用户手里，崩溃了怎么办？你拿到的可能只是一串地址（`0x00007ff6...`）——没有符号，没人知道崩在哪。这就是符号服务的价值：**构建时提取的调试符号（第 10 章 createSymbols）被集中存储，崩溃发生时调试器/崩溃收集器自动下载对应版本的符号，把地址还原成函数名和行号**。

前面章节解决了"符号怎么提取"（createSymbols 三平台）、"符号怎么归档"（zip + BUILD_NUMBER），但**符号存在哪、怎么被下载**一直缺位——这一节用一套真实生产的 nginx 符号服务补全它。它同时还是一个代码签名网关，一个服务管两件事。

## 全景：符号服务的三大块

```
构建流水线（第 10 章）
   ├─ createSymbols 提取三平台符号
   └─ uploadSymbols 上传 *_symbols.{zip,tar}
        ↓
nginx 符号网关（本节）
   ├─ upload_symbols.lua  接收上传，按平台解压归档
   ├─ symbols.conf        三平台符号下载（HTTP + 目录浏览）
        ↓
调试器/崩溃收集器 按 Build ID/UUID/PDB 名自动下载符号 → 崩溃定位
```

## 第一块：符号下载服务（symbols.conf）

三个 server 对应三个平台，目录结构**和 createSymbols 的输出完全一致**：

```nginx
# 来源：sites/symbols.conf（脱敏）
# Windows：PDB 符号（调试器按 PDB 名+GUID 路径查找）
server {
    listen 80;
    server_name windows.symbols.<domain>;
    location / {
        alias /data/symbols/symbols_win/;
        autoindex on;                    # 目录浏览，调试器/人肉都可查
        location ~* \.pdb$ {
            types { }
            default_type application/octet-stream;   # PDB 按文件下载
            add_header Content-Disposition "attachment" always;
        }
    }
}

# macOS：dSYM 符号（第 10 章 createSymbols 按 UUID 散列存储）
server {
    listen 80;
    server_name macos.symbols.<domain>;
    location /uuids {
        alias /data/symbols/symbols_macos/;
        autoindex on;
    }
    location / { return 301 /uuids/; }   # 根路径重定向到符号目录
}

# Linux：.debug 符号（第 10 章按 Build ID 散列存储）
server {
    listen 80;
    server_name linux.symbols.<domain>;
    location /.build-id {
        alias /data/symbols/symbols_linux/;
        autoindex on;
    }
    location / { return 301 /.build-id/; }
}
```

三个设计点：

1. **目录结构 = createSymbols 的输出结构**：Linux 的 `.build-id/xx/xxxx.debug`、macOS 的 `uuids/xx/xxxx.dSYM`、Windows 的 PDB 散列目录——**提取端（第 10 章）和存储端（本节）约定同一套目录规范，这才是闭环能闭合的关键**；
2. **`autoindex on`**：符号目录支持浏览器/工具直接浏览，人肉排查时不用猜路径；
3. **PDB 特殊处理**：`application/octet-stream` + `Content-Disposition: attachment`，保证调试器下载时按文件处理而不是被 nginx 当文本渲染。

## 第二块：符号上传（upload_symbols.lua）

流水线用 `uploadSymbols`（第 12 章共享库）把符号包 POST 上来，Lua 脚本负责接收、按平台解压、归档：

```lua
-- 来源：script/upload_symbols.lua（脱敏，核心逻辑）
local function process_symbols(filename, target_path)
    -- 按请求参数分流：type=pro 进正式目录，默认进 debug 目录
    local args = ngx.req.get_uri_args()
    if args.type ~= "pro" then
        target_path = target_path .. "debug/"
    end
    -- 按扩展名解压：zip / tar / gz / bz2 / xz
    if ext == "zip" then
        extract_cmd = "unzip -o ..."
    else
        extract_cmd = "tar -xf ..."
    end
    os.execute("mkdir -p " .. target_path .. " && " .. extract_cmd)
end

-- 按文件名匹配平台：*_symbols.{zip,tar,...}
if filename:match("windows_symbols%.") then process_win_symbols(...)
elseif filename:match("macos_symbols%.")   then process_macos_symbols(...)
elseif filename:match("linux_symbols%.")   then process_linux_symbols(...)
```

关键约定：**文件名必须带平台标识**（`windows_symbols.zip`/`macos_symbols.zip`/`linux_symbols.zip`）——这是流水线和符号服务的"接口协议"。第 10 章流水线打包符号时用的正是 `${BUILD_NUMBER}_${plat}_symbols.zip` 命名，两头严格对应。

## 第三块：签名网关（win_sign.conf）

代码签名（第 17 章提过 macOS keychain、Windows 签名）需要一个独立的签名服务，nginx 做反向代理把请求转发给签名服务器：

```nginx
# 来源：sites/win_sign.conf（脱敏）
server {
    listen 9981;
    # 关键超时配置：签名任务可能执行很久
    proxy_connect_timeout 20s;
    proxy_send_timeout 3620s;        # 60 分钟超时
    proxy_read_timeout 3620s;
    client_max_body_size 1G;         # 待签名文件可能很大
    client_body_buffer_size 1M;      # 上传阶段写磁盘，不占内存
    proxy_buffering off;             # 流式转发，低内存占用
    location / {
        proxy_pass http://<sign-server>:8080;
        proxy_set_header X-Service-Type "sign-gateway";
        proxy_request_buffering off;
    }
}
```

与流水线的对接：第 12 章的 `funcTest`/`winSignFile` 共享库函数把待签名文件上传到 `http://<nginx>:9981/sign`，nginx 流式转发给签名服务器，签名完成后原路返回。**9981 端口就是流水线里写死的签名入口**——签名服务和构建体系通过这个网关解耦，签名服务器挂了可以独立重启，不影响构建。

## 部署：compose 一键起

```yaml
# 来源：compose.yaml（脱敏）
services:
  gateway:
    image: <registry>/gateway:latest
    ports: [ "80:80", "9981:9981", "8090:8090" ]
    volumes:
      - ./symbols_win:/data/symbols/symbols_win:rw     # 三平台符号目录
      - ./symbols_linux:/data/symbols/symbols_linux:rw
      - ./symbols_macos:/data/symbols/symbols_macos:rw
      - ./script:/data/scripts:ro
      - ./sites:/etc/nginx/sites-enabled:ro
      - /etc/localtime:/etc/localtime:ro                # 时区彻底同步
    deploy:
      resources:
        limits: { cpus: '2', memory: 1G }               # 资源上限
  jaeger:
    image: <registry>/jaeger:one
    ports: [ "4317:4317", "16686:16686" ]               # 链路追踪
    environment: { COLLECTOR_OTLP_ENABLED: true }
```

部署要点：
- **配置即代码**：`sites/`（nginx 站点配置）和 `script/`（Lua）以只读卷挂载进容器，改配置不用重建镜像，`nginx -s reload` 即生效；
- **符号目录挂数据盘**：符号文件只增不减，三平台目录都挂 `:rw` 卷；
- **Jaeger 链路追踪**：网关带 OpenTelemetry，签名/上传请求可追踪，排查"符号上传卡在哪"有据可依；
- **资源限制**：网关本身很轻，2 核 1G 足够，`limits` 防止镜像/日志异常打爆宿主机。

## 完整调试闭环（全册串联）

```
发布后崩溃
   ↓
崩溃收集器/用户反馈拿到崩溃地址 + 版本号
   ↓
从符号服务下载对应版本符号：
  Windows: http://windows.symbols.<domain>/<pdb路径>   （PDB 按名+GUID）
  macOS:   http://macos.symbols.<domain>/uuids/<uuid路径> （UUID 对应 dSYM）
  Linux:   http://linux.symbols.<domain>/.build-id/<id路径> （Build ID 对应 .debug）
   ↓
符号化：地址 → 函数名 → 行号 → 定位崩溃点
```

配合第 10 章：**构建时 createSymbols 按平台规范提取 → uploadSymbols 上传到本节网关 → 崩溃时按同样规范下载**——提取、存储、检索三段用同一套目录规范，这就是"调试闭环"的完整性。

## 调试器接入：VS / LLDB / GDB 三平台实操

符号服务建好了，**调试器怎么用起来**才是读者真正关心的：三大平台配置路径各不相同，这一节逐个讲透——核心就一句话：**把符号服务地址告诉调试器，目录结构对上，调试器自动下载符号**。

### Visual Studio（Windows · PDB）

1. **配置符号服务器**（UI，一次性）：

```text
工具 → 选项 → 调试 → 符号
  ├─ "符号文件(.pdb)位置" → 添加 → 填：http://windows.symbols.<domain>
  ├─ 勾选"在此目录下缓存符号"，填 C:\Symbols   ← 符号只下载一次，第二次起走本地缓存
  └─ 加载行为：仅指定的模块（推荐，快） / 所有模块
```

2. **打开崩溃转储**：

```text
文件 → 打开 → 文件 → 选 .dmp
```

VS 自动进入调试会话，首次打开会自动向符号服务器请求对应 PDB（按 PDB 名 + GUID 的 SSQP 路径）。

3. **验证符号已加载**：

```text
调试 → 窗口 → 模块 → 右键目标模块 → "加载符号"
状态显示"已加载符号"即成功；调用堆栈窗口直接显示 函数名 + 行号
```

命令行等价（WinDbg/cdb 场景）：

```text
set _NT_SYMBOL_PATH=srv*C:\Symbols*http://windows.symbols.<domain>
```

### LLDB（macOS · dSYM）

dSYM 靠 **UUID** 匹配，符号服务目录就是 `/uuids/<uuid前2位>/<完整uuid>.dSYM`。两步：

1. **按 UUID 取符号**（dwarfdump 查 UUID，curl 按路径下载到本地）：

```bash
UUID=$(dwarfdump --uuid ./YourApp | awk '{print $2}')
curl -o /tmp/${UUID}.dSYM \
     http://macos.symbols.<domain>/uuids/${UUID:0:2}/${UUID}.dSYM
```

2. **加载进 lldb 并符号化**：

```text
lldb -c /path/to/core YourApp
(lldb) add-dsym /tmp/${UUID}.dSYM            # 新版 lldb 可用 image add
(lldb) image lookup --address 0x<崩溃地址>
(lldb) bt
```

没有 lldb 交互环境时用 atos 一行命令：

```bash
atos -o /tmp/${UUID}.dSYM/Contents/Resources/DWARF/YourApp -l <加载地址> 0x<崩溃地址>
```

### GDB（Linux · .build-id）

GDB 按 **Build ID** 结构查找 .debug 文件：`debug-file-directory` 目录下放 `.build-id/<前2位>/<剩余>.debug`——**正好就是符号服务 linux 目录的原始结构**，直接 rsync 或按需 curl：

1. **拉符号到本地**：

```bash
mkdir -p /tmp/syms && cd /tmp/syms
# 方式A：整目录 rsync（量大但一次到位）
rsync -av http://linux.symbols.<domain>/.build-id/ /tmp/syms/.build-id/
# 方式B：按需 curl（只取一个崩溃需要的）
curl -o /tmp/syms/.build-id/<ab>/<rest>.debug \
     http://linux.symbols.<domain>/.build-id/<ab>/<rest>.debug
```

2. **gdb 里配置并回溯**：

```text
gdb ./YourApp core
(gdb) set debug-file-directory /tmp/syms
(gdb) bt
```

3. **源码路径替换**（构建机和本地路径不一致时）：

```text
(gdb) set substitute-path /build/path /local/path
```

**进阶（gdb 12+）**：gdb 原生支持 debuginfod 协议，符号服务若实现 `/buildid/<id>/debuginfo` 端点，可完全自动下载：

```text
set debuginfod enabled on
set debuginfod urls http://linux.symbols.<domain>/
```

（当前符号服务是静态 `.build-id/` 文件结构，用前两种方式即可；想升级 debuginfod 端点也可行——见【待补】。）

### 三平台对照表

| 平台 | 调试器 | 符号类型 | 匹配依据 | 接入方式 |
|---|---|---|---|---|
| Windows | Visual Studio / WinDbg | PDB | PDB 名 + GUID | 选项→调试→符号 填 URL |
| macOS | LLDB / atos | dSYM | UUID | add-dsym / image lookup |
| Linux | GDB | .debug | Build ID | debug-file-directory |

三个关键认知：

1. **匹配依据各不相同，但都来自构建期元数据**——GUID/UUID/Build ID 就是第 10 章 createSymbols 提取并归档这些标识的原因，构建期多存一个标识，崩溃期少花一天；
2. **VS 是 UI 配置，lldb/gdb 是命令配置**，本质都是"告诉调试器去哪找符号"；
3. **符号服务 `autoindex on` 让"确认符号在不在"变成浏览器打开目录树**——排查"为什么符号没匹配上"时不用猜。

【待补】作者实际使用时的命令输出/截图（cdb/VS 的符号化结果、lldb image lookup 输出、gdb bt 输出），各补一段真实输出最有说服力。

## 踩过的坑

1. **符号目录结构必须和 createSymbols 输出严格一致**：提取端改目录规范，存储端必须同步——建议把目录规范写进共享库注释（第 12 章），两端各留一份；
2. **上传文件命名必须带平台标识**：`upload_symbols.lua` 靠文件名判断平台，命名不规范 = 符号进错目录 = 崩溃时下载不到；
3. **签名请求可能跑 60 分钟**：nginx 默认超时 60 秒，签名网关必须把 `proxy_read_timeout` 拉到 3600 秒级，否则大文件签名中途断连；
4. **大文件上传占内存**：`proxy_buffering off` + `client_body_buffer_size 1M` 流式写盘，否则 1G 文件上传直接 OOM；
5. **时区**：容器默认 UTC，日志时间对不上，`/etc/localtime` 卷挂载 + `TZ=Asia/Shanghai` 双保险。

## 小结

- 符号服务 = 三平台符号的集中存储与下载：目录结构（PDB/UUID/.build-id）与 createSymbols 输出严格对应，这是闭环闭合的关键；
- 上传走 Lua 脚本：按文件名匹配平台、按参数分流 debug/pro、解压归档；
- 签名网关（9981）把签名服务解耦出来，长超时 + 流式转发是生产必配；
- compose 部署：配置卷挂载、符号目录挂数据盘、Jaeger 链路追踪、资源限制；
- 完整闭环：提取（第 10 章）→ 上传归档（本节）→ 崩溃下载（本节）→ 符号化定位；
- 调试器接入：VS 填符号 URL（PDB+GUID）、LLDB add-dsym（UUID）、GDB debug-file-directory（Build ID）——三平台匹配依据不同，但都来自构建期元数据。

> 延伸：符号与制品的关系（第 20 章）、签名与凭证（第 17 章）、共享库里的 uploadSymbols 实现（第 12 章）——符号服务把这几章的"散件"串成了"调试闭环"。
