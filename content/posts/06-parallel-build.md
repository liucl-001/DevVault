---
title: "CMake并发编译三层提速"
date: 2026-10-12T22:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
summary: "/MP、--parallel、ExternalProject依赖并行，MT/MD统一"
---
# CMake 并发编译：从 /MP 到依赖并行

> 本节解决：C++ 编译慢是常态——MSVC 的 /MP、cmake --build --parallel、依赖编译并行，三个层面把编译时间压下来。

## 编译慢是 C++ 的宿命，但可以治

C++ 的编译速度从来都是痛点：一个中等规模的工程，单核编译动辄十几分钟；跨平台 SDK 还要编多个架构、多个构建类型。但大部分慢不是"代码多"，而是**没开并发**。这一节从三个层面讲并发：编译器层面（/MP）、构建系统层面（--parallel）、依赖层面（ExternalProject 并行）。

## 第一层：MSVC 的 /MP——一行配置全工程并发

Windows 上 MSVC 默认**单文件单核**编译，几十个 .cpp 串行排队，CPU 利用率惨不忍睹。`/MP` 开关让 MSVC 按 CPU 核数并行编译多个源文件：[官方文档：/MP](https://learn.microsoft.com/en-us/cpp/build/reference/mp-build-with-multiple-processes?view=msvc-170)

```cmake
if(MSVC)
    add_compile_options(/MP)
    # 或 设定一个并行度，避免资源冲突,造成更慢(当：内存受限，‌I/O 瓶颈，‌CI/CD 环境共享),eg: /MP4
    # add_compile_options(/MP4)
endif(MSVC)
```

**为什么值得专门写进 CMakeLists？** /MP[processMax] 允许更高效的资源复用和更细粒度的调度，对于大型项目效果显著。

## 第二层：cmake --build --parallel——构建系统级并发

MSVC 的 /MP 只管"一个目标内部并行"，多个目标（多个 exe/lib）之间还要靠构建系统的并发：

```bash
# Linux / macOS：按核数并行
cmake --build Build --parallel $(nproc)

# Windows：逻辑核数
cmake --build Build --parallel %NUMBER_OF_PROCESSORS%
```

流水线里（第 10 章）已经把"取核数"自动化了：Linux 用 `nproc`、macOS 用 `system_profiler` 解析、Windows 用 `wmic`/环境变量——最终都喂给同一个 `--parallel N`。**注意并行度别超过物理核数**，超了反而可能因线程上下文切换变慢。

## 第三层：依赖编译并行——ExternalProject 的并发与隔离

依赖库（用 ExternalProject 编译的三方库，见第 8 章）也可以并行，但要处理一个经典问题：**多个依赖共用同一个下载/构建目录时会互相踩**。生产实践是两个手段：

```cmake
# 1. 每个依赖独立的下载/安装目录，从根上避免互踩
ExternalProject_Add(dep_fmt
    URL <url> URL_HASH <hash>
    DOWNLOAD_DIR  ${DEPS_CACHE}/fmt        # 下载目录按依赖隔离
    INSTALL_DIR   ${DEPS_INSTALL}/fmt      # 安装目录按依赖隔离
    # ...
)

# 2. 依赖之间显式声明顺序（ADD_DEPENDENCIES 或 ExternalProject 的 DEPENDS）
ExternalProject_Add(dep_a ... )
ExternalProject_Add(dep_b DEPENDS dep_a)   # b 依赖 a 编完
```

- **目录隔离**：`DOWNLOAD_DIR`/`INSTALL_DIR` 每个依赖独立，并行构建互不干扰；
- **依赖顺序**：有依赖关系的库用 `DEPENDS` 显式声明，让 CMake 自动排先后；
- **`URL_HASH` 必须配**：锁定源码校验和，下载内容变了构建直接失败而不是静默用错版本（第 8 章展开）。

流水线层面（第 8 章）还有一层：**依赖编译结果用 `finished` 哨兵缓存**——依赖一次编完，日常构建直接跳过，这是比并行更大的时间收益。

## 附：MT/MD——比并发更隐蔽的编译坑

编译配置里有个比并发更坑的开关——**MT vs MD**（静态/动态运行时库）。两者混用会导致链接器报"重定义"或运行时崩溃，且极难排查：[官方文档：/MT](https://cmake.org/cmake/help/latest/variable/CMAKE_MSVC_RUNTIME_LIBRARY.html)

```cmake
option(ENABLE_MT "ENABLE MT" ON)
if(ENABLE_MT)
    # 一行代码搞定！
    # MultiThreaded = /MT, MultiThreadedDebug = /MTd
    # MultiThreadedDLL = /MD, MultiThreadedDebugDLL = /MDd
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif(ENABLE_MT)
```

保证**整个工程所有配置、所有模块的运行时库一致**。铁律：**一个工程内 MT/MD 必须全局统一，跨模块混用 = 灾难**。这也是为什么它值得写进 CMakeLists 而不是靠各人自觉。

## 小结

- 并发三层：`/MP`（MSVC 单目标并行，一行配置）、`--parallel N`（构建系统级并行）、ExternalProject 目录隔离 + DEPENDS（依赖并行）；
- 并行度取核数：nproc / system_profiler / wmic，流水线里自动化；
- MT/MD 必须全局统一，别混用；
- 依赖并行 + finished 缓存（第 8 章）双管齐下，编译时间从小时级压到分钟级。

> 延伸：编译提速之外，构建组织（第 5 章）、依赖管理（第 8 章）、流水线级并行（第 7 章）——完整的提速体系。

