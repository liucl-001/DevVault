# 把编译器装进镜像：Linux / Windows 构建镜像的完整制作

> 本节解决：C++ 构建环境怎么容器化——Linux 的 gcc 镜像和 Windows 的 MSVC 镜像分别怎么搭、多阶段构建怎么组织、buildkit 缓存怎么配。

## 为什么要给 C++ 构建做镜像

C++ 项目的环境问题比任何语言都痛：

- **搭环境以天计**：一个新同事/新机器要把编译器、CMake、依赖库、GUI 库、打包工具全装一遍，出点版本冲突一两天就没了；
- **版本漂移**：你机器能编的，别人机器编不了——同一个 commit 在不同机器上产物不同，还查不出原因；
- **跨平台更痛**：Windows 要 VS BuildTools、macOS 要 Xcode、Linux 要 gcc，三套环境三套维护；
- **CI 机器共享**：多项目共用构建机，A 项目升级了依赖，B 项目莫名编不过。

解决方案就是把**整条工具链固化进 Docker 镜像**：谁构建、在哪个节点构建，都是同一个镜像、同一套编译器、同一批依赖。这一节用一套真实生产镜像讲清楚：Linux 镜像怎么搭、Windows 镜像怎么搭、怎么用 compose 一键构建和缓存。

## 全景：两个镜像 + 一个编排

有三个镜像目标：

| 镜像名 | 平台 | 内容 | 用途 |
|---|---|---|---|
| `gccbuild:ubuntu` | Linux | Ubuntu 24.04 + gcc 工具链 + GUI 依赖| Linux 构建与打包 |
| `msvcbuilder:vs2019` | Windows | Server Core + VS2019 BuildTools + Qt 5.15 + Windows SDK | Windows x64 构建|
| `msvcbuilder:vs2022` | Windows | Server Core 2025 + VS2022 BuildTools + Qt 6.10 + Windows SDK | Windows x64 构建 |

由两个 Dockerfile 定义（`Dockerfile.linux`、`Dockerfile.win`），一个 `compose.yaml` 统一构建、缓存、推送。

## Linux 镜像：gcc 工具链 + GUI 依赖

```dockerfile
# 来源：生产 Dockerfile.linux（脱敏）
ARG BASE_IMAGE=24.04
FROM ubuntu:$BASE_IMAGE as builder
RUN sed -i "s@http://.*security.ubuntu.com@http://mirrors.huaweicloud.com@g" /etc/apt/sources.list.d/ubuntu.sources
RUN sed -i "s@http://.*archive.ubuntu.com@http://mirrors.huaweicloud.com@g" /etc/apt/sources.list.d/ubuntu.sources
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl wget unzip zip \
    git build-essential cmake pkg-config extra-cmake-modules gettext texinfo ninja-build autoconf libtool automake \
    && apt autoclean && update-ca-certificates
RUN apt install -y libgl1-mesa-dev libglu1-mesa-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgtk-3-dev \
    libwebkit2gtk-4.1-dev libgstreamerd-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libmspack-dev libsecret-1-dev \
    && apt autoclean

FROM builder as AppPacker
RUN apt install -y libfuse2t64 fuse
RUN git config --system --add safe.directory '*'
```

四个关键决策：

1. **国内源替换写在 Dockerfile 里**：`sed` 把 ubuntu 官方源换成华为云。**镜像构建在国内网络下，源替换必须是 Dockerfile 的一部分，否则构建时拉包容易超时**。
2. **编译工具链一次装齐**：`build-essential`、`cmake`、`ninja-build`、`autoconf`、`libtool`、`automake`——C++ 项目可能用到的构建体系都覆盖，避免"构建到一半发现缺工具"。
3. **GUI 依赖是桌面应用的隐藏成本**：`libgtk-3-dev`、`libwebkit2gtk-4.1-dev`、`libgl1-mesa-dev` 这些是编译 wxWidgets/CEF/WebView 类应用要链接的库。**不装的话 cmake 配置阶段会报一堆 `Could NOT find GTK`**，而且是逐个报、贼难排查。一次装齐省心。

最后一行 `git config --system --add safe.directory '*'` 是 Jenkins 容器构建的经典坑（第 10 章踩坑也提过）：构建机以 root 拉代码后，git 会因为"可疑所有权"拒操作，在镜像里预置这一行，从根上解决。

## Windows 镜像：MSVC + Qt 的多阶段搭建

Windows 容器镜像比 Linux 复杂一个量级——要装 VS BuildTools（几 GB）、按参数切换 VS 版本、还要配 Qt 和 Windows SDK。真实 Dockerfile 用**五阶段**组织：

```dockerfile
ARG BASE_TAG=ltsc2022
FROM mcr.azure.cn/windows/servercore:$BASE_TAG as BaseImage
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# 阶段1 Builder：基础工具（Git/CMake/Perl/Gettext/Python，全部国内源）
FROM BaseImage AS Builder
ARG CMAKE_VERSION=3.31.0 GIT_VERSION=2.54.0
RUN Invoke-WebRequest -OutFile git.zip $Env:GIT_URL; Expand-Archive git.zip -DestinationPath 'C:\Tools\git'; ...
RUN [Environment]::SetEnvironmentVariable('PATH', ('C:\Tools\git\mingw64\bin;' + 'C:\Tools\cmake-...\bin;' + $env:PATH), 'Machine')

# 阶段2 SDKInstaller：Windows SDK 的 Debuggers（symstore 用）
FROM BaseImage AS SDKInstaller
RUN Invoke-WebRequest -OutFile winsdksetup.exe $Env:WINSDK_URL; \
    start-Process winsdksetup.exe -ArgumentList '/q /features OptionId.WindowsDesktopDebuggers' -Wait
RUN Copy-Item -Recurse 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64' c:\Debuggers

# 阶段3 QTInstaller：aqtinstall 按 MSVC 版本装 Qt
FROM BuildBase AS QTInstaller
RUN pip install aqtinstall -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple; \
    if ($env:MSVC_TARGET_VERSION -eq 17) { aqt install-qt windows desktop 6.10.2 win64_msvc2022_64 --outputdir c:/Qt } \
    else { aqt install-qt windows desktop 5.15.2 win64_msvc2019_64 --outputdir c:/Qt }

# 阶段4 VSBuildTools：最终镜像（VS + Qt + SDK）
FROM BuildBase AS VSBuildTools
RUN Invoke-WebRequest -OutFile vs_BuildTools.exe $Env:VS_BUILDTOOLS_URL; \
    start-Process vs_buildtools.exe -ArgumentList '--quiet --wait --norestart --nocache --installPath "C:\BuildTools" --add Microsoft.VisualStudio.Workload.MSBuildTools --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' -Wait
COPY --from=QTInstaller c:/Qt c:/Qt
COPY --from=SDKInstaller c:/Debuggers C:/Tools/Debuggers
RUN [Environment]::SetEnvironmentVariable('PATH', ('C:\Tools\Debuggers;' + $env:PATH), 'Machine')
RUN git config --system --add safe.directory *
```

几个"非抄不可"的点：

1. **MSVC 版本参数化**：`ARG MSVC_VERSION=16`（VS2019）或 `17`（VS2022），同一个 Dockerfile 用 `build-arg` 切换，避免维护两份几乎一样的 Dockerfile。
2. **Qt 版本跟着 MSVC 走**：VS2019 只能跑 Qt 5.15（msvc2019_64），VS2022 配 Qt 6.10（msvc2022_64）——**MSVC 和 Qt 的工具集必须配对，这是 Windows C++ 最容易踩的坑**。
3. **aqtinstall 装 Qt**：Qt 官方在线安装器要登录、要交互、还慢。`aqt install-qt windows desktop <版本> win64_msvc2019_64` 一条命令无人值守安装，镜像构建才能自动化。
4. **SHELL 切到 PowerShell**：Windows 容器默认 cmd，切到 PowerShell 且开 `$ErrorActionPreference = 'Stop'`，**任何一步失败立刻报错停掉**，否则镜像"看似构建成功实则缺组件"。
5. **SDK Debuggers 单独一个阶段再 COPY 进来**：`symstore` 只在这一层，配合 `--from=` 分层复用，VS 那几 GB 的层不会重复下载。
6. **PATH 永久生效必须 SetEnvironmentVariable 'Machine'**：普通 `$env:PATH=` 只在当前 RUN 进程有效，镜像跑起来就丢了。

## 编排：compose 一键构建 + buildkit 缓存

镜像有了，怎么构建、怎么缓存、怎么推送到私有仓库？真实项目用 docker compose（buildkit）统一管理：

```yaml
# 来源：生产 compose.yaml（脱敏）
services:
  vs2019:
    build:
      context: .
      target: VSBuildTools
      dockerfile: Dockerfile.win
      args:
        MSVC_VERSION: 16
        BASE_TAG: ltsc2022
      cache_from: [{ type: registry, ref: <registry>/msvcbuilder:cache-vs2019 }]
      cache_to:   [{ type: registry, ref: <registry>/msvcbuilder:cache-vs2019, mode: max }]
    image: <registry>/msvcbuilder:vs2019
    platform: windows

  vs2022:
    build:
      context: .
      target: VSBuildTools
      dockerfile: Dockerfile.win
      args:
        MSVC_VERSION: 17
        BASE_TAG: ltsc2025   # vs2022 与 ltsc2022 有兼容问题，必须用 ltsc2025
      cache_from: [{ type: registry, ref: <registry>/msvcbuilder:cache-vs2022 }]
      cache_to:   [{ type: registry, ref: <registry>/msvcbuilder:cache-vs2022, mode: max }]
    image: <registry>/msvcbuilder:vs2022
    platform: windows

  build-linux:
    build:
      context: .
      target: builder
      dockerfile: Dockerfile.linux
    image: <registry>/gccbuild:ubuntu
    platform: linux
```

三个设计要点：

1. **`target` 指定构建到哪个阶段**：vs2019 和 vs2022 都 `target: VSBuildTools`，但通过 `args` 传不同的 `MSVC_VERSION` / `BASE_TAG`——一份 Dockerfile 出两个镜像。
2. **buildkit registry 缓存**（`cache_from/cache_to`）：VS 镜像构建一次几十分钟，缓存层推到私有仓库，**下次构建直接复用缓存层，秒级跳过**。`mode: max` 表示缓存所有层，最省时间。这是 Windows 容器镜像构建能跑起来的核心前提。
3. **`platform: windows`**：显式声明 Windows 容器，避免在 Linux 构建机上被误当成 Linux 镜像构建。

## 踩过的坑（真实记录）

1. **vs2022 和 ltsc2022 有兼容问题**：VS2022 BuildTools 装进 ltsc2022 会失败/异常，必须用 ltsc2025——版本组合要实测，别照抄文档。
2. **PowerShell 的 `$ErrorActionPreference` 不设 = 失败静默**：Windows 容器每一步都可能"默默跳过"，SHELL 定义里必须 `Stop`。
3. **PATH 不写 Machine 级 = 镜像失效**：`$env:PATH` 只存活于当前 RUN，重启进程就没了。
4. **Git/CMake/Python 都要国内源**：`mirrors.huaweicloud.com` 下 Git、Python，清华 pypi 下 aqt——不换源，Windows 镜像构建能卡死在外网下载。
5. **`git safe.directory` 在 Windows 容器同样要配**：构建机上 checkout 的仓库属主和镜像内用户不一致时，git 拒绝操作。

## 小结

- C++ 构建镜像 = 工具链 + 依赖 + 打包工具一次固化，谁构建都是同一环境；
- Linux 镜像简单：Ubuntu + 工具链 + GUI 依赖 + AppImage 工具，多阶段拆分"构建/打包"；
- Windows 镜像复杂：VS BuildTools 参数化（16/17）+ Qt 跟 MSVC 配对 + SDK Debuggers 分层复用 + PowerShell 严格模式；
- compose + buildkit registry 缓存是 Windows 镜像能快速重建的关键，`target` + `args` 一份 Dockerfile 出多个镜像；
- 国内源替换必须写进 Dockerfile，否则构建卡死在外网。

> 延伸：镜像搭好后，怎么在流水线里引用（`agent { docker }`）、怎么从 Docker Hub/私有仓库拉取、`alwaysPull` 的坑——见第 18 章。

