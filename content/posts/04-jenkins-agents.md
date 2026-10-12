---
title: "三平台从节点配置"
date: 2026-10-12T20:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
series: ["C++工程化实战"]
weight: 4
summary: "Ubuntu/Windows/macOS从节点安装、SSH连接、JDK一致性与故障排查"
---
# Jenkins 三平台从节点配置：Ubuntu / Windows / macOS

> 本节解决：构建机才是真正干活的地方——三平台从节点怎么配、添加节点时的关键参数、JDK 一致性、Windows 工作目录迁移、常见连接失败排查。

## 主节点管调度，从节点管干活

Jenkins 主节点只负责"派活"：解析流水线、调度 stage、分发到节点。真正的编译、测试、打包都发生在**从节点**上——所以从节点的配置质量，直接决定构建速度和稳定性。三平台从节点各有各的坑：Ubuntu 要选对系统版本、Windows 要处理盘符和 SSH、macOS 要开远程登录。

这一节按平台逐个讲，最后给"添加节点"的统一步骤和故障排查清单。

## Ubuntu 从节点

**第一步：系统选择（重要）**

| 版本 | 结论 | 原因 |
|---|---|---|
| Ubuntu Mini Server | ❌ 不推荐 | 精简过度，缺大量基础工具 |
| Ubuntu Desktop | ❌ 不推荐 | 桌面太重，浪费资源 |
| Ubuntu Server | ✅ 推荐 | 标准环境，按需装工具 |

> 部分系统装完可能有驱动不完整的情况，提前检查，避免构建性能低下。

**第二步：装 JDK + Docker + Git**

```bash
# JDK 版本必须和主节点一致（21）
apt install openjdk-21-jdk docker.io git -y

# 查 Java 路径（添加节点时要用）
which java
readlink -f $(which java)
```

**第三步：Docker 配置**

Docker 配置参考第 2/3 章（TCP 远程 + 国内源 + insecure-registries）。添加节点时给 Linux 节点配环境变量：

```text
DOCKER_HOST = 127.0.0.1:2375   # 让流水线里的 agent { docker } 能调用本机 docker
```

## Windows 从节点

Windows 是坑最多的平台，按顺序来：

**1. Git（Jenkins 节点必须装 Git，否则无法拉代码）**

```powershell
Invoke-WebRequest -OutFile git.zip https://mirrors.huaweicloud.com/git-for-windows/v2.54.0.windows.1/MinGit-2.54.0-64-bit.zip
Expand-Archive git.zip -DestinationPath 'C:\Tools\git'
[Environment]::SetEnvironmentVariable('PATH', ('C:\Tools\git\mingw64\bin;' + $env:PATH), 'Machine')
```

**2. Docker（微软官方安装脚本）**

```powershell
Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1" -o install-docker-ce.ps1
.\install-docker-ce.ps1
```

**3. Java（JDK 21 JRE，清华源）**

下载 [Windows JDK 21 JRE](https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jre/x64/windows)，解压到 `C:\Program Files\Java\jdk-21`。

**4. SSH**

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'
New-NetFirewallRule -DisplayName "Allow ssh In" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -Profile Private,Domain -Description "Allow inbound TCP 22 for OpenSSH server"
```

**5. 工作目录迁移（Windows 特有的坑）**

> Windows 容器中仅有 C 盘，Jenkins 默认工作目录在 C 盘——构建产物、workspace 全堆系统盘，很快打满。

```powershell
New-Item -ItemType Directory -Path 'E:\jenkins'
# 符号链接：C:\jenkins 指向 E:\jenkins（第 2 章的 mklink 解法）
New-Item -ItemType SymbolicLink -Path 'C:\jenkins' -Target 'E:\jenkins'
```

这和第 2 章 Linux 挪 `data-root` 是同一个思路：**构建机的磁盘规划决定它能扛多久**，别把系统盘当工作盘。

## macOS 节点

```bash
# 1. Xcode 命令行工具（编译器依赖）
xcode-select --install

# 2. JDK 21（ARM 版，清华源）
#    下载 https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jre/aarch64/mac
#    解压到 /Library/Java/JavaVirtualMachines/jdk-21

# 3. 开远程登录：系统设置 → 通用 → 远程登录 → 开启 → 添加用户
```

macOS 相对简单，注意 JDK 要下 **aarch64（ARM）版**——M 系列芯片的 macOS 节点跑 x86 版 JVM 会有兼容问题。

## 添加节点：统一步骤

`Manage Jenkins → Manage Nodes and Clouds → New Node`，关键参数：

| 配置项 | 值 | 说明 |
|---|---|---|
| Name | 如 `linux-01` | 流水线里 `label` 引用的名字 |
| Type | Permanent Agent | 固定节点 |
| Remote root directory | 工作目录（Windows 填 `C:\jenkins`） | 符号链接已指向大盘 |
| Launch method | Launch agents via SSH | SSH 连接 |
| Host | 节点 IP | |
| Credentials | SSH 凭据 | 先配好 |
| Host key verification | Non Verifying Verification Strategy | 内网免密钥校验 |
| Java path | Java 安装路径 | **必须明确配置** |
| Windows 附加 | Prefix Start Agent Command: `"c: &&"` | 先切到 C 盘再启动 agent |
| Linux 附加 | 环境变量 `DOCKER_HOST=127.0.0.1:2375` | 供 `agent { docker }` 调用 |

## 故障排查：从节点连接失败

按顺序查：

1. **SSH 通不通**：`ssh <用户名>@<节点IP>`——不通先解决网络/SSH 服务；
2. **Java 路径对不对**：Jenkins 通过 SSH 启动 agent 依赖 Java，路径错直接失败——用 `readlink -f $(which java)` 拿真实路径；
3. **工作目录权限**：`Remote root directory` 不可写/不存在，agent 起不来；
4. **看 Jenkins 系统日志**：`Manage Jenkins → System Log`，定位具体报错（最常见是 SSH 握手失败和 Java 版本不匹配）。

> 节点连接失败 90% 是"Java 路径错 / SSH 没开 / 工作目录不可写"三选一，先查这三样再动别的。

## 小结

- 从节点才是干活的地方：Ubuntu 选 Server 版、Windows 处理盘符和 SSH、macOS 开远程登录；
- **JDK 21 三平台一致**（主节点也是 21）——版本漂移是从节点连接失败的常见根因；
- Windows 工作目录用符号链接迁到大盘；Linux 挪 Docker 数据目录——别让系统盘扛构建；
- 添加节点六个关键参数：Name/Type/Remote root/SSH/Host key/Java path；
- 连接失败排查顺序：SSH → Java 路径 → 目录权限 → 系统日志。

> 延伸：节点就绪后，`agent { label }` 和 `agent { docker }` 才能真正跑起来（第 7/18 章），构建镜像（第 14 章）也才能在节点上被拉起。
