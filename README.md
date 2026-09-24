# 从零讲透 Kubernetes

**从一次凌晨故障到一套生产级集群**

一本讲原理而非讲操作的 Kubernetes 技术书。全书 15 章加一份附录，以一个虚构的云笔记服务 **CloudNote** 为贯穿案例，从"手工运维为什么必然失效"讲到"一套服务如何在生产环境里稳定运行"。每个概念都要回答"它为什么必须存在"，而不只是"它怎么配置"。

- 正文约 13,500 行，39 张 Mermaid 架构图（GitHub 原生渲染）
- 15 个 YAML 清单 + 13 个实验脚本，可直接 `kubectl apply` 跑起来
- 基于 Kubernetes 1.28 及以上版本验证

---

## 三种阅读方式

| 方式 | 入口 | 适合 |
|---|---|---|
| **单文件全书** | [BOOK.md](BOOK.md) | 一口气读完，或用浏览器搜索全文 |
| **按章阅读** | 下方目录 | 只想看某一个主题 |
| **在线版（mdBook）** | 见[在线版](#在线版) | 想要侧边栏目录、全文检索、深浅色主题 |

---

## 目录

[前言](chapters/preface.md)　—— 这本书要解决什么问题、怎么读、贯穿案例与写作约定

### 第一篇　原理基础

建立整体模型。这一篇几乎不需要集群，纯读即可。

| 章 | 标题 | 回答的问题 |
|---|---|---|
| 1 | [一张地图看清 Kubernetes](chapters/01-why-k8s.md) | 有了容器为什么还需要 Kubernetes？它到底在管什么？ |
| 2 | [容器与 Pod：最小调度单元的秘密](chapters/02-pod.md) | 为什么最小单位不是容器而是 Pod？ |
| 3 | [集群的解剖学：控制平面与工作节点](chapters/03-cluster-anatomy.md) | API Server、Scheduler、kubelet 各自负责什么？ |
| 4 | [声明式 API 与控制器模式](chapters/04-declarative-controller.md) | 事件丢了为什么副本数还能恢复？ |

### 第二篇　部署与网络

把应用真正跑起来并暴露出去。从这一篇开始需要一个可用的集群。

| 章 | 标题 | 回答的问题 |
|---|---|---|
| 5 | [把应用跑起来：Deployment 与滚动更新](chapters/05-deployment.md) | 怎么发布？回滚回滚的究竟是什么？ |
| 6 | [Pod 之间怎么说话：Service、DNS 与数据面](chapters/06-service-network.md) | ClusterIP 为什么 ping 不通却能通 TCP？ |
| 7 | [让世界访问你：Ingress 与南北向流量](chapters/07-ingress.md) | 域名怎么进来？ingress-nginx 退役后选什么？ |

### 第三篇　配置、存储与调度

让应用具备生产形态。

| 章 | 标题 | 回答的问题 |
|---|---|---|
| 8 | [配置与密钥：ConfigMap 与 Secret](chapters/08-configmap-secret.md) | 配置怎么与镜像解耦？Secret 真的安全吗？ |
| 9 | [数据要持久：Volume、PV、PVC、StorageClass](chapters/09-storage.md) | 容器没了数据为什么还在？RWO 到底限制了什么？ |
| 10 | [调度与资源管理：requests、limits、QoS 与亲和性](chapters/10-scheduling.md) | 为什么 CPU 超限只是变慢，内存超限却被杀死？ |

### 第四篇　稳定性与弹性

让系统在故障与波动中存活。

| 章 | 标题 | 回答的问题 |
|---|---|---|
| 11 | [自愈的真相：探针与故障恢复](chapters/11-self-healing.md) | Kubernetes 能修什么、不能修什么？liveness 为什么危险？ |
| 12 | [弹性伸缩：HPA、VPA 与 Cluster Autoscaler](chapters/12-autoscaling.md) | 为什么 requests 写错，HPA 就失灵？ |
| 13 | [工作负载全景：StatefulSet、DaemonSet、Job 与 CronJob](chapters/13-workloads.md) | 有状态服务、每节点一个、批处理任务分别用什么？ |

### 第五篇　实战与生产

从零部署一整套服务，注入六类故障做演习，最后固化成手册。

| 章 | 标题 | 内容 |
|---|---|---|
| 14 | [实战总演习：CloudNote 从 0 到 1](chapters/14-capstone.md) | 五阶段部署 + 六个故障演习 |
| 15 | [生产实践与排错手册](chapters/15-production.md) | 五层排查模型、症状对照表、上线检查清单 |

### 附录

- [命令速查表 · YAML 骨架 · 术语中英对照](chapters/appendix-cheatsheet.md)

> 小节级目录（每章 8~12 个小节，共 190 余条）在 [BOOK.md](BOOK.md) 开头，全部可点击跳转。

---

## 贯穿案例：CloudNote

CloudNote 是一个在线笔记服务，由五个组件构成：`web`（前端）、`api`（后端）、`worker`（异步导出）、`redis`（缓存）、`postgres`（数据库）。

选择单一贯穿案例，是为了让同一份配置在各章之间持续演进：第 5 章的 Deployment 到第 8 章长出 ConfigMap 与 Secret，到第 10 章加上资源声明与打散约束，到第 11 章补上探针。每一章都在同一份配置上做增量，而不是各讲一个互不相干的玩具例子。

它也承载了第 1 章列出的四种手工运维失效方式——环境漂移、人肉扩容、故障无人接管、发布靠勇气——每一种都在后续某一章被正面解决。

配套的 YAML 清单与实验脚本在 [cases/cloudnote/](cases/cloudnote/README.md)，可以独立于书稿运行。没有集群时，第 1.10 节给出了三种零成本的搭建方式。

---

## 在线版

在线版由 [mdBook](https://rust-lang.github.io/mdBook/) 构建，提供侧边栏目录、全文检索与深浅色主题。

**地址**：`https://evaevable.github.io/k8s-study/`

它由 `.github/workflows/mdbook.yml` 在每次推送到 `main` 时自动构建并部署。首次启用需要在 GitHub 仓库的 **Settings → Pages → Build and deployment** 里把 Source 设为 **GitHub Actions**（而不是 Deploy from a branch），之后推送即自动发布。

### 本地构建

```bash
# 一次性安装（也可以直接从各自的 GitHub Releases 下载二进制）
cargo install mdbook mdbook-mermaid

# 生成 mermaid 所需的前端资源，只需执行一次（产物已在 .gitignore 中）
mdbook-mermaid install .

# 本地预览，默认 http://localhost:3000
mdbook serve --open

# 只构建，产物在 book/
mdbook build
```

书稿源目录就是 `chapters/`（`book.toml` 里 `src = "chapters"`），目录结构由 [chapters/SUMMARY.md](chapters/SUMMARY.md) 定义。这样做的理由是：不必把 16 个正文文件搬到 `src/` 下，章节之间的交叉引用与 README 里的链接都无需改动，而 `cases/` 下的 YAML 与实验脚本也天然不会被当成章节收进书里。

---

## 修改与重新生成

正文的唯一来源是 `chapters/*.md`。`BOOK.md` 与 `chapters/SUMMARY.md` 都是生成物，**不要直接编辑**：

```bash
# 改完任意章节后重跑，同时重新生成 BOOK.md 与 chapters/SUMMARY.md
bash tools/build-book.sh
```

该脚本在生成后会自检一遍：目录里的每条链接都必须命中文档中真实存在的锚点，否则以非零状态退出。CI 也会校验 `BOOK.md` 与章节是否同步，不同步则构建失败。

新增一章时，把文件名加到 `tools/build-book.sh` 里 `PARTS` 列表对应的篇下面即可，两份目录都会自动更新。

### 仓库结构

```
.
├── BOOK.md                     # 单文件全书（生成物，开头是完整目录）
├── README.md                   # 本文件
├── book.toml                   # mdBook 配置
├── chapters/                   # 正文：唯一的内容来源
│   ├── SUMMARY.md              # mdBook 目录（生成物）
│   ├── preface.md              # 前言
│   ├── 01-why-k8s.md … 15-production.md
│   └── appendix-cheatsheet.md
├── cases/cloudnote/            # 配套资源：15 个 YAML + 13 个实验脚本
├── tools/
│   ├── build-book.sh           # 重新生成 BOOK.md 与 SUMMARY.md
│   ├── debook.py               # 书稿化清洗脚本（成书过程留存）
│   └── polish-*.py             # 行文改写脚本（成书过程留存）
└── .github/workflows/mdbook.yml
```

文件名使用英文 slug，便于命令行引用与跨平台；章内标题为中文。

---

## 许可

正文与配套代码可自由用于学习与内部分享。
