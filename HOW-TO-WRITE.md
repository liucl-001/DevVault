# DevVault 使用说明

## 日常写文章流程

### 1. 新建一篇文章

在 `mkdocs-docs/` 下新建目录放文章。比如加一个新分类：

```
mkdocs-docs/
  cpp-engineering/          # 已有分类
    index.md                # 分类首页
    01-toolchain.md
    ...
  notes/                    # 新分类：新建这个目录
    index.md                # 分类首页（可选）
    踩坑1.md                # 新文章
```

### 2. 写 Markdown

直接写 `.md` 文件，标题用 `#`、`##` 分级（右侧目录自动生成）。

代码块：
````
```bash
git push origin master
```
````

### 3. 注册到导航

编辑 `mkdocs.yml`，在 `nav` 里加上新文章路径：

```yaml
nav:
  - 首页: index.md
  - C++工程化实战:
      - 导读: cpp-engineering/index.md
      - 01 xxx: cpp-engineering/01-xxx.md
  - 笔记:                    # 新分类
      - 踩坑1: notes/踩坑1.md
```

### 4. 本地预览

```powershell
E:\src\mkdocs-env\Scripts\mkdocs.exe serve --dev-addr 127.0.0.1:8000
```

浏览器打开 http://127.0.0.1:8000/ ，改md文件自动刷新。

### 5. 构建并发布

```powershell
# 构建到仓库docs目录
E:\src\mkdocs-env\Scripts\mkdocs.exe build --site-dir E:\src\dev-vault\docs

# 推送到Gitee（稳定）
cd E:\src\dev-vault
git add -A
git commit -m "文章说明"
git push origin master

# 推送到GitHub（时好时坏，多试几次）
git push github master
```

GitHub Pages等1-2分钟自动更新 https://liucl-001.github.io/DevVault/

## 目录结构

```
dev-vault-docs/           # MkDocs项目（写作在这里）
  mkdocs.yml               # 站点配置+导航
  docs/                    # 文章源文件
    index.md               # 首页
    cpp-engineering/       # C++工程化小册
    stylesheets/           # 自定义CSS
  overrides/               # 自定义模板
dev-vault/                # Git仓库（部署在这里）
  docs/                    # MkDocs构建产物（GitHub Pages指向这里）
  mkdocs-docs/             # 源文件备份
```

## 常用配置

- **改站点标题**：编辑 `mkdocs.yml` 里的 `site_name`
- **加新分类**：新建目录 + nav里加一组
- **明暗主题**：右上角太阳/月亮图标切换，自动跟随系统
- **搜索**：右上角搜索框，全站全文检索
