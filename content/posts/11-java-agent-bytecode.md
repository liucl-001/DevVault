---
title: "Java Agent 与字节码改写：从一行启动参数开始"
date: 2026-10-16T15:45:45+08:00
draft: false
---
先说个事儿，讲讲我为什么写这篇。

最近在研究一类"激活工具"——就是那种在 IDE 的启动参数里加上 `-javaagent:xxx.jar` 和 `--add-opens=...` 这么两行，软件就"变样"了的东西。起因特别简单：我很好奇，**凭什么往启动参数里加两行，一个程序的整个行为就被改了？**

追下去之后发现，这背后的东西一点都不神秘，就是 JVM 生态里几项通用的机制——和 SkyWalking 做链路追踪、Arthas 做线上诊断，用的是**同一套底层能力**。这篇文章就是我把这条链从现象追到 JVM 底层的过程。读完你就知道，这类工具不是黑科技，它只是把几项官方能力拼在了一起。

先说清楚范围：我只讲这套通用机制本身，不讲任何针对具体软件的绕过步骤。机制是中性的，至于拿来干嘛，你自己心里有数，也请遵守对应软件的许可协议。

---

## 先从"一个类是怎么活起来的"说起

要理解 agent 为什么能插手，得先知道一个类从 `.class` 字节码到真正能跑，JVM 中间经历了什么。这个过程规范叫 **LOADING（加载）→ LINKING（链接）→ INITIALIZING（初始化）**：

```
字节码(.class)
   ↓ LOADING：读字节码，生成 Class 对象
   ↓ LINKING
   │   ├ 验证（VERIFY）：字节码合不合法、能不能过类型检查
   │   ├ 准备（PREPARE）：静态字段分配内存
   │   └ 解析（RESOLVE）：符号引用转直接引用
   ↓ INITIALIZING：执行静态初始化块 <clinit>
```

这里有个很关键的点：**JVM 真正消费的，是"验证通过的那份字节码"。** 而在验证之前、LOADING 阶段，字节码还有一次被替换的机会——这正是 agent 下手的时机。JVM 把这个入口留在 JVMTI 层（后面第四章会讲到），Java 这边则通过 `java.lang.instrument` 暴露出来。

## Java Agent：JVM 留给外界的官方后门

Java Agent 就是一个**遵循 `java.lang.instrument` 规范的 jar**，装载后能拿到一个 `Instrumentation` 对象——这是 JVM 给 Java 代码"改写已加载类"的唯一官方通道。

它有两条装载路径，你大概都见过：

- **启动时装载**：`java -javaagent:agent.jar -jar app.jar`，走 `premain(String, Instrumentation)`。APM、覆盖率采集、安全防护都是这条路。
- **运行中 attach**：Arthas 走这条路，工具 attach 进一个正在跑的 JVM，走 `agentmain(String, Instrumentation)`，所以它能不动声色地"钻进"别人的进程。

启动时那条路，时机是酱紫的：JVM 初始化完系统类加载器、但还没加载主类之前，就会把一个叫 **JPLISAgent** 的本地组件拉起来，调用你的 `premain`：

```
JVM 启动
  ├ ① 解析命令行，认出 -javaagent
  ├ ② 初始化系统类加载器
  ├ ③ 装载 agent，调用 premain()   ← 在这里拿到 Instrumentation
  ├ ④ 加载主类，进 main()
  └ ⑤ 业务类懒加载（每个都会被 agent 的转换器过一遍）
```

因为 `premain` 跑在所有业务类加载之前，agent 就能提前把"转换器"注册好，之后每一个类加载都会被它过一遍手。

agent jar 的清单文件（`META-INF/MANIFEST.MF`）里，有几个属性决定了它的能力：

| 属性 | 干嘛的 |
|------|--------|
| `Premain-Class` / `Agent-Class` | 两条装载路径各自的入口类 |
| `Can-Redefine-Classes` / `Can-Retransform-Classes` | 允不允许重定义 / 重转换已加载类 |
| `Boot-Class-Path` | 追加到 Bootstrap 类加载器搜索路径 |

一个最小的 agent 其实就这么点东西：

```properties
Premain-Class: com.example.MyAgent
Can-Redefine-Classes: true
Can-Retransform-Classes: true
```

```java
public class MyAgent {
    public static void premain(String args, Instrumentation inst) {
        inst.addTransformer(new MyTransformer(), true);
    }
}
```

## 进场之后，第一件事：怎么认出"这是哪个类"

好，agent 进场了，`addTransformer` 注册的转换器会在每个类加载时被回调。现在问题来了——**回调来了，你总得知道眼前这个类是哪个吧？不然改谁都不知道。**

这就是 `transform` 方法签名里 `className` 参数的意义。它给你的是 JVM 内部的**类名表示法**：包路径用斜杠、类名直连。比如 Java 里 `com.example.LicenseCheck`，传进来就是：

```java
className = "com/example/LicenseCheck"   // 包名 + 类名，斜杠分隔
```

你平时写的 `com.example.LicenseCheck` 是"点号分隔"的，这里变成了斜杠。记住这个换算，别在匹配时踩坑。

拿到这个名字，接下来就是**目标匹配**。实际工具通常先粗筛再精筛：

```java
public byte[] transform(ClassLoader loader, String className, ...) {
    // 粗筛：只看我关心的包（前缀匹配）
    if (className == null || !className.startsWith("com/example/")) {
        return null;                    // 不是目标，原样返回
    }
    // 精筛：精确到类
    if (!className.equals("com/example/LicenseCheck")) {
        return null;
    }
    // 命中目标，进入改写
    return rewrite(className, classfileBuffer);
}
```

粗筛用**包名前缀**（`startsWith`），一次挡掉绝大多数无关类；精筛再对到具体类。为什么先粗筛？因为 JVM 里要加载的类成千上万，每个都去解析字节码太浪费，先用一个字符串比较把 99% 挡在外面。

有些场景只靠类名不够，比如要看注解、父类、接口——这时就得把字节码交给 `ClassReader` 解析，在 `visitAnnotation` / `visitMethod` 里做二次判断。但**第一步永远是"看名字"，这是性能的关键**。

## 第二件事：怎么认出"要改哪个方法"、它的参数和返回值

类认出来了，下一步是定位到具体方法。这里就用到 ASM 回调 `visitMethod` 时给的几个参数：

```java
public MethodVisitor visitMethod(int access, String name, String desc,
                                 String signature, String[] exceptions)
```

- `name`：方法名，一目了然，比如 `check`。
- `desc`：**方法描述符**，参数列表和返回值全编码在这一个字符串里。
- `signature` / `exceptions`：泛型签名和声明抛出的异常，一般不用管。

`desc` 是 JVM 对方法类型的标准编码，格式是 `(参数类型)返回类型`。比如：

```
()V                 → 无参、返回 void
(IJ)Z               → 参数为 int、long，返回 boolean
(Ljava/lang/String;)Z  → 参数为 String，返回 boolean
(Ljava/lang/String;ILjava/util/List;)Ljava/lang/String;
                    → 三个参数（String、int、List），返回 String
```

基本类型记这几个：`V`=void、`Z`=boolean、`I`=int、`J`=long、`D`=double、`F`=float、`C`=char、`B`=byte、`S`=short；引用类型一律 `L包名/类名;`（注意分号结尾）。数组就是 `[` 加元素类型。

所以定位一个方法，就是**用 `name` + `desc` 一起匹配**——同名方法可能有好几个（重载），靠 desc 区分它们：

```java
@Override
public MethodVisitor visitMethod(int access, String name, String desc,
                                 String signature, String[] exceptions) {
    // 只改：名为 check、参数 String、返回 boolean 的那个方法
    if (name.equals("check") && desc.equals("(Ljava/lang/String;)Z")) {
        return new AdviceAdapter(Opcodes.ASM9, super.visitMethod(...), ...) {
            // 在这里对方法体做手脚
        };
    }
    return super.visitMethod(access, name, desc, signature, exceptions);
}
```

**到这一步，你手里已经攥着三样东西：目标类、目标方法名、方法的完整参数/返回签名。** 这就是"改谁"的全部信息。

## 第三件事：核心——怎么"修改"而不是"增加"

这是你最容易想歪的地方，也是激活这类场景和普通插桩最根本的差别。

普通 APM 工具做的是**增加**：往方法里塞入埋点打印，方法原来的逻辑照跑。但激活类工具要的是**修改**：把软件里那一段"许可证校验"的已有逻辑，在字节码层面改掉——比如让某个返回 `false`（未授权）的校验方法，直接返回 `true`（已授权）。**不是在旁边加东西，而是让原来的代码"变了"。**

### 改字节码到底改的是什么

ASM 把一个方法体看成一条**指令事件流**，`visitMethodInsn`（方法调用）、`visitVarInsn`（局部变量）、`visitInsn`（栈操作/返回）、`visitJumpInsn`（跳转）……一个个按顺序回调给你。你做的"修改"，就是在这条流里**拦截、替换、跳过**某些事件。

比如 `AdviceAdapter` 提供了两个好用的时机钩子：

- `onMethodEnter()`：方法第一条指令前
- `onMethodExit(int opcode)`：每个 return 之前

### 典型操作一：改方法的返回值

目标：`boolean check(String key)` 原本算完返回 `false`，我要让它返回 `true`。

在 `onMethodExit` 里，当检测到这个方法以 `IRETURN`（返回 int/boolean）结尾时，把栈顶上原来的返回值**丢掉、换成一个常量 1**：

```java
@Override
protected void onMethodExit(int opcode) {
    if (opcode == IRETURN) {          // 这是个返回 boolean/int 的方法
        mv.visitInsn(POP);            // 丢掉原来栈顶的返回值
        mv.visitInsn(ICONST_1);       // 压入常量 1（即 true）
        // 然后 JVM 会接着执行原来的 IRETURN，返回的变成 1
    }
}
```

效果等价于把源码里的 `return 原结果;` 改成了 `return true;`——**方法体里其他逻辑一行都没加，只是改了最终返回值**。这就是最典型的"改而不是加"。

### 典型操作二：改方法内部的一个调用

如果不想整个替换返回值，只想把方法里某次"关键调用"的结果改掉，可以在方法体里**拦下那次 `visitMethodInsn`**：

```java
@Override
public MethodVisitor visitMethodInsn(int opcode, String owner, String name, String desc, boolean itf) {
    // 只拦截：对某个类的 validate 调用，参数 String、返回 boolean
    if (name.equals("validate") && desc.equals("(Ljava/lang/String;)Z")) {
        // 先调它，但把结果覆盖
        super.visitMethodInsn(opcode, owner, name, desc, itf);
        mv.visitInsn(POP);            // 丢掉调用的返回值
        mv.visitInsn(ICONST_1);       // 压入 true
        return mv;                     // 不再继续原始回调
    }
    return super.visitMethodInsn(opcode, owner, name, desc, itf);
}
```

这个语义就是：**"原来这里调用 validate 拿结果，现在调用照旧，但结果我接管、换成 true"**。粒度比改整个方法返回值更细，你只动了方法体里那一处。

### 典型操作三：跳过 / 翻转分支

还有一种思路：不替换值，而是**让某段校验代码根本别执行**——用 `GOTO` 直接跳到方法末尾，或者在分支处翻转判断条件（`IFNE` 换 `IFEQ`）。这类属于"控制流"层面的修改，实现上要小心维护局部变量表和 StackMapTable，所以工具一般尽量用前两种"改值"的方式，少动控制流。

### 为什么改动必须"合法"：验证器与 StackMapTable

不管你用哪种改法，**插进去 / 替换出来的字节码必须能通过验证器**。JVM 会做严格的类型检查：

- **操作数栈类型一致**：你压了个 `String` 后面当 `int` 用，直接 `VerifyError`
- **局部变量表匹配**：索引、类型要对上
- **StackMapTable（堆栈映射表）**：Java 6 起 JVM 在每个分支汇合点做增量类型检查。你一旦动了控制流（加跳转），改变了栈和局部变量的形状，就得同步更新映射表

这也是为什么正经工具都用 `AdviceAdapter`、`GeneratorAdapter` 这类**帮你维护栈帧**的封装，而不是裸写 `MethodVisitor`——它们知道该在什么时候更新映射表、怎么保证你压栈出栈的类型对得上。

一句话记住：**你改的不是源码，而是 JVM 最终验证并执行的那份字节码**；改完还得让它稳稳过验证器。

## 往下钻一层：这一切在 JVM 底层是怎么撑起来的

到这儿你可能会想：`java.lang.instrument` 这套东西，总不会是凭空冒出来的吧？对，它建立在 **JVMTI（JVM Tool Interface）** 之上。

具体来说，JDK 里有个专门的本地代理，叫 **JPLISAgent**（源码在 OpenJDK 的 `jdk/src/java.instrument/.../libinstrument/`）。它干的事，就是把 Java 层的调用翻译成 JVMTI 的本地接口：

```
Instrumentation.addTransformer(tr)
   ↓
JPLISAgent.c 里 SetEventCallbacks 注册 onClassFileLoadHook
   ↓
只要 JVM 要 define 一个类，就会回调 ClassFileLoadHook 事件
   ↓
在回调里把 Java 层所有已注册的 transformer 依次跑一遍
   ↓
收集返回的新字节码，取最后一个非 null 的作为最终字节码
```

所以**"改写字节码能生效"的底层真相**是：不是在源码层面改了东西，而是在字节码被验证器消费之前，于 JVMTI 的 `ClassFileLoadHook` 这个 hook 处，把整份字节码替换掉了。

redefine 和 retransform 在 JVMTI 层也各有对应：redefine 对应 `RedefineClasses`，retransform 对应 `RetransformClasses`（它会再次触发 `ClassFileLoadHook`，让转换器再跑一遍）。这里有个硬性约束很多人会搞混：**这两者都改不了类的基本结构**——增减字段、方法、改签名都不行，只能改方法体里的实现。这是 JVMTI 规范规定的。

## 为什么非要 `--add-opens` 不可

前面那几行启动参数里，`--add-opens` 是很多人一头雾水的地方。这要从 JDK 9 的模块系统说起。

JDK 9 引入了模块化，`java.base` 模块的内部包（`jdk.internal.*` 那一堆）默认**强封装**——除了模块自己，谁都不许反射访问，硬来就抛 `InaccessibleObjectException`。

这里有个特别容易混淆的点，值得单独拎出来说清楚：`--add-exports` 和 `--add-opens` 是两码事。

- **`--add-exports`** 管的是**编译期**：让别的模块在编译时能看到这个包的公开类型。
- **`--add-opens`** 管的是**运行期深反射**：允许别的模块对这个包做 `setAccessible(true)`。

agent 需要的是 `--add-opens`，因为它在运行期要用反射 / 字节码访问内部类，而不是编译期去引用它们：

```bash
--add-opens=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED
```

语法是 `--add-opens=<模块>/<包>=<目标模块>`，`ALL-UNNAMED` 表示"所有未命名模块"——也就是跑在类路径上的所有代码，agent 就在其中。

那为什么偏偏要碰内部包？因为 ASM 这类库要"读懂并改写字节码"，而 JVM 自己就带了一份 ASM 的副本（`jdk.internal.org.objectweb.asm`）。有的实现为了省依赖，会直接复用它；就算不复用，想深反射到 JVM 内部的数据结构，也得 `--add-opens`。所以结论很实在：**在 JDK 9+ 上做字节码操作，这行参数基本躲不掉。**

## 把整条链串起来

把这些串成一条线，就是开头那句"魔法"的完整真相：

```
java -javaagent:agent.jar --add-opens=...=ALL-UNNAMED -jar app.jar
   ↓ JVM 启动早期
JPLISAgent 装载 → premain() 拿到 Instrumentation
   ↓ addTransformer() 注册 → 本地 SetEventCallbacks 挂上 ClassFileLoadHook
   业务类 defineClass 时
   ↓ ClassFileLoadHook 事件 → 逐个跑 Java transformer
   ↓ transformer 先按 className 粗筛/精筛出目标类
   ↓ 再按 visitMethod 的 name + desc 定位目标方法
   ↓ 用 ASM 改方法体（改返回值 / 改某处调用）→ 新字节码
   ↓ 新字节码过 VERIFY（含 StackMapTable 检查）→ 生成 Class
   ↓ 程序行为在字节码层面被改变
```

四个环节，环环相扣，缺一不可：

| Java 层 | JVMTI / 规范层 | 缺了会怎样 |
|---------|--------------|-----------|
| `-javaagent:` | 启动器装载 JPLISAgent | agent 根本不进场 |
| `Instrumentation.addTransformer` | 挂 `ClassFileLoadHook` 回调 | 没法干预类定义 |
| ASM 改写 | 在 hook 里替换字节码（得过验证器） | 改不动字节码 |
| `--add-opens` | 模块系统强封装 | JDK 9+ 反射被拒 |

## 附：一个最小可运行的 Demo（动手验证）

上面讲了半天机制，不自己跑一遍很难有实感。这里给一个**真正能编译运行**的最小例子，把前面三步完整走一遍：认类 → 定位方法 → 改返回值。

Demo 的目标非常小：一个 `Target.isLicensed()` 本来返回 `false`，我们用 agent 把它在字节码层面改成返回 `true`。跑之前打印 `false`，挂上 agent 打印 `true`——"改而不是加"的完整效果。

**环境要求（保证可复现、与本文实测一致）**：

| 项 | 值 |
|----|----|
| JDK | Temurin 21.0.12.1+1（x64 Windows，HotSpot，即安装目录形如 `jdk-21.0.12.101-hotspot`） |
| 下载来源 | 清华大学开源软件镜像站 · Adoptium 21 JDK |
| 目录 | `https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/x64/windows/` |
| 具体文件 | `OpenJDK21U-jdk_x64_windows_hotspot_21.0.12.1_1.zip`（解压即用）或同名 `.msi` |

> demo 的编译 / 打包 / 运行依赖 JDK 21 的 `javac` / `jar` / `java`，请确保它们在 PATH 中（或改用该 JDK `bin` 下的全路径）。其他 JDK 版本通常也能跑（ASM 兼容），但为复现本文"实测通过"的结果，建议使用上面同一版本。

整个 demo 只有 **2 个 Java 源文件**（完整文件也在本项目 `demo/` 目录里）：

**1. `MyAgent.java`** — agent 入口 + 转换器（同文件两个类，对应正文三步）：

```java
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import org.objectweb.asm.*;

public class MyAgent {
    // premain 在业务类加载前执行，这里只注册转换器
    public static void premain(String args, Instrumentation inst) {
        inst.addTransformer(new LicenseTransformer(), true);
    }
}

class LicenseTransformer implements ClassFileTransformer {
    public byte[] transform(ClassLoader loader, String className,
            Class<?> classBeingRedefined, ProtectionDomain pd,
            byte[] classfileBuffer) {
        // ① 认类：className 是 JVM 内部形式，Target 在默认包所以就是 "Target"
        if (!"Target".equals(className)) return null;

        ClassReader cr = new ClassReader(classfileBuffer);
        // COMPUTE_MAXS/COMPUTE_FRAMES：让 ASM 自动重算栈上限和 StackMapTable，改完不用手动维护帧
        ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS | ClassWriter.COMPUTE_FRAMES);

        ClassVisitor cv = new ClassVisitor(Opcodes.ASM9, cw) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String desc,
                    String signature, String[] exceptions) {
                MethodVisitor mv = super.visitMethod(access, name, desc, signature, exceptions);
                // ② 定位方法：name=isLicensed，desc "()Z" = 无参、返回 boolean
                if (name.equals("isLicensed") && desc.equals("()Z")) {
                    return new MethodVisitor(Opcodes.ASM9, mv) {
                        @Override
                        public void visitInsn(int opcode) {
                            // ③ 改返回值：拦 IRETURN，return 前丢掉原值、压入 true
                            if (opcode == Opcodes.IRETURN) {
                                super.visitInsn(Opcodes.POP);       // 丢掉栈顶原返回值
                                super.visitInsn(Opcodes.ICONST_1);  // 压入 true
                            }
                            super.visitInsn(opcode);                // 继续原来的 IRETURN
                        }
                    };
                }
                return mv;
            }
        };

        cr.accept(cv, 0);
        return cw.toByteArray();
    }
}
```

**2. `Main.java`** — 入口 + 目标类（同文件两个类）：

```java
public class Main {
    public static void main(String[] args) {
        System.out.println("isLicensed = " + new Target().isLicensed());
    }
}

class Target {
    public boolean isLicensed() {
        return false;   // 模拟校验未通过
    }
}
```

**3. `MANIFEST.MF`** — 声明 agent 入口（注意结尾要有空行）：

```
Premain-Class: MyAgent
Can-Retransform-Classes: true
```

**一键构建 + 运行（PowerShell，`build-run.ps1`）**：

```powershell
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "lib" | Out-Null

# ① 下载 ASM 核心 jar（只用核心 asm.jar，不依赖 asm-commons）
Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/org/ow2/asm/asm/9.7/asm-9.7.jar" -OutFile "lib\asm.jar"

# ② 编译（仅 2 个源文件）
javac -encoding UTF-8 -cp "lib\asm.jar" Main.java MyAgent.java

# ③ 打包 agent：把 asm 解包进 agent.jar，自包含（生产形态）。
#    -javaagent 会把 agent.jar 加入系统类加载器搜索路径，asm 打进 jar 后运行时无需额外 classpath
New-Item -ItemType Directory -Force -Path "build" | Out-Null
Push-Location build
jar xf ..\lib\asm.jar                  # 解出 org/objectweb/asm/...
Pop-Location
jar cfm agent.jar MANIFEST.MF MyAgent.class LicenseTransformer.class -C build org
Remove-Item -Recurse -Force build

# ④ 对比运行（agent.jar 已自包含 asm，classpath 都只需 .）
Write-Host "--- 不带 agent（预期：false）---"
java -cp . Main
Write-Host "--- 带 agent（预期：true）---"
java -javaagent:agent.jar -cp . Main
```

**预期输出**：

```
--- 不带 agent（预期：false）---
isLicensed = false
--- 带 agent（预期：true）---
isLicensed = true
```

> 说明：demo 只用 ASM 核心包（`asm.jar`），`COMPUTE_FRAMES` 自动补栈帧，依赖最小、最贴近机制本身。**已在 JDK 21（Temurin 21.0.12.1）实测通过**，输出如上方预期。完整源码（含 `demo/build-run.ps1` 一键运行）可在仓库获取：`https://gitee.com/goccoder/jbactive`

## 这套机制的正当用途

说了半天，这套东西在正经工程里用得可广了：

- **APM**：SkyWalking、New Relic，无侵入埋点、方法耗时统计（这是"增加"路线的典型）
- **运行时诊断**：Arthas，观测方法入参出参、在线热更新
- **测试 / 质量**：Jacoco 覆盖率采集、Mockito 行为替换
- **热部署 / 修复**：线上临时改方法体逻辑（"修改"路线的典型）
- **安全**：RASP 做方法级拦截

"增加"和"修改"两种路线，底层是同一套机制，差别只在改写方式：**APM 大多在方法里"加"东西，修复/激活类场景大多"改"已有逻辑。** 而这套机制本身是中性的，用途由使用者决定。

---

## 参考资料来源（按可信度分级）

写这篇文章，每个关键论断都能在这里找到出处核对。排序原则是：**先第一手规范和 JDK 源码，再官方文档，最后才是开源实现**（开源实现用来参考"怎么落地"，不是规范依据）。

**A 级：官方规范与 JDK 源码（结论以此为准）**

| 主题 | 来源 | 链接 |
|------|------|------|
| `java.lang.instrument` 包规范（agent 装载、Manifest 属性、transformer 语义） | Oracle 官方 Javadoc | http://docs.oracle.com/en/java/javase/25/docs/api/java.instrument/java/lang/instrument/package-summary.html |
| `Instrumentation` 接口（addTransformer / retransform / redefine） | Oracle 官方 Javadoc | http://docs.oracle.com/en/java/javase/24/docs/api/java.instrument/java/lang/instrument/Instrumentation.html |
| JVMTI 规范（`ClassFileLoadHook`、`RedefineClasses`、`RetransformClasses`） | Oracle JVMTI 文档 | https://docs.oracle.com/en/java/javase/23/docs/specs/jvmti.html |
| 类加载 / 链接 / 验证 / StackMapTable | Oracle JVMS | https://docs.oracle.com/javase/specs/jvms/se23/html/jvms-4.html |
| 方法描述符 desc 编码规则 | Oracle JVMS（第 4 章） | https://docs.oracle.com/javase/specs/jvms/se23/html/jvms-4.html |
| JPLISAgent 本地代理实现 | OpenJDK 源码（java.instrument 模块） | https://github.com/openjdk/jdk/tree/master/src/java.instrument |
| `--add-opens` / `--add-exports` 语法与深反射 | Oracle 迁移指南 | http://docs.oracle.com/en/java/javase/23/migrate/migrating-jdk-8-later-jdk-releases.html |

**B 级：官方库文档（面向使用）**

| 主题 | 来源 | 链接 |
|------|------|------|
| ASM 框架概述 | OW2 官方 | https://asm.ow2.io/ |
| ASM 开发者指南（ClassReader/ClassWriter/ClassVisitor、AdviceAdapter） | OW2 官方 | https://asm.ow2.io/developer-guide.html |
| `AdviceAdapter`（onMethodEnter / onMethodExit、方法修改） | ASM Javadoc | https://asm.ow2.io/javadoc/org/objectweb/asm/commons/AdviceAdapter.html |

**C 级：知名开源实现（参考落地，非规范依据）**

| 主题 | 来源 | 链接 |
|------|------|------|
| SkyWalking Java Agent（`-javaagent` 自动埋点） | Apache 官方 | https://skywalking.apache.org/docs/skywalking-java/latest/en/setup/service-agent/java-agent/readme/ |
| Arthas（运行时诊断 / redefine） | 阿里开源 | https://arthas.aliyun.com/ |

正文里的规范语义、事件机制、阶段顺序，都以 **A 级** 为准；ASM 具体用法看 **B 级**；C 级用来理解"大厂怎么把机制落成产品"。如果正文和 A 级有出入，以 A 级为准。

