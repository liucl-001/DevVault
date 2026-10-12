---
title: "C++ SDK流水线实战拆解"
date: 2026-10-13T12:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
series: ["C++工程化实战"]
summary: "三平台并行、buildStage函数、依赖缓存、符号处理全链路"
---
# C++ 流水线实战：一套扛住三平台的 Pipeline

> 本节解决：C++ 项目的 Jenkins 流水线到底怎么组织——多平台并行、依赖编译、调试符号、制品提交，一条完整链路拆给你看。
> 完整流水线来自作者生产环境（私有），本节展示脱敏后的核心片段；全文代码基于真实运行版本。

## 为什么 C++ 的流水线比想象的难

前端流水线很简单：`npm install && npm run build`，产物一个目录，扔到 CDN 完事。后端也类似：编译、打镜像、发布。但 C++ 不一样——

- **一个产物要跨 Windows / macOS / Linux 三个平台**，每个平台的编译器、依赖、打包方式完全不同；
- **依赖要自己编译**：vcpkg 只是拉源码，几百个第三方库（fmt、spdlog、nlohmann-json…）要一个个编出来，还得分架构、分构建类型；
- **调试符号要单独处理**：Linux 的 Build ID、macOS 的 dSYM、Windows 的 PDB，格式完全不一样；
- **产物要回写仓库**：SDK 编完后要提交到 SDK 仓库，再触发下游应用构建。

所以一条 C++ 流水线动辄十几个 stage、几百行。网上教程教的是 hello world，真实项目里你大概率抄不到能用的。这一节，我们把一条在生产环境跑着的 C++ SDK 流水线完整拆开。

## 全景：一条 C++ SDK 流水线的完整骨架

```
GitLab Webhook 触发
    ↓
[构建环境检查] 分支校验，master 才放行
    ↓
[并发构建] ──┬── MacOS 构建（arm64+x86_64 × Debug/RelWithDebInfo）
             ├── Linux 构建
             └── Windows 构建（vs2019）
    ↓ 三平台全部成功
[统一提交仓库] commitGit 提交制品到 SDK 仓库
    ↓
[下游触发] 触发应用构建 + PDB 符号入库
```

设计要点：**并行在主流水线，单路构建抽成函数**。这样三平台共享同一套构建逻辑，只通过参数区分平台差异。

## 核心片段一：多平台并行（parallel）

流水线入口用 `agent none`——顶层不占任何节点，让每个并行分支各自选 agent：

```groovy
@Library('base_lib@master') _;
pipeline {
    agent none
    triggers {
        GenericTrigger(
            token: '<webhook_token>',
            causeString: 'Triggered by GitLab WebHook',
            genericVariables: [
                [key: 'BRANCH_NAME', value: '$.ref', regexpFilter: 'refs/heads/'],
                [key: 'GIT_REPO',     value: '$.project.http_url']
            ]
        )
    }
    environment {
        BUILD_DIR = 'Build'
        INSTALL_DIR = 'Install'
        CACHE_DIR  = 'CACHE'
    }
    parameters {
        string(name: 'BRANCH_NAME', defaultValue: 'master', description: 'SDK分支名称')
        booleanParam(name: 'CLEAN_BUILD', defaultValue: false,
            description: '清洁编译，开这个编译时间非常长，想好再点')
    }
    stages {
        stage("构建环境") {
            steps { script {
            } }
        }
        stage('并发构建') {
            when { expression { currentBuild.currentResult != 'ABORTED' } }
            // failFast true  // 一个平台失败，其余全部终止（默认不开启）
            parallel {
                stage("MacOS 构建") {
                    agent { label 'macos' }
                    stages { stage('开始构建') { steps { script { buildStage('macos') } } } }
                }
                stage("Linux 构建") {
                    agent { label 'linux' }
                    stages { stage('开始构建') { steps { script { buildStage('linux') } } } }
                }
                stage("Windows 构建") {
                    agent { label 'windows && vs2019' }
                    // 也可以换成 docker agent，见第 18 章：
                    // agent { docker { image '<registry>/msvcbuilder:vs2019' } }
                    stages { stage('开始构建') { steps { script { buildStage('windows') } } } }
                }
            }
        }
        stage('统一提交仓库') {
            agent { label 'linux' }
            when {
                beforeAgent true
                expression { currentBuild.currentResult == 'SUCCESS' }
            }
            steps { script {
                commitGit("${env.CACHE_DIR}/*_binary.zip",
                          params.SDK_GIT_REPO, params.SDK_BRANCH_NAME,
                          params.CREDENTIALS_ID, "${WORKSPACE}/<sdk_dir>")
            } }
        }
    }
    post {
        success {
            build(job: '<pdb_commit_job>',
                parameters: [string(name: 'UPSTREAM_BUILD_NUMBER', value: "${BUILD_NUMBER}")],
                wait: false)
        }
    }
}
```

**为什么这么设计：**

- `agent none` 顶层不占节点：`parallel` 三个分支跑在不同机器上，顶层如果指定 agent，会白白占用一台机器等全部跑完；
- 分支校验放在最前：不是 master 直接 `ABORTED`，避免浪费三台机器资源。用 `when { expression }` 而不是 `if` 写在 stage 里，是 Jenkins 推荐的条件跳过方式；
- Windows 用 `label 'windows && vs2019'` 而非 docker：**签名和证书依赖本机环境**（见第 17 章），容器里做签名要额外处理凭证链路，得不偿失。这是实战取舍，在使用docker的情况下，windows的整体性能非常低，低到不可接受！
- `failFast true` 默认注释掉：三平台编译都很慢，一个平台挂了直接终止可能浪费另两台已完成的工作，是否 failFast 取决于你的机器资源。这里选择"不互相拖累"。但有一场景需要一起失败就开启

## 核心片段二：单路构建函数 buildStage

三个平台共用一套构建逻辑，差异用 `plat` 参数区分。这是整条流水线的心脏：

```groovy
// 按平台执行单路构建
def buildStage(String plat) {
    stage('环境清理') {
        script {
            [env.INSTALL_DIR, env.DEBUG_SYMBOLS_DIR, env.BUILD_DIR, env.CACHE_DIR,
             env.VCPKG_ROOT_DIR + "/buildtrees", env.VCPKG_ROOT_DIR + "/packages",
             env.VCPKG_ROOT_DIR + "/downloads"].each { subdir ->
                removeDir(subdir)
            }
            if (params.CLEAN_BUILD) {
                removeDir(env.DEPS_INSTALL_DIR)   // 全量重编依赖（非常耗时）
            }
        }
    }
    stage('代码拉取') {
        script {
            dir(env.SRC_DIR) {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: params.BRANCH_NAME]],
                    extensions: [cleanBeforeCheckout(deleteUntrackedNestedRepositories: true)],
                    userRemoteConfigs: [[url: params.GIT_REPO, credentialsId: params.CREDENTIALS_ID]]
                ])
                
            }
            // vcpkg 不存在才 clone（复用已有工具链）
            def filename = isUnix() ? "${env.VCPKG_ROOT_DIR}/vcpkg" : "${env.VCPKG_ROOT_DIR}/vcpkg.exe"
            if (!fileExists(filename)) {
                dir(env.VCPKG_ROOT_DIR) {
                    checkout([... url: env.VCPKG_GIT_REPO ...])
                }
            }
        }
    }
    stage('VCPKG环境配置') {
        // bootstrap + 按 triplet 安装依赖（fmt/nlohmann-json/spdlog）
        // 安装完成写 finished 标记文件，下次直接跳过 —— 见【核心片段三】
    }
    stage('依赖编译') {
        // cmake -S deps -B build -DCMAKE_BUILD_TYPE=... 
        // 内部库通过 ExternalProject 拉取编译（详见第 8 章）
        // Windows 下必须先 call vcvars64.bat 再执行 cmake
    }
    stage('编译') {
        // cmake -S src -B build --target install
        // 并行度：Linux nproc / macOS system_profiler 核数 / Windows wmic 取逻辑核
        // 详见下方【并发编译的核数检测】
    }
    stage('打包构建结果') {
        script {
            def zipfilename = "${WORKSPACE}/${env.CACHE_DIR}/${BUILD_NUMBER}_${plat}_binary.zip"
            zip(env.INSTALL_DIR, zipfilename)
        }
    }
    stage('调试符号处理') {
        // 三平台符号格式完全不同，createSymbols 内部按平台分发
        // Linux: readelf Build ID → objcopy 分离 .debug
        // macOS: dwarfdump UUID → dsymutil 导出 dSYM
        // Windows: symstore 收集 PDB（详见第 19 章）
        createSymbols(env.INSTALL_DIR, env.DEBUG_SYMBOLS_DIR)
        zip(env.DEBUG_SYMBOLS_DIR, "${WORKSPACE}/${env.CACHE_DIR}/${BUILD_NUMBER}_${plat}_symbols.zip")
        removeDir(env.DEBUG_SYMBOLS_DIR)
    }
}
```

**为什么这么设计：**

- **环境清理删掉 vcpkg 的 buildtrees/packages/downloads**：这三处是 vcpkg 的编译缓存，不删会导致上一轮编译的残留污染本轮（比如三方库升级后仍用旧产物）。但注意**只删这三处、不删 `installed`**——`installed` 是已编译好的依赖产物，保留能极大加速（这就是"增量"与"干净"的平衡点）；`CLEAN_BUILD` 才是全量开关，默认关；
- **`finished` 标记文件**（VCPKG 配置和依赖编译 stage 都有）：编译前检查标记，存在就跳过整个 stage。这是 Jenkins 里最朴素的缓存机制——比插件可靠、比插件透明。文件写在哪、命名怎么定，就是你的缓存 key；
- **`cleanBeforeCheckout(deleteUntrackedNestedRepositories: true)`**：C++ 工程常带 submodule 或嵌套 git 仓库，这个参数确保拉代码时把嵌套仓库也清干净，否则会出现"拉不下来/旧文件残留"的玄学问题。

## 核心片段三：依赖缓存——`finished` 标记 + arch×buildType 矩阵

```groovy
// 遍历架构 × 构建类型（macOS 双架构，其余单架构）
def foreachBuild(String platform, Closure call) {
    def arch_list = platform == 'macos' ? ['arm64', 'x86_64'] : ['x86_64']
    ["Debug", "RelWithDebInfo"].each { buildType ->
        arch_list.each { arch -> call(arch, buildType) }
    }
}

// 依赖编译 stage 内：
def build_dir = "${WORKSPACE}/${env.BUILD_DIR}/deps/${buildType}_${arch}"
def install_dir = "${WORKSPACE}/${env.DEPS_INSTALL_DIR}/${arch}_${buildType}"
if (!fileExists("${install_dir}/finished")) {   // ← 缓存判断
    removeDir(build_dir)
    cmake -S deps -B build_dir -DCMAKE_BUILD_TYPE=${buildType} -DDESTDIR="${install_dir}" ...
    cmake --build build_dir --config ${buildType}
    writeFile(file: "${install_dir}/finished", text: "1")   // ← 标记完成
}
```

**为什么这么设计：**

- **缓存粒度是"架构 × 构建类型"**：macOS 要编 arm64 和 x86_64 两套，Debug 和 RelWithDebInfo 又是两套，所以目录名 `${arch}_${buildType}`、标记文件放 `${install_dir}/finished`——缓存 key 就是目录路径，天然隔离，不会串；
- **`CLEAN_BUILD` 参数**：普通构建只清 SDK 自己的构建目录，依赖 `finished` 在就跳过；想全量重编才开 `CLEAN_BUILD` 清掉 `DEPS_INSTALL_DIR`。这样"日常构建快、发版构建稳"两个目标都满足。

## 核心片段四：并发编译的核数检测（三平台写法）

```groovy
// Linux / macOS：
number=\$(nproc)                                  // Linux
number=\$(system_profiler SPHardwareDataType | grep "Total Number of Cores" | awk '{print \$5}')  // macOS
cmake --build ${build_dir} --config ${buildType} --parallel \${number}

// Windows：
for /f "skip=1 tokens=2 delims==" %a in ('wmic cpu get NumberOfLogicalProcessors /value') do set cpu=%a
cmake --build ${build_dir} --config ${buildType} --parallel %cpu%
```

`cmake --build --parallel N` 会把编译任务分发到 N 个核上。三个平台取核数的方式完全不同（`nproc` / `system_profiler` / `wmic`），但最终都喂给同一个 `--parallel`。**这就是 C++ 流水线"同一抽象、三份实现"的典型切片**。

## 踩过的坑（真实记录）

1. **Windows 必须先 `call vcvars64.bat` 再执行 cmake/bat**：不加载 VC 环境变量，`cl.exe`、`rc.exe` 全找不到，报的错却五花八门，最容易误导排查方向；
2. **`git config --global --add safe.directory '*'`**：Jenkins 以服务账号 checkout 后，git 会因"可疑所有权"拒绝操作，不加这句直接报 `detected dubious ownership`；
3. **vcpkg 缓存不清理会"假成功"**：三方库源码更新后，buildtrees 里的旧编译产物会让新版本不生效，这就是环境清理 stage 必须存在的原因。

## 小结

一条 C++ 流水线的核心不是语法，而是**组织方式**：

- 顶层 `agent none` + `parallel` 三平台并行，单路构建抽成 `buildStage(plat)` 函数；
- 依赖用 `finished` 标记做缓存，缓存粒度是"架构 × 构建类型"，`CLEAN_BUILD` 做全量开关；
- 三平台差异（编译器环境、核数检测、sed 语法、符号格式）收敛在函数内部，主流水线保持干净；
- 产物命名带 `BUILD_NUMBER` 和平台名，符号单独归档，最后统一提交制品并触发下游。

到这里，一条 C++ SDK 流水线的主体已经成型。流水线能跑起来之后，下一步是把它拆干净——下一节（第 11 章）我们看生产工程里的共享库：怎么用 Groovy 把公共逻辑封装成函数，让 9 套流水线复用同一套代码。

