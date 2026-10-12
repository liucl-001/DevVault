---
title: "C++工程化实战：目录"
date: 2026-10-12T15:00:00+08:00
draft: false
series: ["C++工程化实战"]
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
summary: "从零搭建三平台C++工程化流水线：工具链→Docker→Jenkins→CMake→缓存→Pipeline实战"
---

## 系列简介

这套小册来自生产环境的真实沉淀，讲清楚一件事：**怎么给一个跨 Windows / macOS / Linux 三平台的 C++ 项目搭一套可复现、可并行、可缓存的 CI/CD 流水线。**

不是 hello world，是跑在公司 Jenkins 上的真实配置——vcpkg 依赖编译、三平台从节点、依赖缓存三层体系、调试符号归档，全部基于实际项目（OrcaSlicer 类 FDM 切片软件 SDK）脱敏而来。

## 章节列表

| 章节 | 主题 |
|---|---|
| [00 环境基线与版本说明](/posts/00-env-baseline/) | 版本锁死、环境要求、常见问题 |
| [01 三平台工具链与vcpkg](/posts/01-toolchain/) | Windows/macOS/Linux工具链、vcpkg、调试器 |
| [02 Docker环境搭建](/posts/02-docker-setup/) | 三平台Docker安装、远程访问、故障排查 |
| [03 Jenkins主节点部署](/posts/03-jenkins-master/) | JDK版本锁死、compose编排、备份 |
| [04 三平台从节点](/posts/04-jenkins-agents/) | Ubuntu/Windows/macOS从节点、SSH连接 |
| [05 最小CMake工程](/posts/05-min-cmake/) | exe/lib/test三件套宏、验证闭环 |
| [06 CMake并发编译](/posts/06-parallel-build/) | /MP、--parallel、依赖并行、MT/MD |
| [07 多平台并行构建](/posts/07-matrix-build/) | parallel vs matrix、failFast、资源控制 |
| [08 依赖缓存与增量构建](/posts/08-deps-cache/) | finished哨兵、下载缓存、CLEAN_BUILD |
| [09 Pipeline基础语法](/posts/09-pipeline-syntax/) | agent/trigger/when/credentials/错误处理 |
| [10 C++流水线实战](/posts/10-pipeline-real/) | 三平台并行、buildStage、符号处理全链路 |

## 核心思路

整条流水线的设计围绕三个杠杆：

1. **并行**：三平台同时跑，总耗时 = 最慢平台；
2. **缓存**：依赖编译一次几十分钟，日常构建靠 inished 哨兵全跳过；
3. **函数化**：三平台共用 uildStage(plat)，差异收敛在函数内部。

日常构建从小时级压到分钟级，发版构建勾 CLEAN_BUILD 保证可复现。