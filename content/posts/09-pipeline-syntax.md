---
title: "Jenkins Pipeline语法速查"
date: 2026-10-13T01:00:00+08:00
draft: false
tags: ["C++", "CI/CD", "CMake", "Jenkins", "Docker"]
summary: "agent/trigger/when/credentials/错误处理一套语法"
---
# Pipeline 基础：把构建流程写成代码

> 本节解决：Jenkins 的声明式 Pipeline 到底怎么组织——骨架、agent、触发器、条件、Git 操作、错误处理，一套语法一次讲清。


## Pipeline 骨架：一个块搞定所有

```groovy
// 导入共享库（下划线 = 导入所有全局变量）
@Library('base_lib@master') _;

pipeline {
    agent none                       // 代理配置
    environment { /* 全局环境变量 */ }
    parameters { /* 流水线参数 */ }
    triggers { /* 触发器 */ }

    stages {
        stage('阶段') { steps { /* 步骤 */ } }
    }

    post {
        success { /* 成功后 */ }
        failure { /* 失败后 */ }
        always  { /* 总是执行 */ }
    }
}
```

骨架的五块拼图：

| 块 | 作用 | 关键点 |
|---|---|---|
| `agent` | 在哪台机器/容器跑 | `none` 表示顶层不占节点，由各 stage 自己指定 |
| `environment` | 全局环境变量 | 路径类常量放这里（BUILD_DIR/CACHE_DIR） |
| `parameters` | 构建参数 | 给默认值，Webhook 不传参也能手动构建 |
| `stages` | 构建阶段 | 从上到下顺序执行，任一失败即中断 |
| `post` | 收尾逻辑 | 无论成败都执行，success/failure 分支处理 |

`@Library` 是共享库的入口——把公共函数（打包、通知、符号提取）抽到独立仓库，所有流水线复用。具体见第 12 章。

## agent：构建跑在哪

```groovy
// 节点标签组合（同时满足）
agent { label 'linux && docker' }
agent { label 'macos' }

// Docker 容器（环境即代码）
agent {
    docker {
        label 'linux && docker'
        image '<registry>/gccbuild:ubuntu'   // 镜像来自私有仓库
        alwaysPull true                        // 每次构建拉最新镜像
    }
}
```

两个要点：

1. **标签是组合不是单个**：`linux && docker` 表示"既是 linux 节点又装了 docker"——节点可以打多个标签（macos、vs2019、sign），用 `&&`/`||` 精确挑选。
2. **`alwaysPull true` 必须显式开**：默认情况下 agent 会复用节点上已存在的镜像，镜像更新后行为不一致；显式 `alwaysPull` 保证每次都用最新。

## triggers：谁来触发构建

```groovy
triggers {
    // GitLab WebHook 触发（最常用）
    GenericTrigger(
        token: '<webhook_token>',              // 与 GitLab 里配置的 token 一致
        causeString: 'Triggered by GitLab',
        genericVariables: [
            [key: 'BRANCH_NAME', value: '$.ref', regexpFilter: 'refs/heads/'],      // 从 Webhook JSON 取分支名
            [key: 'GIT_REPO',    value: '$.project.http_url']                        // 取仓库地址
        ]
    )
    // 定时触发
    cron('H 3 * * *')   // 每天凌晨 3 点
}
```

GenericTrigger 是最灵活的方式：**从 GitLab 推送的 Webhook JSON 里用 JSONPath 提取变量**（分支、仓库、提交人），注入流水线参数。`regexpFilter` 做过滤（比如只放行 `refs/heads/` 开头的分支推送）。定时用 `cron('H 3 * * *')`——注意 `H` 是 Jenkins 的"哈希散列"语法，避免所有任务同时整点触发。

## 条件执行：什么时候跳过

```groovy
stage('提交') {
    when {
        beforeAgent true   // 在分配 agent 之前先判断
        expression { currentBuild.currentResult == 'SUCCESS' }
    }
    steps { /* ... */ }
}
```

`when` 是声明式里推荐的条件跳过方式（比在 stage 里写 `if` 更规范）。`beforeAgent true` 尤其重要：**条件不满足时连 agent 都不分配**——多平台流水线里"三平台全成功才提交"的判断，就用它避免白占一台构建机（见第 10 章实际用法）。

## Git 操作：拉代码与带认证的推送

```groovy
// 拉取代码（标准姿势）
checkout([
    $class: 'GitSCM',
    branches: [[name: params.BRANCH_NAME]],
    extensions: [cleanBeforeCheckout()],       // 拉取前清空工作区
    userRemoteConfigs: [[url: params.GIT_REPO, credentialsId: params.CREDENTIALS_ID]]
])
```

私有仓库的认证有两种，按场景选：

```groovy
// 方式一：用户名密码（如提交制品回仓库）
withCredentials([usernamePassword(credentialsId: 'git-cred', usernameVariable: 'U', passwordVariable: 'P')]) {
    sh """
        repoWithAuth=https://${U}:${P}@github.com/repo.git
        git remote set-url origin "\${repoWithAuth}"
    """
}

// 方式二：GitLab API Token（只读/API 调用场景）
withCredentials([gitlabApiToken(credentialsId: 'git-token', variable: 'GIT_TOKEN')]) {
    sh """
        repoWithAuth=http://oauth2:${GIT_TOKEN}@<git-server>
        git remote set-url origin "\${repoWithAuth}"
    """
}
```

注意：凭证**永远用 `withCredentials` 注入环境变量**，绝不要硬编码在 Jenkinsfile 里（git log 会留下明文密码）。`credentialsId` 对应 Jenkins 凭证管理里配置的 ID，团队共享。

## 错误处理：失败要可见、要可重试

```groovy
// 捕获异常 → 通知 → 标记失败 → 中断
try {
    sh 'command'
} catch (Exception e) {
    sendNotification('FAILURE', '阶段', "错误: ${e.getMessage()}")
    currentBuild.result = 'FAILURE'
    error "终止构建"
}

// 网络类操作加重试（最多 3 次，间隔 30 秒）
def retries = 3
while (retries > 0) {
    try {
        sh 'command'
        break
    } catch (Exception e) {
        retries--
        if (retries == 0) throw e
        sleep(30)
    }
}
```

错误处理的铁律：**`currentBuild.result` 标记 + `error` 中断 + `sendNotification` 通知三者缺一不可**——只中断不通知，半夜构建挂了没人知道；只标记不中断，流水线会继续跑后面的阶段。重试只用于网络类瞬时故障（拉依赖、下载文件），编译错误重试没有意义。

## 快速参考表（日常翻这张）

| 场景 | 语法 |
|---|---|
| 跨平台命令 | `isUnix() ? sh() : bat()` |
| 遍历执行 | `list.each { item -> /* */ }` |
| 并行执行 | `parallel { stage1 {} stage2 {} }` |
| 条件跳过 | `when { expression { condition } }` |
| 异步触发 | `build(job: 'x', wait: false)` |
| 凭证使用 | `withCredentials([usernamePassword(credentialsId: 'id', ...)])` |
| 制品复制 | `copyArtifacts filter: '*.zip', projectName: 'job', selector: lastSuccessful()` |

## 小结

- Pipeline as Code 把构建流程版本化、可评审、可复用，替代界面点按钮；
- 骨架五块：agent / environment / parameters / stages / post，各司其职；
- agent 支持标签组合与 Docker 容器；触发器用 GenericTrigger 从 Webhook 提参；
- `when` + `beforeAgent` 是省资源的关键；凭证必须 `withCredentials` 注入；
- 错误处理：标记 + 中断 + 通知三件套；重试只用于瞬时故障。

> 延伸：骨架有了，下一节看它怎么撑起一条完整的 C++ 流水线（第 10 章），以及怎么把公共逻辑抽成共享库（第 12 章）。
