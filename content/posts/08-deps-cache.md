---
title: "依赖缓存三层体系"
date: 2026-10-13T00:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
summary: "finished哨兵、源码下载缓存、CLEAN_BUILD全量开关"
---
# 依赖缓存与增量构建：把几十分钟压缩成秒

> 本节解决：C++ 依赖编译一次几十分钟，每次构建都重编就是灾难。用生产流水线（Jenkinsfile.fdm）的真实代码，讲透三层缓存体系：`finished` 哨兵、源码下载缓存、CLEAN_BUILD 全量开关。
> 相关代码以OrcaSlicer的依赖为例说明。

## 依赖编译是 C++ CI 最大的时间黑洞

前端 `npm install` 有锁文件和全局缓存，Go 有 module cache——C++ 呢？vcpkg 只是把源码拉下来，**几百个第三方库（fmt、spdlog、nlohmann-json…）要一个个现场编译**，动辄几十分钟；而且分平台、分架构、分构建类型（macOS 要编 arm64 和 x86_64 两套，每套还分 Debug/RelWithDebInfo）——缓存失效一次就是几十分钟白费。

生产流水线的依赖编译矩阵是这样的（后面会反复用到）：

```groovy
def foreachBuild(String platform, Closure call) {
    def arch_list = platform == 'macos' ? ['arm64', 'x86_64'] : ['x86_64']
    ["Debug","RelWithDebInfo"].each {buildType ->
        arch_list.each { arch ->
            call(arch, buildType)
        }
    }
}
```

**macOS 4 个组合（arm64/x86_64 × Debug/RelWithDebInfo），Linux/Windows 各 2 个**。每个组合的依赖都要编译一份——这就是为什么缓存设计必须是"按组合隔离"的。

## 缓存全景：一次构建的三个时间黑洞

```
构建开始
  │
  ├─ ① VCPKG 环境：bootstrap + 安装基础库
  │    几十分钟，只该装一次
  ├─ ② 依赖编译：deps/ 目录编源码自己的依赖（每个 架构×构建类型 一份）
  │    几十分钟 × N 个组合，日常构建应该全跳过
  └─ ③ 自身编译：源码每次变，每次都全编（不能缓存）
        ——但下载依赖源码本身也要时间，需要源码下载缓存
```

三层缓存分别对应 ① ② ③ 的三个时间黑洞。下面用真实代码逐个讲。

## 第一层：`文件` 哨兵——"装过没"用文件存在性当缓存

### VCPKG 环境（对应 ①）

```groovy
def source = "${WORKSPACE}/${env.VCPKG_ROOT_DIR}"
dir(source) {
    if (fileExists("${source}/finished")) {
        return    // 缓存命中：vcpkg 已就绪，直接跳过
    }

    if (isUnix()) {
        if (!fileExists("${source}/vcpkg")) {          // vcpkg 可执行文件不在才 bootstrap
            sh 'bash bootstrap-vcpkg.sh -disableMetrics'
        }
        def triplets = (plat == 'linux') ? ['x64-linux'] : ['arm64-osx', 'x64-osx']
        triplets.each { triplet ->
            sh "${source}/vcpkg install fmt --triplet ${triplet}"
        }
    } else {
        if (!fileExists("${source}/vcpkg.exe")) {
            bat "${source}\\bootstrap-vcpkg.bat"
        }
        bat "${source}/vcpkg.exe install fmt --triplet x64-windows"
    }

    writeFile(file: "${source}/finished", text: "1")   // 全部装完，写标记
}
```

完整处理逻辑：

1. **缓存 key = `${VCPKG_ROOT}/finished` 文件的存在性**；
2. 不存在 → 完整执行：bootstrap vcpkg（Windows 用 bat、Unix 用 sh）→ 按平台装 triplets（Linux 一套、macOS 两套、Windows 一套）→ 写 `finished`；
3. 存在 → **整段跳过**，bootstrap 和基础库安装只发生一次。

### 依赖编译（对应 ②，核心中的核心）

* `C:\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat` 是假设vs2019 buildtool安装在这里了
  
```groovy
foreachBuild(plat, { arch, buildType ->
    def build_dir = "${WORKSPACE}/${env.BUILD_DIR}/deps/${buildType}_${arch}"
    def install_dir = "${WORKSPACE}/${env.DEPS_INSTALL_DIR}/${arch}_${buildType}"
    if (fileExists("${install_dir}/finished")) {
        return    // 缓存命中：该组合已编译过，跳过
    }
    removeDir(build_dir)

    // 平台差异只在这里：Windows 必须先用 vcvars64 加载 VS 环境
    def run = isUnix()
        ? { cmd -> sh cmd }
        : { cmd -> bat "call \"C:\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat\" && ${cmd}" }

    def config_cmd = "cmake -S \"${WORKSPACE}/${env.SRC_DIR}/deps\" -B \"${build_dir}\"" +
        " -DCMAKE_BUILD_TYPE=${buildType} -DDESTDIR=\"${install_dir}\"" +
        " -DDEP_DOWNLOAD_DIR=\"${WORKSPACE}/${env.DEPS_CACHE_DIR}\" "
    if (isUnix()) {
        config_cmd += " -DCMAKE_OSX_ARCHITECTURES=${arch} -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${params.MACOS_DEPLOYMENT_TARGET} -G 'Unix Makefiles'"
    } else {
        config_cmd += " -G \"Visual Studio 16 2019\" -A x64 -T host=x64"
    }
    def build_cmd = "cmake --build ${build_dir} --config ${buildType}"

    run(config_cmd)
    run(build_cmd)

    writeFile(file: "${install_dir}/finished", text: "1")   // 该组合编译完，写标记
})
```

完整处理逻辑（**这是本节最关键的一段，逐行理解**）：

1. **按组合遍历**：`foreachBuild` 展开成 macOS 4 个组合 / Linux+Windows 各 2 个，每个组合独立处理；
2. **缓存 key = `${DEPS_INSTALL_DIR}/${arch}_${buildType}/finished`**——**粒度是架构 × 构建类型**，目录名天然隔离：`arm64_Debug`、`x86_64_RelWithDebInfo`…互不污染；
3. **miss 时**：清掉该组合的 build_dir（防残留）→ cmake 配置（关键参数见下）→ 编译 → 写 `finished`；
4. **hit 时**：整段跳过——日常构建 8 个组合全部命中，直接到源码编译。

**cmake 配置里的四个关键参数**（决定了缓存能复用）：
- `-DDESTDIR="${install_dir}"`：依赖装到哪，**install_dir 带 arch+buildType**，产物和缓存 key 一一对应；
- `-DDEP_DOWNLOAD_DIR="${WORKSPACE}/${env.DEPS_CACHE_DIR}"`：**源码下载目录全局共享**（这就是第三层，见下）；
- Windows 先 `vcvars64.bat` 再 cmake（VS 环境，第 1/10 章踩坑的实战体现）。

### 为什么 `文件` 比插件可靠

- 不依赖任何 Jenkins 插件，任何环境都能跑；
- 缓存 key 就是路径——天然按平台、架构、构建类型隔离，不会串；
- 逻辑透明：文件在 = 装过，文件不在 = 重装，谁都能看懂、出问题也好排查。

## 第二层：`DEPS_CACHE_DIR` 源码下载缓存——跨组合共享

上面依赖编译里传的 `-DDEP_DOWNLOAD_DIR` 就是这层：**deps 里的第三方源码（ExternalProject 下载）统一放 `DEPS_CACHE_DIR`，8 个组合共用一份**。

```
首次构建：macOS arm64-Debug 下载 fmt 源码 → DEPS_CACHE_DIR/fmt/
后续构建：其余 7 个组合 cmake 配置时发现 fmt 已存在 → 不再下载，直接编译
```

这解决的是**下载**这个时间黑洞：依赖要下载几十个源码包，GitHub 慢的时候光下载就十几分钟；有了共享缓存，**下载只发生一次，8 个组合复用**。这也是为什么环境清理时 `DEPS_CACHE_DIR` 绝不能被清（见第三层）。

## 第三层：环境清理 + CLEAN_BUILD——缓存什么时候失效

缓存最大的敌人是"假成功"：三方库源码更新了，但旧编译产物还躺着，新版本不生效——构建"成功"了，产物是旧的。生产环境的解法是**分层清理 + 显式全量开关**：

```groovy
// 来源：Jenkinsfile.fdm → buildStage('xxx') → stage('环境清理')
[env.INSTALL_DIR, env.DEBUG_SYMBOLS_DIR, env.BUILD_DIR, env.CACHE_DIR,
 env.VCPKG_ROOT_DIR + "/buildtrees",
 env.VCPKG_ROOT_DIR + "/packages",
 env.VCPKG_ROOT_DIR + "/downloads"
].each {subdir ->
    removeDir(subdir)                 // 每次必清
}
if(params.CLEAN_BUILD){
    removeDir(env.DEPS_INSTALL_DIR)   // 仅全量构建才清
}
```

**完整处理逻辑——每次构建什么被清、什么保留：**

| 清理对象 | 时机 | 原因 |
|---|---|---|
| 编译产物（BUILD_DIR/INSTALL_DIR/CACHE_DIR） | **每次** | 保证本次构建可复现，不留上一轮残留 |
| 调试符号（DEBUG_SYMBOLS_DIR） | **每次** | 上一轮的符号必须清，否则混淆版本 |
| vcpkg 编译缓存（buildtrees/packages/downloads） | **每次** | 三方库升级后旧编译产物会"假成功" |
| vcpkg 已装库（VCPKG_ROOT/installed） | **不清** | `finished` 已标记，重装浪费几十分钟 |
| vcpkg 源码（VCPKG_ROOT 本体） | **不清** | 代码拉取 stage 靠它存在跳过 checkout |
| 依赖安装目录（DEPS_INSTALL_DIR） | **仅 CLEAN_BUILD** | 依赖编译一次几十分钟 × 8 组合，日常必须复用 |
| 源码下载缓存（DEPS_CACHE_DIR） | **绝不清** | 下载一次跨 8 组合复用 |

三个关键认知：

1. **`finished` 不等于"依赖永远不更新"**——日常构建跳过依赖编译（快），依赖真正升级时**勾选 CLEAN_BUILD 显式失效**（稳）；
2. **每次清 vcpkg 的 buildtrees**——省空间 + 防部分三方库假成功；已装库靠 finished 保护，不受影响；
3. **DEPS_CACHE_DIR 是"只增不清"的**——源码下载缓存是纯增益，清了就白下载。

## 完整串起来：一次日常构建的缓存路径

```
构建触发（CLEAN_BUILD=false，全部命中）
  │
  ├─ 环境清理：清编译产物 + vcpkg buildtrees/packages/downloads
  │            DEPS_INSTALL_DIR 保留、DEPS_CACHE_DIR 保留
  ├─ 代码拉取：源码全新 checkout；vcpkg 源码已存在 → 跳过
  ├─ VCPKG 环境：finished 命中 → 跳过（bootstrap+基础库只装过一次）
  ├─ 依赖编译：8 个组合 finished 全命中 → 全跳过（几十分钟 → 0）
  │            源码下载 DEPS_CACHE 全命中（下载 → 0）
  ├─ 编译：每次全编（源码变了），链接 DEPS_INSTALL 产物
  │            -DCMAKE_PREFIX_PATH=DEPS_INSTALL_DIR/${arch}_${buildType}/usr/local
  ├─ 打包：BUILD_NUMBER_${plat}_binary.zip
  └─ 符号：createSymbols → *_symbols.zip
```

发版构建（CLEAN_BUILD=true）只多一步：`DEPS_INSTALL_DIR` 被清 → 依赖全重编 → 新的 finished 重新写入——之后日常构建又回到秒级。

## 缓存失效的三个场景（务必知道）

1. **依赖源码更新**：deps 仓库/三方库有更新，但 `finished` 还在 → 勾 CLEAN_BUILD 全量重编（这是唯一正式通道）；
2. **编译器/工具链升级**：镜像换了新 MSVC/GCC，旧产物 ABI 不兼容 → 同样 CLEAN_BUILD（镜像升级后第一次构建必开）；
3. **vcpkg ports 更新**：vcpkg 源码重新 checkout 后基础库版本变了 → 清 VCPKG_ROOT/finished 让基础库重装。

## 小结

- 三层缓存对应三个时间黑洞：**finished 哨兵**（VCPKG 环境 + 依赖编译，本任务幂等）→ **DEPS_CACHE_DIR 源码下载缓存**（8 个组合共享，下载只发生一次）→ **CLEAN_BUILD 全量开关**（显式失效依赖缓存）；
- 缓存 key 用路径天然隔离：`${arch}_${buildType}` 目录名保证 8 个组合互不污染；
- 分层清理是精确的：编译产物每次清（可复现）、vcpkg 编译缓存每次清（防假成功）、依赖安装保留（日常快）、下载缓存永不清（纯增益）；
- 源码编译通过 `-DCMAKE_PREFIX_PATH` 链接依赖缓存产物——缓存不是"存着好看"，是被编译真正消费的。

> 延伸：依赖怎么组织（vcpkg + deps/CMake，第 1 章）、并发构建怎么配合缓存（第 7 章）、这段 buildStage 在整条流水线的位置（第 10/20 章）。

