# Jenkins 主节点部署：Docker 化一键拉起

> 本节解决：CI 中枢——Jenkins 主节点怎么用 Docker 部署、JDK 版本为什么要锁死、.env/compose 怎么组织、初始化与关键配置。

## 主节点是 CI 的中枢，但别把它当"一台装好的服务器"

很多团队装 Jenkins 的方式是"找个机器、下载 war 包、java -jar 跑起来"——然后这台机器的状态就成了玄学：JDK 升级了、插件装乱了、数据目录在系统盘打满了，谁都不知道。生产环境的正确姿势是 **Docker 化部署**：Jenkins 跑在容器里，数据卷挂出来，版本、端口、配置全用文件管理，重建一台主节点 = 一条命令。

## 第一步：Docker 基础配置

主节点本身要先配好 Docker（参考第 2 章），但多了两个 CI 特有的配置：

```json
// /etc/docker/daemon.json
{
  "insecure-registries": ["<registry>:5000"],   // 私有镜像仓库（http，必须加 insecure）
  "data-root": "/var/lib/docker/data"            // 数据目录
}
```

- **`insecure-registries`**：私有仓库（第 15 章部署）走 HTTP，Docker 默认拒绝非 HTTPS 仓库，必须在这里白名单——**不配的话 `docker pull` 直接报 `certificate signed by unknown authority`**；
- **`data-root`**：镜像、容器、卷全在数据盘，别占系统盘。

## 第二步：.env + compose 启动

Jenkins 官方镜像 + docker compose 是标准组合。版本和端口用 `.env` 管理：

```env
# .env（与 compose.yaml 同目录）
# 版本选择要点：1、必须锁死 jdk 版本；2、只选 lts 版本
JENKINS_VERSION=2.555.2-lts-jdk21
JENKINS_PORT=9527            # 外部访问端口
JENKINS_AGENT_PORT=50000     # 代理端口（从节点连接用）
```

```yaml
# compose.yaml
services:
  jenkins:
    image: jenkins/jenkins:${JENKINS_VERSION}
    volumes:
      - /data/docker_volumes/jenkins:/var/jenkins_home   # 数据卷挂出来
    ports:
      - "${JENKINS_PORT}:8080"
      - "${JENKINS_AGENT_PORT}:50000"
    environment:
      TZ: Asia/Shanghai
    restart: unless-stopped
```

两个设计点：

1. **`JENKINS_VERSION` 必须锁 JDK 版本**：`2.555.2-lts-jdk21` 明确带上 `jdk21`——因为**主节点用什么 JDK，所有从节点就必须用什么 JDK**（Jenkins 通过 SSH 启动 agent 时用同一套 Java 协议）。版本不锁，主节点悄悄升级 JDK，从节点全部连不上，这是生产事故级的问题。
2. **数据卷挂到 /data**：`/var/jenkins_home` 里是全部配置、插件、构建历史，必须挂到数据盘——Jenkins 数据丢了等于重搭整个 CI。

## 第三步：初始化

```bash
docker compose up -d jenkins
# 拿初始密码
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

初始化五步：访问 `http://<IP>:${JENKINS_PORT}` → 输入初始密码 → 安装推荐插件 → 创建管理员 → 配置 Jenkins URL → 完成。

## 第四步：必需插件与关键配置

**插件**（推荐插件装完后再补，避免版本冲突）：

| 插件 | 用途 |
|---|---|
| Docker Pipeline | 流水线里用 `agent { docker }` |
| Copy Artifacts | 跨任务复制制品（第 8/16 章） |
| Generic Webhook Trigger | 接收 GitLab/GitHub webhook（第 9 章） |
| Git Parameter | 构建时从仓库拉分支列表 |

**关键配置**（每个流水线任务都要配）：

- **主节点不跑构建任务**：主节点只做调度/编排，不跑任何构建任务——**避免主节点卡死**（构建任务吃 CPU/内存，主节点卡死整个 CI 都停）；
- **从节点禁用并发**：每个流水线勾选"Do not allow concurrent builds"——**让单个任务尽量快完成**（一个节点同时跑多个任务会互相抢资源，单个任务反而变慢）；
- **Permission to Copy Artifact = `*`**：允许下游复制制品，否则 `copyArtifacts` 报权限不足；
- **Webhook token 一致性**：GitLab 里配的 token 必须和 Jenkinsfile 里 `GenericTrigger(token: ...)` 一致（第 9 章）。

## 第五步：Shared Library（base_lib）配置

### 什么是 Shared Library

Shared Library 是 Jenkins 的"公共代码库"——把多个流水线重复用的函数（构建/打包/通知/上传）抽出来放一个 Git 仓库，所有流水线 `@Library` 引用即可。**避免每个流水线复制粘贴同一套代码**，改一处全生效。

### Jenkins 里怎么配置

**Manage Jenkins → System → Global Pipeline Libraries**：

> **![Global Pipeline Libraries](https://www.jenkins.io/zh/doc/book/resources/pipeline/add-global-pipeline-libraries.png)**：Jenkins → Manage Jenkins → System → Global Pipeline Libraries 页面，配置 Library Name/Default Version/Retrieval Method 的完整截图。

| 配置项 | 值 |
|---|---|
| Library Name | `base_lib` |
| Default Version | `master`（或分支名） |
| Retrieval Method | Modern SCM → Git |
| Project Repository | `<共享库 Git 仓库地址>` |

### 怎么用

流水线开头引用：

```groovy
@Library('base_lib@master') _;

pipeline {
    agent any
    stages {
        stage('构建') {
            steps {
                buildStage('linux')    // 共享库里的函数
            }
        }
    }
}
```

### 和第 12 章的关系

本节只讲"怎么在 Jenkins 里注册"；**共享库怎么写（vars/ 目录、函数模板、共享库骨架）见第 12 章**。

## 第六步：定时备份（关键运维）

Jenkins 数据丢了等于重搭整个 CI——**必须定时备份**。备份内容是 `JENKINS_HOME`（配置/凭据/任务/插件），排除可重建的 workspace/caches。

### 备份脚本

```bash
#!/bin/bash
# /data/backup/jenkins_backup.sh
BACKUP_DIR=/data/backup/jenkins
JENKINS_HOME=/data/docker_volumes/jenkins    # compose 挂载的 Jenkins 数据目录
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS=7
COMPOSE_DIR=/opt/jenkins    # compose.yaml 所在目录

mkdir -p $BACKUP_DIR

# 关键：先停 Jenkins（运行中备份可能不一致，文件正在写入）
cd $COMPOSE_DIR
docker compose stop jenkins

# 备份（排除 workspace/caches/war）
tar -czf $BACKUP_DIR/jenkins_$DATE.tar.gz \
    --exclude='workspace' \
    --exclude='caches' \
    --exclude='war' \
    -C $JENKINS_HOME .

# 备份完立即启动
docker compose start jenkins

# 保留最近 7 天，自动清理旧备份
find $BACKUP_DIR -name "jenkins_*.tar.gz" -mtime +$KEEP_DAYS -delete

echo "备份完成: jenkins_$DATE.tar.gz（Jenkins 已重启）"
```

> **为什么要先停**：Jenkins 运行时会持续写入 jobs/secrets/config.xml，tar 打包时文件正处于修改中间态，备份出来的可能损坏。凌晨 2 点备份停机几分钟影响小。

### 定时执行（crontab）

```bash
# 每天凌晨 2 点备份
0 2 * * * /data/backup/jenkins_backup.sh >> /data/backup/jenkins_backup.log 2>&1
```

### 备份内容说明

| 目录 | 备份？ | 说明 |
|---|---|---|
| `jobs/` | ✅ | 所有任务配置 |
| `users/` | ✅ | 用户 |
| `secrets/` | ✅ | 凭据（Git/Registry SSH key） |
| `plugins/` | ✅ | 插件（或备份插件列表） |
| `config.xml` | ✅ | 全局配置 |
| `workspace/` | ❌ | 构建工作空间，可重建 |
| `caches/` | ❌ | 缓存，可重建 |

> **进阶**：备份可以 rsync 到备份服务器（异地容灾），或推到对象存储（Minio/S3）。

## 踩过的坑

1. **JDK 版本漂移 = 从节点全挂**：主节点镜像带 `-jdk21` 后缀就是为了锁死，别换成不带后缀的 latest；
2. **数据卷不挂 = 重建丢一切**：容器重建后插件、凭据、构建历史全没，务必挂卷；
3. **私有仓库忘配 insecure-registries**：拉构建镜像（第 14/18 章）直接失败，且报错容易误判成网络问题。

## 小结

- 主节点用 Docker + compose 部署：`.env` 锁版本端口、数据卷挂 /data、`restart: unless-stopped` 保活；
- **JDK 版本必须锁死且与从节点一致**——`-jdk21` 后缀就是干这个的；
- 插件按需补装：Docker Pipeline / Copy Artifacts / Generic Webhook / Git Parameter；
- 关键配置：共享库 `base_lib`、禁用并发、Copy Artifact 权限、Webhook token 一致。

> 延伸：主节点就绪后，配三平台从节点（第 4 章）——构建机才是真正干活的地方。
