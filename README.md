# Kubernetes 从零到一：一章一章搞懂它

> 授课人：WorkBuddy（你的 K8s 老师）
> 学员：lance
> 学习方式：**一章一图一案例**。学完当章，回一句「继续」，我讲下一章。

---

## 这门课想解决什么问题

市面上讲 Kubernetes 的材料有两种常见毛病：

1. **翻字典式**：把几十个对象的名词解释堆在一起，你看完记住了 `Pod` 的拼写，却不知道它为什么存在。
2. **跳过原理直接抄命令**：告诉你 `kubectl apply -f xxx.yaml`，但不告诉你这行命令之后集群里到底发生了什么，于是出了问题只能瞎试。

这门课换一条路：**先讲"为什么需要它"，再讲"它怎么做到的"，最后落到"怎么用"**。

- 每一章都用**积木块（Block）**切成小段，一段只解决一个问题，读完一段就能停下来。
- 每一章配**一张图谱**（Mermaid 图，GitHub 上可直接渲染），帮你把零散名词挂到同一张地图上。
- 全书用**一个贯穿案例 CloudNote（云笔记服务）**走到底。第 1 章认识它，第 14 章把它从零部署、扩容、打挂、自愈，完整走一遍。

---

## 课程表

| 章 | 标题 | 这一章回答的问题 | 状态 |
|---|---|---|---|
| 01 | [一张地图看清 Kubernetes](chapters/01-why-k8s.md) | 有了 Docker，为什么还要 K8s？K8s 到底在管什么？ | 已发布 |
| 02 | [容器与 Pod：最小调度单元的秘密](chapters/02-pod.md) | 为什么最小单位不是容器而是 Pod？ | 已发布 |
| 03 | [集群的解剖学：控制平面与工作节点](chapters/03-cluster-anatomy.md) | API Server / Scheduler / Kubelet 各干什么？ | 已发布 |
| 04 | [声明式 API 与控制器模式：K8s 的灵魂](chapters/04-declarative-controller.md) | 「期望状态」和「调谐循环」到底怎么运作？ | 已发布 |
| 05 | [把应用跑起来：Deployment 与滚动更新](chapters/05-deployment.md) | 怎么发布？怎么回滚？ | 已发布 |
| 06 | [Pod 之间怎么说话：Service、DNS 与数据面](chapters/06-service-network.md) | 一个虚拟 IP 背后发生了什么？ | 已发布 |
| 07 | [让世界访问你：Ingress 与南北向流量](chapters/07-ingress.md) | 域名怎么进来？为什么 ingress-nginx 退役了？ | 已发布 |
| 08 | [配置与密钥：ConfigMap 与 Secret](chapters/08-configmap-secret.md) | 配置怎么和镜像解耦？Secret 真的安全吗？ | 已发布 |
| 09 | [数据要持久：Volume、PV、PVC、StorageClass](chapters/09-storage.md) | 容器死了数据为什么还在？RWO 到底是什么？ | 已发布 |
| 10 | 调度与资源管理 | requests/limits、QoS、亲和性、污点容忍 | 待发布 |
| 11 | 自愈的真相：探针与故障恢复 | K8s 到底能修哪些故障？不能修哪些？ | 待发布 |
| 12 | 弹性伸缩：HPA / VPA / Cluster Autoscaler | 怎么自动从 2 个副本扩到 20 个？ | 待发布 |
| 13 | 工作负载全景：StatefulSet / DaemonSet / Job | 有状态服务、每节点一个、批处理任务怎么办？ | 待发布 |
| 14 | 实战总演习：CloudNote 从 0 到 1 | 部署、扩缩容、故障恢复全流程实操 | 待发布 |
| 15 | 生产实践与排错手册 | 上线前检查清单、故障树、常用命令 | 待发布 |
| 附录 | 命令速查表 + 术语中英对照表 | 随时翻阅 | 待发布 |

---

## 目录结构

```
k8s-study/
├── README.md                     # 本文件：课程总览与目录
├── chapters/                     # 每一章的正文（Markdown，含 Mermaid 图谱）
│   ├── 01-why-k8s.md
│   ├── 02-pod.md
│   ├── 03-cluster-anatomy.md
│   ├── 04-declarative-controller.md
│   ├── 05-deployment.md
│   ├── 06-service-network.md
│   ├── 07-ingress.md
│   ├── 08-configmap-secret.md
│   └── 09-storage.md
├── cases/cloudnote/              # 贯穿案例的 YAML 清单，随章节逐步填充
│   ├── 00-namespace.yaml
│   ├── 10-config.yaml
│   ├── 15-pod-demo.yaml
│   ├── 18-config-demo.yaml
│   ├── 20-api-deployment.yaml
│   ├── 22-api-service.yaml
│   ├── 30-web.yaml
│   ├── 40-ingress.yaml
│   ├── 45-pvc-demo.yaml
│   ├── tools/inspect-cluster.sh
│   ├── tools/reconcile-lab.sh
│   ├── tools/rollout-lab.sh
│   ├── tools/service-lab.sh
│   ├── tools/ingress-lab.sh
│   ├── tools/config-lab.sh
│   ├── tools/storage-lab.sh
│   └── README.md
└── .gitignore
```

> 说明：文件名使用英文 slug（便于命令行引用与跨平台），章内标题为中文。

---

## 怎么用这套材料

1. **先看图，再看字**：每章开头的图谱是全章骨架，先扫一眼，心里有个"地图"。
2. **积木块按顺序读**：标注 `【积木 x-y】`，一段只讲一个概念，读不完可以停。
3. **一定要动手**：第 1 章第 10 节给你三种零成本起集群的方式，选一个即可。
4. **每章末尾有自测题**：答不上来就回到对应积木块复习，不用硬背。

---

## 关于「不背命令」的原则

命令是查出来的，不是背出来的。这门课里出现的每一条命令，我们都会讲清**它改变了什么状态**。理解了状态流转，命令忘了随手查文档就能补回来。
