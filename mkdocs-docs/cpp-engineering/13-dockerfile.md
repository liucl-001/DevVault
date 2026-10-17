# Dockerfile 最佳实践：指令、缓存与多阶段

> 本节解决：Dockerfile 怎么写才又快又稳——缓存规则、核心指令用法、.dockerignore、多阶段构建，一套能直接用的最佳实践。

## Dockerfile 写得好不好，差的是构建时间

同样是构建镜像，有人 30 秒，有人 30 分钟——差别不在网络，在 **Dockerfile 的层缓存利用**。Docker 的镜像构建是按指令一层层缓存的：某条指令没变，它和它后面的层直接复用缓存。所以"哪条指令放哪"直接决定构建速度。这一节把缓存规则、核心指令、多阶段构建一次讲透。

## 缓存规则：五条铁律

1. **指令按"变化频率"排序**：不常变的（装基础工具）放前面，常变的（COPY 代码）放后面——前面的层稳定，缓存命中率就高；
2. **`RUN` 创建中间层会被缓存**：`docker build --no-cache` 可强制不缓存，但正常构建尽量利用缓存；
3. **`ADD`/`COPY` 每次执行缓存必然失效**：文件一变，后面的层全部重跑——所以**尽量放后面**，别把 COPY 放在安装工具前面；
4. **`CMD`/`ENTRYPOINT` 不产生缓存层**：它们是运行时指令，只在容器启动时执行；
5. **每个 `RUN` 尽量合并**：一条 `RUN` 里的多个命令（`&&` 连接）只生成一层，减少层数 = 减少体积 + 加快构建。

```dockerfile
# ❌ 反面：COPY 在前面，每次改代码都重装依赖
COPY . /app
RUN apt-get install -y build-essential cmake

# ✅ 正面：依赖安装在前，代码 COPY 在后
RUN apt-get install -y build-essential cmake   # 代码没变时这层永远命中缓存
COPY . /app
```

## 核心指令速查（生产够用版）

| 指令 | 作用 | 关键点 |
|---|---|---|
| `FROM` | 指定基础镜像 | 必须第一条；锁 tag 别用 latest |
| `RUN` | 构建时执行命令 | 有缓存；多命令用 `&&` 合并 |
| `CMD` | 容器默认执行命令 | 运行时；可被 `docker run` 参数覆盖；只最后一条生效 |
| `ENTRYPOINT` | 容器入口命令 | 与 CMD 配合：`ENTRYPOINT` 定主命令，`CMD` 给默认参数 |
| `ADD` | 添加文件 | **自动解压 tar、支持 URL**；缓存必失效 |
| `COPY` | 添加文件 | 弱化版 ADD，不支持解压/URL；优先用 |
| `ENV` | 设置环境变量 | 影响后续所有指令，构建期可用 |
| `EXPOSE` | 声明端口 | 仅文档作用，不真正开端口 |
| `WORKDIR` | 工作目录 | 影响后续 RUN/CMD/COPY 的相对路径 |
| `VOLUME` | 匿名卷 | 声明可挂载点 |

**ADD vs COPY**：能用 COPY 就别用 ADD——ADD 的"自动解压/URL 下载"在 CI 里经常带来意外（比如 URL 下载到一半、解压出意外目录结构），COPY 行为可预期。

**ENTRYPOINT + CMD 的标准组合**：

```dockerfile
ENTRYPOINT ["top", "-b"]   # 主命令
CMD ["-c"]                 # 默认参数：docker run image 等效于 top -b -c
```

## 多阶段构建：把"构建环境"和"运行环境"分开

多阶段构建（multi-stage build）是生产镜像的标配：**前面阶段负责编译（工具齐全），最后阶段只 COPY 产物（镜像干净）**。第 14 章的 Linux 镜像就是这个套路，这里用一个文档服务镜像演示：

```dockerfile
# 第一阶段：编译/准备（工具齐全，产物自包含）
FROM ubuntu:24.04 as builder
RUN apt-get install -y build-essential cmake ninja-build
# ... 编译 ...

# 第二阶段：只带产物和运行时
FROM ubuntu:24.04
COPY --from=builder /opt/build/output /opt/app   # 只复制产物
WORKDIR /opt/app
EXPOSE 4000
ENTRYPOINT ["/opt/app/run.sh"]
```

价值：**最终镜像里没有编译器、没有源码、没有构建缓存**——体积从 GB 级降到百 MB 级，攻击面也小。第 14 章的 Windows 镜像更进一步：五阶段（BaseImage → Builder → SDKInstaller → QTInstaller → VSBuildTools）用 `COPY --from=` 只把需要的工具从各阶段拷进最终层。

## .dockerignore：别把脏东西带进构建上下文

```dockerfile
# .dockerignore
*/temp*
*/*/temp*
temp?
```

.dockerignore 的作用是**减少构建上下文体积**：`COPY . /app` 会把整个目录打进上下文，没有 ignore，`node_modules`、`build`、`.git` 这些动辄 GB 的目录全会被传输和缓存。规则语法：`*/temp*` 匹配任意层级的 temp 开头文件，`temp?` 匹配单字符后缀。

## 小结

- 缓存是 Dockerfile 的灵魂：按变化频率排指令，COPY 尽量后置，RUN 多命令合并；
- 核心指令：RUN 构建期 / CMD+ENTRYPOINT 运行时 / COPY 优先于 ADD / WORKDIR 定基准；
- 多阶段构建把编译环境和运行环境分离，镜像小、攻击面小（第 14 章是完整实战）；
- .dockerignore 控制构建上下文，别把 node_modules/.git 打进镜像。

> 延伸：指令会用之后，第 14 章是完整的 C++ 构建镜像实战（Linux + Windows 五阶段 + buildkit 缓存），第 15/16 章讲镜像仓库与编排。

