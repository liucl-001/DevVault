---
title: "三平台工具链与vcpkg"
date: 2026-10-12T17:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
series: ["C++工程化实战"]
weight: 1
summary: "Windows/macOS/Linux三套工具链从零配好，vcpkg包管理与调试工具选择"
---
# C++ 构建环境：三平台工具链与 vcpkg

> 本节解决：跨平台 C++ 开发的第一道坎——Windows/macOS/Linux 三套工具链怎么从零配好、包管理用什么、调试工具怎么选。

## 跨平台 C++ 的第一个敌人是"环境"

写 C++ 的人都有过这种经历：代码在 Windows 上编译通过，到 Linux 上"缺个头文件"；macOS 上链接报错，Windows 上根本不会。**C++ 不是跨平台语言，你的构建体系才是**——而构建体系的第一步，是三平台各自的工具链。

这一节把三平台工具链、包管理、调试工具一次讲清。目标是：**任何一台新机器，照着这篇 30 分钟内把 C++ 环境配好**。

## Windows：winget 一键装，两个必做的性能坑

### 用 winget 装开发环境（按自己需求选）

`winget` 是微软官方包管理器（**Windows 11 自带；Windows 10 需先手动装"应用安装程序" App Installer**）：

官方文档：[https://learn.microsoft.com/zh-cn/windows/package-manager/winget/](https://learn.microsoft.com/zh-cn/windows/package-manager/winget/)

直接执行下面命令即可：
```powershell
$progressPreference = 'silentlyContinue'
Write-Host "Installing WinGet PowerShell module from PSGallery..."
Install-PackageProvider -Name NuGet -Force | Out-Null
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null
Write-Host "Using Repair-WinGetPackageManager cmdlet to bootstrap WinGet..."
Repair-WinGetPackageManager -AllUsers
Write-Host "Done."
```

简单使用示例：

```powershell
# 搜索可用包
winget search "Visual Studio Community"
# 安装（--id 指定包，--version 指定版本）
winget install "Visual Studio Community 2026"
# 查看已装
winget list
```

开发环境通常需要这几类（按需选，版本按自己项目定，别绑定具体年份）：

- **编译器**：MSVC、Clang、GCC
- **构建工具**：cmake
- **版本控制**：git
- **编辑器 / IDE**：VS Code 或 Visual Studio（按团队习惯）
- **辅助工具**：7-Zip、Wireshark 等（可选）

msvc 是 Windows 编译的本体；命令行编译必须先进 `vcvars64.bat`（第 10 章踩坑详述）。

### 两个必做的性能坑

**坑 1：关闭 VBS / HVCI**（Windows 默认开启，会让编译/虚拟化性能掉一大截）：

```bat
bcdedit /set hypervisorlaunchtype off
```

**坑 2：装 Docker 前先开虚拟化组件**（第 2 章前置）：

```powershell
DISM /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V
DISM /Online /Enable-Feature /All /FeatureName:Containers
```


## Linux：换源 + 一键编译环境 + 调试符号

### 换国内镜像（必做，否则 apt 龟速）

```shell
# 华为云镜像（其他国内镜像同理）
sudo sed -i "s@http://.*archive.ubuntu.com@http://mirrors.huaweicloud.com@g" /etc/apt/sources.list
sudo sed -i "s@http://.*security.ubuntu.com@http://mirrors.huaweicloud.com@g" /etc/apt/sources.list
sudo apt update && sudo apt upgrade -y
```

### 装编译环境（按需选，不是全装）

```shell
# 核心编译环境（C++ 必需）
sudo apt install -y git build-essential cmake automake clang-format lldb
# 常用依赖库（按需）
sudo apt install -y libboost-all-dev
# 开发文档（可选，中文 man）
sudo apt install -y manpages manpages-zh
# IDE（可选）
sudo snap install code --classic
# 容器化（CI/CD 才需要，见第 2 章）
sudo apt install -y docker.io docker-compose
```


### 调试符号（和第 19 章呼应）

Linux 上要能调试系统库/自己的二进制，得装 dbgsym 调试符号包：

```shell
sudo apt install ubuntu-dbgsym-keyring
echo "Types: deb
URIs: http://ddebs.ubuntu.com/
Suites: $(lsb_release -cs) $(lsb_release -cs)-updates
Components: main restricted universe multiverse
Signed-by: /usr/share/keyrings/ubuntu-dbgsym-keyring.gpg" | \
sudo tee /etc/apt/sources.list.d/ddebs.sources
sudo apt update
# 按包名装对应调试符号
sudo apt install <package>-dbgsym
```

这就是第 19 章讲的"符号归档"在本地的对应物——**没有符号，崩溃现场就是一串地址**。

## macOS：brew + xcode-select

### 命令行工具（不需要整个 Xcode）

```shell
xcode-select --install
```

装完即有 Clang + lldb，足够命令行构建。

### 装 brew（国内镜像脚本）

```shell
# 国内镜像脚本
/bin/zsh -c "$(curl -fsSL https://gitee.com/cunkai/HomebrewCN/raw/master/Homebrew.sh)"
# brew安装可能会新的报错，这个时候可能需要从源码安装，有时候也会因为brew引起CMake版本问题，要特别注意
brew install cmake
```


## 包管理：vcpkg 是默认答案

C++ 没有统一的官方包管理器（不像 npm/go），生产实践里 vcpkg 是最实用的选择。

### 目录结构（知道每个目录干啥）

| 目录 | 作用 |
|---|---|
| `downloads` | 下载缓存，装包先搜这里——**备份它能省大量下载时间** |
| `installed` | 已装库的头文件和二进制（CMake / VS 集成的目标） |
| `ports` | 每个库的描述文件（版本 / 下载地址），可加自己的端口 |
| `triplets` | 各目标平台编译设置（x64-windows / x64-linux / arm64-osx...） |
| `buildtrees` | 编译中间产物（CI 里清理它省空间） |

### 三平台安装

```bash
# 通用：克隆 + bootstrap
# 国内慢用 gitee 镜像（作者维护，同步上游，会慢一些，特定包可能安装失败）：
git clone https://gitee.com/goccoder/vcpkg.git
# 或官方：git clone https://github.com/microsoft/vcpkg
cd vcpkg
./bootstrap-vcpkg.sh -disableMetrics     # Linux / macOS
bootstrap-vcpkg.bat                       # Windows（先开 VC 命令行）
```

macOS zsh 小坑：装包报 `no matches found` → 先执行 `setopt no_nomatch`。

### 搜索与安装

```bash
# 搜索库
vcpkg search curl
# 安装（指定 triplet 平台）
vcpkg install curl --triplet x64-linux
vcpkg install curl:x64-windows
# 方括号选编译选项（多个用逗号分隔）
vcpkg install curl[http2,openssl]:x64-windows
```

### 集成（CMake Presets）

用 `CMakePresets.json` 统一管理（CMake 官方推荐，跨平台普适，不用改 CMakeLists.txt）：

```json
{
  "version": 3,
  "configurePresets": [
    {
      "name": "default",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build",
      "cacheVariables": {
        "CMAKE_TOOLCHAIN_FILE": "$env{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
      }
    }
  ]
}
```

VS Code / Visual Studio / CLion 都原生支持 CMakePresets.json，打开即识别。

Windows Visual Studio 也可 `vcpkg integrate install` 自动集成（可选）。

### 缓存策略

- **downloads 目录**：装包下载的源码/工具缓存，备份它，换机 / CI 复用，省几十分钟重复下载；

### 为什么 CI 里 vcpkg 要特别处理

vcpkg 装依赖要现场编译（几十分钟），且不同 triplet 是独立编译的——这就是第 8 章"finished 哨兵缓存"和第 10 章"VCPKG 环境配置 stage"存在的根本原因。**依赖安装是 C++ CI 最大的时间黑洞，vcpkg 的缓存策略直接决定流水线快慢**。

## 调试工具：按平台选

```bash
# Linux：gdb + valgrind（内存泄漏）
gdb ./demo
valgrind --leak-check=full ./demo

# macOS：lldb + Xcode Instruments
lldb ./demo

# Windows：VS 调试器 + 远程调试（生产节点排查用）
```

调试符号治理（第 19 章）三平台也完全不同：Linux 的 `.debug`（Build ID）、macOS 的 `.dSYM`、Windows 的 `.pdb`——**崩溃现场能不能定位，取决于符号有没有归档**。这也是为什么生产流水线里符号提取是独立 stage。

## 验证环境就绪

```bash
# 三平台统一验证
cmake --version && g++ --version    # 编译器与构建工具
vcpkg list                          # 依赖可查
```

> 本节示例最低要求是 **CMake ≥ 3.21**（CMakePresets 的稳定版本门槛），读者按自己环境对应；依赖版本通过 vcpkg triplet 锁定（第 8 章详述），不在正文写死版本号。

## 踩过的坑

1. **Windows 不关 VBS，编译/虚拟化性能掉一大截**：`bcdedit /set hypervisorlaunchtype off` 一次搞定；
2. **Linux 不换源，apt 龟速**：华为云/清华镜像先 sed 替换 sources.list 再 update；
3. **Linux 调试要 dbgsym**：没装 dbgsym-keyring，gdb 看到的就是地址不是函数名；
4. **Windows 命令行编译必须先 vcvars64.bat**：直接跑 cl 会报"找不到编译器"。

## 小结

- 三平台工具链：Windows winget 一键装 + 关 VBS；Linux 换源 + 一键编译环境 + dbgsym；macOS brew + xcode-select；
- 包管理用 vcpkg：triplet 分平台、CMake 工具链集成、CI 缓存策略决定流水线快慢；
- 调试工具按平台选，但符号归档（Build ID/dSYM/PDB）是跨平台的统一需求；
- 环境就绪验证：编译器 + vcpkg 一条命令过。

> 延伸：环境就绪后，第 5 章验证最小工程、第 6 章并发编译、第 14 章把环境固化进镜像——环境问题从"每台机器"变成"一个镜像"。

