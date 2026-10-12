# 导读：环境基线与版本说明

> 本节说明：这本小册的示例基于什么版本的环境，读者需要对应到什么程度，哪些地方版本不同会影响内容。

## 为什么要有这节

C++ 工程化涉及的软件栈很多：操作系统、编译器、CMake、Docker、Jenkins……**版本不同，命令和行为可能就不一样**。这本小册的示例基于一套真实生产环境，先把这套基线说清楚，读者照自己的环境对应，不要因为版本差异卡住。

## 示例环境基线

| 软件 | 示例版本 | 说明 |
|---|---|---|
| **操作系统** | | |
| Windows | Windows 10 or later | 需要winget(如果手动安装环境是可以更低的系统的) |
| Linux | Ubuntu 24.04（LTS） or later | 其他 Debian/Ubuntu LTS 同理 |
| macOS | macOS 14 or later | Xcode CLT、brew |
| **编译器** | | |
| MSVC | VS2019  |  这个是测试环境，实际根据需求选择 |
| GCC | GCC 13 | Ubuntu 24.04 自带 |
| Clang | Clang 15+ | Xcode CLT 自带（macOS 14+） |
| **构建工具** | | |
| CMake | CMake 3.28+ | Presets 需要 3.21+ |
| **容器** | | |
| Docker | docker.io / docker-ce | daemon.json、TCP 远程访问 |
| **CI** | | |
| Jenkins | 2.555.2-lts-jdk21 | Pipeline、Shared Library |
| JDK | 21 | Jenkins 运行需要（安装路径不要带空格） |
| **包管理** | vcpkg | gitee 镜像 |
| **版本控制** | Git | 从节点需配全局环境变量（第 4 章） |

## 怎么对应

- **操作系统**：太过时的系统可能会遇到主要软件的兼容问题，建议尽量新一些；
- **编译器**：只要支持 **C++17** 即可（正文示例锁定 C++17），具体版本号不绑定；
- **CMake**：建议 **3.21+**（Presets 语法需要）；
- **Docker / Jenkins**：LTS 版本即可，字段语法基本不变。

## 版本检测命令

以下是各软件的版本检测命令，读者可以快速确认环境是否满足要求：

```bash
# 编译器版本
gcc --version           # GCC
clang --version         # Clang (macOS/Linux)
cl.exe --version        # MSVC (需打开 Developer Command Prompt)

# 构建工具
cmake --version

# 容器
docker --version
docker compose version  # Docker Compose v2

# CI
java -version           # JDK 版本
jenkins --version       # 如果使用 jenkins-cli

# 包管理
vcpkg version

# 版本控制
git --version
```

## 常见问题 FAQ

### Q1: 编译器支持 C++17，但示例编译失败？

检查是否显式开启了 C++17 标准。本书示例统一使用：
```cmake
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
```
如果没开启，编译器可能使用了默认的老旧标准。

### Q2: CMake Presets 提示 "CMake version X.XX is less than minimum version Y.YY"？

确保 CMake 版本 >= 3.21。低于此版本不支持 Presets 语法。可以通过 `cmake --version` 确认。

### Q3: Docker 命令执行报错 "permission denied" 或 "cannot connect to Docker daemon"？

- **Linux**：检查当前用户是否在 `docker` 用户组中，`sudo usermod -aG docker $USER` 后重新登录
- **Windows**：确认 DockerCE 服务已启动

### Q4: Windows 上路径相关命令报错？

Windows 命令行对路径支持有限，建议：
- 使用 PowerShell / Git Bash / WSL 环境运行命令