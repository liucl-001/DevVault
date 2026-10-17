# 共享库函数拆解：16 个 vars/ 函数的封装之道

> 本节解决：生产工程里 9 套 Jenkinsfile，90% 的代码是重复的（清理、拉取、打包、通知、符号）——怎么抽成共享库，让所有项目流水线复用同一套骨架。

## 流水线写多了，你会发现 90% 是重复的

如果你维护过 SDK 构建、QT 应用、符号服务等多套流水线，对比一下就会发现：

- 清理环境、拉代码、归档制品、发通知——**三套代码几乎一样**；
- 变的只有核心几步：不同项目的编译命令（cmake、qmake、脚本工具链）；
- 一旦要改打包方式或通知格式，三处都要改，漏一处就行为不一致。

共享库（Shared Library）就是答案：**把公共逻辑抽到一个独立的 Git 仓库，所有流水线用 `@Library` 引用**。函数写一次，处处复用，项目 / 平台的差异收敛到参数上。

## 全景：一个共享库长什么样


```
base_lib/
└── vars/                      # 全局变量/函数，文件名即函数名
    ├── sendNotification.groovy   # 企业微信通知
    ├── zip.groovy / unzip.groovy # zip 压缩解压
    ├── compressArchive.groovy    # tar 压缩
    ├── expandArchive.groovy      # tar 解压
    ├── removeDir.groovy          # 清理目录
    ├── createSymbols.groovy      # 三平台调试符号提取
    ├── commitGit.groovy          # 制品提交回 Git
    ├── execute.groovy            # 跨平台命令执行
    ├── uploadSymbols.groovy      # 符号上传
    ├── uploadPackage.groovy      # 制品上传
    ├── artifacts.groovy          # 制品归档封装
    ├── funcTest.groovy           # 代码签名（调用签名服务器）
    ├── winSignFile.groovy        # Windows 文件签名
    └── ...
```

流水线里一行引用即可：

```groovy
@Library('base_lib@master') _;   // master 分支
```

## 核心函数拆解（按使用频率）

### 1. 通知：sendNotification

```groovy
// vars/sendNotification.groovy（脱敏）
def call(String status, String stage, String message, String robot = '<robot-id>') {
    def reportStatus = (status == 'SUCCESS') ? "✅" : "❌"
    def md = """# 【Jenkins 构建通知】
**构建配置**：${env.JOB_NAME}
**构建编号**：<font color= #FF0000>${BUILD_NUMBER}</font>
**当前分支**：${BRANCH_NAME}
**构建阶段**：${stage}
**构建状态**：${reportStatus}
**通知内容**：${message}
"""
    wxwork(robot: robot, type: 'markdown', text: [md.trim()])
}
```

设计点：**默认参数给机器人 ID**，调用方不传就用默认机器人；内容用 markdown 让企业微信显示结构化信息。`env.JOB_NAME`、`BUILD_NUMBER` 这些 Jenkins 内置变量在函数里直接可用。

### 2. 跨平台命令：execute

```groovy
// vars/execute.groovy（脱敏）
def call(String command) {
    if (isUnix()) { sh command } else { bat command }
}
```

最朴素的抽象：**`isUnix()` 判断平台，自动切 `sh`/`bat`**。流水线里写 `execute('cmake --build Build')` 一行，平台差异藏在函数里——所有项目流水线都能用。

### 3. 制品归档：artifacts

```groovy
// vars/artifacts.groovy（脱敏）
def call(String pattern) {
    archiveArtifacts artifacts: pattern, allowEmptyArchive: true, fingerprint: true
}
```

封装 `archiveArtifacts`：**`allowEmptyArchive: true`** 是关键——某些平台可能没有产物（比如某个平台构建被跳过），默认情况下空归档会直接让流水线失败，封装后统一允许空归档。

### 4. 调试符号：createSymbols（跨平台最复杂）

```groovy
// vars/createSymbols.groovy（脱敏，核心逻辑）
def call(String search_dir, String symbols_dir){
    dir(search_dir) {
        if (isUnix()) {
            if (sh(script: 'uname', returnStdout: true).trim() == 'Darwin') {
                // macOS：dwarfdump 取 UUID → dsymutil 导出 dSYM → strip -S
                // 目录结构：<uuid前2位>/<剩余uuid>.dSYM
            } else {
                // Linux：readelf 取 Build ID → objcopy --only-keep-debug → strip
                // 目录结构：<buildid前2位>/<剩余buildid>.debug
            }
        } else {
            // Windows：收集所有 pdb → symstore add 生成符号库
            // symstore add /f "*.pdb" /s <symbols_dir> /t <产品名> /v <版本>
        }
    }
}
```

这个函数是共享库价值的极致体现：**同一个函数名，内部按平台分发三套完全不同的实现**（Linux 的 Build ID、macOS 的 UUID、Windows 的 symstore）。流水线里永远只写一行 `createSymbols(installDir, symbolsDir)`，跨平台复杂度被完全封装。符号格式和目录结构详见第 19 章。

### 5. 制品提交：commitGit

```groovy
// vars/commitGit.groovy 用法（脱敏）
commitGit(
    '*.zip',                    // 文件匹配模式
    'https://<git-server>/repo.git',  // 目标仓库
    'main',                     // 目标分支
    '<credentials-id>',         // 凭证 ID
    'workspace'                 // 工作目录
)
```

把"SDK 编译产物提交回制品仓库"封装成一个函数——内部做 checkout、带认证 push、空提交判断（`git diff --cached --quiet || git commit`）。各项目流水线发布制品时调同一个函数，保证提交行为一致。

## 多个项目怎么共用同一套骨架

共享库有了，不同项目的差异怎么收敛？答案是**模板函数 + 项目参数**：

```groovy
// 通用构建模板
def buildStage(String project) {
    // 1. 清理环境（所有项目一样）
    [BUILD_DIR, INSTALL_DIR, CACHE_DIR].each { removeDir(it) }
    // 2. 拉取代码（所有项目一样）
    checkout([...])
    // 3. 核心编译（项目差异在这里）
    if (project == 'sdk')    { execute('cmake --build Build --parallel $(nproc)') }
    else if (project == 'qt') { execute('qmake app.pro && make -j$(nproc)') }
    // 4. 打包 + 符号 + 归档（所有项目一样）
    zip(INSTALL_DIR, "${CACHE_DIR}/${BUILD_NUMBER}_${project}.zip")
    archiveArtifacts artifacts: "${CACHE_DIR}/*.zip"
}
```

各项目流水线的 Jenkinsfile 就都变成这样：

```groovy
pipeline {
    agent none
    stages {
        stage('构建') {
            parallel {
                stage('SDK') { agent { label 'linux' }; steps { script { buildStage('sdk') } } }
                stage('QT')  { agent { label 'linux' }; steps { script { buildStage('qt') } } }
            }
        }
    }
}
```

**90% 的代码（清理/拉取/打包/通知/符号）来自共享库，10% 的差异（编译命令）收敛到 `buildStage` 的一个 if/else**——这就是共享库体系该有的形态。

## 最佳实践

1. **函数职责单一**：每个 vars 文件只做一个事（zip 就是 zip、通知就是通知），组合由流水线/模板完成；
2. **命名即文档**：函数名 = 文件名，`sendNotification` 一眼知道干嘛，不需要看实现；
3. **共享库单独仓库、单独版本**：`@Library('base_lib@master')` 可以锁定分支/版本，改造共享库前先想好兼容性，因为它影响所有流水线；
4. **敏感信息不写进共享库**：仓库地址、凭证 ID 用参数传入，共享库本身保持"通用"。

## 小结

- 共享库把各项目流水线的公共逻辑（清理/拉取/打包/通知/符号）抽成 `vars/` 函数，`@Library` 一行引用；
- 跨平台复杂度封装在函数内部（`execute` 切 sh/bat、`createSymbols` 分发三平台符号）；
- 项目差异收敛到一个模板函数的参数判断里，各项目 Jenkinsfile 几乎相同；
- 共享库是独立资产：单独仓库、单独版本、函数命名即文档。

> 延伸：共享库里的 `createSymbols`、`uploadSymbols` 涉及符号治理（第 10/19 章），`commitGit` 涉及制品发布链路（第 10/20 章），`funcTest`/`winSignFile` 涉及代码签名（第 19 章）——后续章节逐个展开。
