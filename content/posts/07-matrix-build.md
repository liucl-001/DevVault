---
title: "parallel与matrix怎么选"
date: 2026-10-12T23:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
series: ["C++工程化实战"]
summary: "三平台并行构建，failFast策略与资源控制"
---
# 多平台并行构建：parallel 与 matrix 怎么选

> 本节解决：C++ 项目的多平台构建怎么提速——parallel（手动并行）与 matrix（矩阵组合）两种写法的区别、failFast 要不要开、资源怎么控制。


## 三平台串行构建 = 把一天浪费在等待上

一个跨平台 C++ 项目，Windows/macOS/Linux 三个平台各自独立编译——如果串行跑，一次构建的耗时是三个平台之和，动辄一两个小时起步；而且三平台互相不依赖，串行纯粹是浪费时间。**并行是 C++ 跨平台 CI 的第一杠杆**：三平台同时开跑，总耗时约等于最慢的那个平台。

Jenkins 声明式 Pipeline 提供两种并行写法：`parallel` 和 `matrix`。这一节把两者的区别、选型和资源控制讲透。

## 写法一：parallel——手动并行，平台差异显式写

```groovy
stage('并发构建') {
    failFast true   // 一个平台失败，其余全部终止
    parallel {
        stage("MacOS 构建") {
            agent { label 'macos' }
            stages { stage('构建') { steps { script { buildStage('macos') } } } }
        }
        stage("Windows 构建") {
            agent { docker { image '<registry>/msvcbuilder:vs2022' } }
            stages { stage('构建') { steps { script { buildStage('windows') } } } }
        }
        stage("Linux 构建") {
            agent { docker { image '<registry>/gccbuilder:ubuntu' } }
            stages { stage('构建') { steps { script { buildStage('linux') } } } }
        }
    }
}
```

`parallel` 的特点：**每个分支完全独立声明**——agent 不同、stage 不同、逻辑可以完全不同。它适合平台差异大的场景（macOS 用物理节点、Windows 用容器、Linux 用容器，agent 都不一样，只能手动写）。

## 写法二：matrix——矩阵组合，同构任务自动展开

```groovy
// 来源：生产部署素材（脱敏）
stage('并发构建') {
    matrix {
        axes {
            axis { name 'PLATFORM'; values 'windows', 'macos', 'linux' }
        }
        agent { label "${PLATFORM}" }
        options { timeout(time: 600, unit: 'MINUTES') }
        stages {
            stage("构建") {
                steps { script { buildStage("${PLATFORM}") } }
            }
        }
    }
}
```

`matrix` 的特点：**定义一个轴（axis），Jenkins 自动为每个取值生成一个并行分支**。它适合"同构"场景——所有平台跑同一套逻辑，只有轴变量不同（平台名、架构、构建类型）。一个轴就是一层循环：`['windows','macos','linux']` 自动展开成三个并行 stage。

## 对比：怎么选

| 维度 | parallel | matrix |
|---|---|---|
| 适用场景 | 平台差异大、逻辑各不相同 | 平台同构、只是参数不同 |
| agent 指定 | 每个分支独立指定 | 统一用轴变量引用（`label "${PLATFORM}"`） |
| 多轴组合 | 手动嵌套 | 天然支持多轴（平台 × 架构 × 构建类型） |
| 代码量 | 平台越多越长 | 与平台数无关，只加轴取值 |
| 可读性 | 直观但冗长 | 紧凑但间接 |

实战建议：**你的平台差异大（agent 方式都不同）用 parallel；平台同构（比如都是 docker agent、只换镜像名）用 matrix**。生产里更常见的是两者混用：外层 parallel 放差异大的平台，内层用 matrix/循环展开架构 × 构建类型（见第 10 章的 `foreachBuild`）。

## failFast：要不要一个挂全部停

```groovy
failFast true   // 一个分支失败，立即终止其余分支
```

- **开（failFast true）**：三平台任一失败，立即 kill 其他两个。省资源，但**可能浪费已完成的工作**——比如 macOS 已编译 40 分钟就差打包，Linux 在第 5 分钟失败，macOS 的 40 分钟白费；
- **关（默认）**：失败的分支标记失败，其余分支继续跑完。不浪费已投入的计算，但失败后其他平台还会占着 agent 跑。

生产里的现实选择：**三平台构建都很慢时，默认关**（不互相拖累，让每个平台跑完拿到完整产物）；**构建快、依赖少时开**（早点止损）。第 10 章生产流水线把 `failFast true` 注释掉，就是这个考量——没有绝对正确，取决于你的机器资源和构建时长。

## 资源控制：并行是双刃剑

并行越快，资源占用越猛。三个控制手段：

```groovy
// 1. 超时保护：单个矩阵组合最长跑多久
options { timeout(time: 120, unit: 'MINUTES') }

// 2. 并发上限：同一任务最多几个并行分支
//    （Jenkins 全局配置：Manage Jenkins → 节点限制，或用 Lockable Resources 插件）

// 3. 构建历史保留：磁盘保护
options { buildDiscarder(logRotator(numToKeepStr: '10')) }
```

- **`timeout`**：多平台构建最容易"卡死一个平台拖死全部"，超时保护是底线；
- **并发上限**：并行分支数和可用 agent 数要匹配——8 个并行分支但只有 3 台构建机，其他 5 个会排队等 agent，并行变成假并行；
- **构建保留**：每个平台归档一份产物，构建次数多了磁盘涨得飞快，`buildDiscarder` 必须配。

## 踩过的坑（真实记录）

1. **并行分支共享 workspace 会互相踩**：`parallel` 分支默认在**不同 agent** 上跑（各自 workspace），但如果在同一 agent 上并行，必须用 `workspace` 指令或显式区分目录，否则两个分支写同一个文件互相覆盖；
2. **matrix 的轴变量是字符串**：`agent { label "${PLATFORM}" }` 里 `${PLATFORM}` 引用轴值，注意引号——Jenkins 会把轴值当字面量，拼错标签名直接无节点可用；
3. **并行不增加 agent 数**：并行只"发起任务"，真正同时跑多少取决于可用 agent。想提速，先加构建机或给节点配 docker。

## 小结

- 并行是跨平台 CI 的第一杠杆：三平台同时跑，总耗时 = 最慢平台；
- `parallel` 适合平台差异大（agent 各不同），`matrix` 适合同构场景（轴变量驱动），可混用；
- `failFast` 开/关取决于构建时长与资源：慢构建默认关，快构建可开；
- 资源控制三件套：timeout 超时保护、并发上限匹配 agent 数、buildDiscarder 防磁盘打满。

> 延伸：并行构建的产物怎么统一归档（第 10 章）、依赖怎么跨平台复用缓存（第 8 章）、并行里每路构建函数怎么写（第 10 章）。

