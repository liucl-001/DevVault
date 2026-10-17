# docker-compose 编排：一个命令拉起整套开发环境

> 本节解决：多个容器怎么组织——compose 的核心字段（services/networks/volumes）、版本选择，以及用真实 compose 文件把"整套环境"串起来。

## 容器多了，docker run 就不够用了

一个容器用 `docker run` 还好，但 CI 环境里往往是：Jenkins 主节点 + Registry + Registry UI + 数据库 + 各种中间件，每个都带端口、卷、网络、重启策略——`docker run` 写十条命令，谁维护谁崩溃。

**docker-compose 把"整套环境"声明成一份 YAML**：一个文件定义所有服务，一条 `docker compose up -d` 全部拉起，`down` 全部停掉。这一节讲透核心字段，再拆两个真实文件。

## 版本选择：别乱升

compose 顶部 `version` 对应 docker-compose 版本要求，**新文件用新版、旧文件不要乱升**：

| version | 需要 docker-compose |
|:-:|:-:|
| 3.8 | 19.03.0+ |
| 3.3 | 17.06.0+ |
| 2.4 | 17.12.0+ |

## services：核心段落

每个 service 就是一个容器，最常用的字段：

```yaml
services:
  app:
    image: nginx:latest          # 直接用镜像
    build:                       # 或本地构建（第 14 章 compose 就是这种）
      context: .
      dockerfile: Dockerfile
      args:
        MSVC_VERSION: 17         # build-arg，构建期才可用
    ports:
      - "9527:8080"              # 宿主机端口:容器端口
    volumes:
      - /data/app:/app           # 数据卷挂载
    environment:
      TZ: Asia/Shanghai
    networks:
      - app_net
    restart: unless-stopped      # 崩溃自动重启
    depends_on:
      - db
```

生产必配三件：**`volumes` 挂数据盘**（容器可重建、数据不丢）、**`restart: unless-stopped`**（崩溃自动拉起）、**`TZ` 时区**（容器默认 UTC，日志时间对不上）。

## networks：服务间通信

默认每个 compose 项目建一个 bridge 网络，服务名即域名。需要精细控制时显式声明：

```yaml
networks:
  app_net:
    driver: bridge                       # 单机默认
    ipam:
      config:
        - subnet: 172.28.0.0/16          # 自定义网段
          gateway: 172.28.0.1
    internal: true                       # 内部网络，隔离外网
  external_net:
    external: true                       # 引用已存在的网络（跨 compose 项目共享）
```

**两个典型场景**：
- `internal: true`：数据库/中间件放内部网络，不暴露公网；
- `external: true`：两个 compose 项目（如 Jenkins 和业务服务）共享同一网络，用服务名互通。

## 实战拆解一：CI 全家桶（Jenkins + Registry）

第 3 章的 CI compose 把 Jenkins 和 Registry 放在一个文件：

```yaml
services:
  jenkins:
    image: jenkins/jenkins:${JENKINS_VERSION}
    volumes: [ /data/docker_volumes/jenkins:/var/jenkins_home ]
    ports: [ "${JENKINS_PORT}:8080", "${JENKINS_AGENT_PORT}:50000" ]
    networks: [ jenkins ]
    restart: unless-stopped
    environment: { TZ: Asia/Shanghai }
  registry:
    image: registry:${REGISTRY_VERSION}
    volumes: [ /data/docker_volumes/registry:/var/lib/registry ]
    ports: [ "${REGISTRY_PORT}:5000" ]
    restart: unless-stopped
    environment: { TZ: Asia/Shanghai }
networks:
  jenkins: { driver: bridge }
```

**用 `.env` 管版本和端口**：`${JENKINS_VERSION}` 来自同目录 `.env`——版本升级、端口调整只改一个文件，compose 文件本身保持"声明式、可提交"。

## 实战拆解二：文档服务 compose

```yaml
version: "3.3"
services:
  knowledge:
    build:
      context: .
      dockerfile: Dockerfile          # 多阶段构建
    ports:
      - "4900:4000"
    ulimits:
      nproc: 65535                    # 进程数限制
      nofile: { soft: 20000, hard: 40000 }
    restart: always
```

两个细节：
- **`build` 不是 `image`**：本地 Dockerfile 构建（多阶段案例，第 13 章讲过）；
- **`ulimits`**：容器默认文件句柄/进程数限制低，服务并发一上来就报 `too many open files`——生产服务按需调。

## 小结

- compose 把"整套环境"声明成一份 YAML：`up -d` 拉起、`down` 停掉、`.env` 管版本；
- services 核心：image/build、ports、volumes 挂数据盘、restart 保活、TZ 时区、depends_on 顺序；
- networks：单机 bridge 默认服务名互通；`internal` 隔离、`external` 跨项目共享；
- 生产必配：数据卷、restart、时区；高并发服务按需调 ulimits。

> 延伸：compose 里用的镜像来自哪（第 15 章 Registry）、镜像怎么管理（第 17 章）、Jenkins 全家桶怎么初始化（第 3 章）。

