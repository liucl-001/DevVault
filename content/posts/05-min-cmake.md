---
title: "最小CMake工程验证环境"
date: 2026-10-12T21:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
summary: "exe/lib/test三件套宏，配置→编译→测试→安装→运行闭环"
---
# 构建环境验证：从零跑通第一个 CMake 工程

> 本节解决：环境搭好后（第 1-4 章），怎么快速验证它真的能用——一套 exe/lib/test 分离的 CMake 工程骨架，从零建起、一次跑通。


## 环境搭好了，怎么知道"能用"

第 1-4 章我们搭好了 C++ 工具链、Docker、Jenkins 主从节点——但"装好了"不等于"能用"。验证环境最快的方式：**从零建一个最小 CMake 工程，编译、运行、出产物**。如果这一步 10 分钟内跑通，说明工具链、CMake、依赖管理全部就位，后面的流水线才有意义。

这一节给一套生产沉淀的工程骨架：**exe / lib / test 三类目录用宏自动生成工程**，这是后面所有 C++ 章节的地基。

## 第一步：全局基础配置

`CMakeLists.txt` 顶部是一套必配的基础设施：

```cmake
cmake_minimum_required(VERSION 3.8.1)

# vcpkg 集成：设置了 VCPKG_ROOT 就用 vcpkg 工具链（必须在 project 之前！）
if(DEFINED ENV{VCPKG_ROOT} AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" CACHE STRING "")
endif()
project(demo CXX C)    # project 必须在 vcpkg 配置之后

# 默认 Debug 构建（没指定时，防止生成空的构建类型）
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "default set build type Debug" FORCE)
endif()

# 锁 C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 输出目录统一：bin 放可执行/DLL，lib 放静态库
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/${CMAKE_BUILD_TYPE}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/${CMAKE_BUILD_TYPE}/lib)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/${CMAKE_BUILD_TYPE}/bin)

# VS 工程分组
set_property(GLOBAL PROPERTY USE_FOLDERS On)
```

几个"非抄不可"的细节：

- **vcpkg 工具链必须在 `project()` 之前设置**——放后面，`find_package` 找不到 vcpkg 装的库，报错还难排查；
- **默认 Debug**：开发环境没指定构建类型时，CMake 会生成空字符串类型，产物路径全是 `bin/`（没子目录），多配置下容易乱——强制默认 Debug 后路径里带构建类型；
- **输出目录三分**：`bin`（可执行 + Windows DLL）、`lib`（静态库/导入库）——Windows 的 DLL 属于 "runtime"，不分开的话 DLL 和 exe 混在一个目录，部署时还得自己找。

## 第二步：三件套宏——exe / lib / test

生产工程的核心套路是三个宏，把"加一个模块"缩成一行：

```cmake
# ---- 可执行程序 ----
# 自动收集子目录下所有 .h/.cpp/.rc，支持链接库、VS 工程分组、统一 install 规则
macro(add_subdirExe dir)
    cmake_parse_arguments(P_ARGS "" "PNAME;LIBRARY;GROUP" "ARGS" ${ARGN})
    file(GLOB_RECURSE HDRS_G "${dir}/*.h*")
    file(GLOB_RECURSE SRCS_G "${dir}/*.cpp")
    file(GLOB_RECURSE RCS_G  "${dir}/*.rc")
    add_executable(${P_ARGS_PNAME} ${HDRS_G} ${SRCS_G} ${RCS_G})
    if(P_ARGS_LIBRARY)
        target_link_libraries(${P_ARGS_PNAME} ${P_ARGS_LIBRARY})
    endif()
    if(P_ARGS_GROUP)
        set_target_properties(${P_ARGS_PNAME} PROPERTIES FOLDER ${P_ARGS_GROUP})
    endif()
    INSTALL(TARGETS ${P_ARGS_PNAME}
        RUNTIME DESTINATION bin/  LIBRARY DESTINATION lib/  ARCHIVE DESTINATION lib/)
endmacro()

# ---- 库（静态/动态）----
# 自动收集源文件、按类型建库、头文件统一安装到 include/<subname>/
# 动态库场景：Windows 上需要导出宏（本模板默认 STATIC，导出宏见注释）
macro(add_subdirLibrary dir)
    cmake_parse_arguments(P_ARGS "" "PNAME;TYPE;GROUP" "" ${ARGN})
    file(GLOB_RECURSE HDRS_G "${dir}/*.h*")
    file(GLOB_RECURSE SRCS_G "${dir}/*.cpp")
    add_library(${P_ARGS_PNAME} ${P_ARGS_TYPE} ${HDRS_G} ${SRCS_G})
    # PUBLIC 传播 include 根：链接方自动获得 <模块名/xx.h> 的查找路径
    # （子目录约定：src/<模块名>/xx.h，include 根是 src/）
    target_include_directories(${P_ARGS_PNAME} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
    if(NOT P_ARGS_TYPE STREQUAL "STATIC")
        # 动态库：Windows 上生成导出宏（示例）：
        # target_compile_definitions(${P_ARGS_PNAME} PRIVATE ${P_ARGS_PNAME}_BUILD_DLL)
        # 头文件里： #if defined(${P_ARGS_PNAME}_BUILD_DLL) #define API __declspec(dllexport)
        #           #else #define API __declspec(dllimport) #endif
    endif()
    if(P_ARGS_GROUP)
        set_target_properties(${P_ARGS_PNAME} PROPERTIES FOLDER ${P_ARGS_GROUP})
    endif()
    INSTALL(TARGETS ${P_ARGS_PNAME}
        RUNTIME DESTINATION bin/  LIBRARY DESTINATION lib/  ARCHIVE DESTINATION lib/)
    INSTALL(DIRECTORY "${dir}/"
            DESTINATION include/${dir}
            FILES_MATCHING PATTERN "*.h*")
endmacro()

# ---- 测试可执行 ----
# 默认零外部依赖（测试文件自带 main + assert），ctest 一键跑。
# 要切换 GTest：见 README「启用 GTest」与 cmake/deps.cmake。
if(${CMAKE_BUILD_TYPE} STREQUAL "Debug")
    option(ENABLE_TEST "TEST project build" OFF)
else()
    set (ENABLE_TEST OFF)
    message("google test only support Debug")
endif()
macro(add_subdirTEST subname)
    if(ENABLE_TEST)
		find_package(GTest REQUIRED)
		INCLUDE_DIRECTORIES(${GTEST_INCLUDE_DIRS})
	
		include_directories(
			${CMAKE_CURRENT_BINARY_DIR}/${subname}
			${CMAKE_CURRENT_SOURCE_DIR}/${subname}
			)

        file(GLOB_RECURSE HDRS_G "${CMAKE_CURRENT_SOURCE_DIR}/${subname}/*.h*" )
        file(GLOB_RECURSE SRCS_G "${CMAKE_CURRENT_SOURCE_DIR}/${subname}/*_Test.cpp" )
        file(GLOB_RECURSE OtherSRC_G "${CMAKE_CURRENT_SOURCE_DIR}/${subname}/*cpp" )
        foreach(item ${SRCS_G})
            list(REMOVE_ITEM OtherSRC_G ${item})
        endforeach(item)

        foreach(FILE ${SRCS_G})
            STRING(REGEX REPLACE ".+/(.+)\\..*" "\\1" SUB_NAME ${FILE})
            add_executable(${SUB_NAME} ${FILE} ${OtherSRC_G})
            target_link_libraries(${SUB_NAME} ${GTEST_BOTH_LIBRARIES} ${ARGN})
            set_target_properties(${SUB_NAME} PROPERTIES FOLDER "Test")
        endforeach(FILE)
    endif(ENABLE_TEST)
endmacro()

```

配套的 `add_subdirLibrary`（生成导出头、隐藏符号可见性）和 `add_subdirTEST`（自动找 `*_Test.cpp` 生成 GTest 可执行）结构相同，只改 `add_executable` 为 `add_library`/GTest 链接。工程里加一个新模块就是一行：

```cmake
add_subdirExe(app      PNAME app      GROUP execute)
add_subdirLibrary(core  PNAME core    TYPE STATIC GROUP libs)
add_subdirTEST(core_test)
```

三个宏解决的问题：**模块目录约定 + 自动收集源文件 + install 规则统一**——新模块快速配置加入构建。

## 第三步：验证清单（环境是否就绪的验收标准）

按顺序执行，全过 = 环境就绪：

```bash
# 1. 配置生成（应该看到 vcpkg 工具链 + 默认 Debug 的消息）
cmake -S . -B Build

# 2. 编译（看到所有目标，无报错）
cmake --build Build

# 3. 运行测试（GTest 全绿）
ctest --test-dir Build

# 4. 安装产物（bin/lib/include 齐全）
cmake --install Build --prefix Install

# 5. 产物可执行（直接运行出结果）
./Install/bin/demo
```

第 5 步是整个工程化体系的"最小闭环"：**配置 → 编译 → 测试 → 安装 → 运行**。这五步跑通，后续流水线里的 `buildStage`（第 10 章）才有意义——它本质上就是执行这几条命令。

## 小结

- 验证环境最快的方式：从零建最小 CMake 工程，跑通"配置→编译→测试→安装→运行"闭环；
- 全局配置四个要点：vcpkg 工具链在 project 前、默认 Debug、C++17、输出目录三分（bin/lib）；
- 三件套宏（exe/lib/test）让新模块一行接入，工程骨架统一；
- 验证清单五步全过 = 工具链、CMake、依赖管理全部就绪。

> 延伸：骨架有了，怎么并发编译提速（第 6 章）、怎么管理依赖缓存（第 8 章）、怎么把这套命令搬上流水线（第 10 章）——下一节讲编译提速。
