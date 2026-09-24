# CloudNote 案例清单

本目录存放贯穿案例 **CloudNote（云笔记服务）** 的 Kubernetes 清单文件。
它们会随着课程章节的推进逐步添加。

## 一键部署

```bash
# 方式一（推荐）：按五个阶段有序部署 + 等就绪
bash tools/capstone-lab.sh deploy

# 方式二：用 Kustomize 一次性聚合提交（不保证顺序、不等就绪）
kubectl apply -k .

# 部署后跑一次 13 项验收
bash tools/capstone-lab.sh verify

# 体检
bash tools/diagnose.sh

# 六个故障演习
bash tools/capstone-lab.sh fault
bash tools/capstone-lab.sh cleanup
```

## 应用结构

| 组件 | 类型 | 副本数 | 有状态 | 首次出现章节 |
|---|---|---|---|---|
| `web` | 前端静态资源（Nginx） | 2 | 否 | 第 5 章 |
| `api` | 后端 API 服务 | 2 → 10（自动） | 否 | 第 2 / 5 / 12 章 |
| `worker` | PDF 导出异步任务 | 1 | 否 | 第 13 章 |
| `redis` | 缓存 | 1 | 是（可容忍丢失） | 第 6 章 |
| `postgres` | 主数据库 | 1 | 是（必须持久化） | 第 9 / 13 章 |

## 文件规划

| 文件 | 内容 | 对应章节 |
|---|---|---|
| `00-namespace.yaml` | 命名空间 `cloudnote` | 第 2 章（前置）/ 第 8 章（详解） |
| `15-pod-demo.yaml` | 三容器裸 Pod：init 容器 + 主容器 + 边车 + 共享卷 | 第 2 章 |
| `tools/inspect-cluster.sh` | 集群透视脚本（只读，打印控制面/数据面关键信息） | 第 3 章 |
| `tools/reconcile-lab.sh` | 调和循环实验（删 Pod 自愈、改标签造孤儿、幂等、409 冲突、并发删除） | 第 4 章 |
| `tools/rollout-lab.sh` | 发布与回滚实验（滚动更新观察、坏版本、秒级回滚、maxSurge/revisionHistoryLimit） | 第 5 章 |
| `tools/service-lab.sh` | Service 实验（Endpoints 自动维护、DNS、ping 不通但 curl 通、不 Ready 时地址簿变空、iptables 规则、NodePort、Headless） | 第 6 章 |
| `tools/ingress-lab.sh` | 七层入口实验（检测控制器、路径分流、Prefix 匹配边界、TLS 终止） | 第 7 章 |
| `tools/config-lab.sh` | 配置注入实验（三路注入行为对比、Secret 解密实证、目录覆盖坑、optional） | 第 8 章 |
| `tools/storage-lab.sh` | 存储实验（PVC vs emptyDir 的 A/B 对照、Pending→Bound、动态供给 Events、扩容、reclaimPolicy） | 第 9 章 |
| `tools/scheduling-lab.sh` | 调度与资源实验（FailedScheduling、CPU 限流、OOMKilled、QoS 等级、打散软硬对比、taint 与 toleration） | 第 10 章 |
| `tools/probes-lab.sh` | 探针与自愈实验（容器重启 vs Pod 重建、readiness 只摘流量、CrashLoopBackOff 退避、慢启动死循环与修复） | 第 11 章 |
| `tools/autoscaling-lab.sh` | 弹性伸缩实验（metrics-server 检测、TARGETS 含义、扩容与比例公式、缩容延迟、扩了但 Pending、VPA 资源建议） | 第 12 章 |
| `tools/workloads-lab.sh` | 工作负载实验（StatefulSet 三个稳定与有序启动、独立 PVC、Pod 级 DNS、重建后身份与存储不变、DaemonSet 每节点一个、Job 与 Indexed 分片、CronJob） | 第 13 章 |
| `tools/capstone-lab.sh` | 实战总演习（五阶段部署 / 13 项验收 / 六个故障演习 / Kustomize 一把梭 / 清理） | 第 14 章 |
| `tools/diagnose.sh` | 集群与命名空间体检（按五层模型输出报告，只读） | 第 15 章 |
| `10-config.yaml` | ConfigMap `api-config` + Secret `api-secret`（含"Secret 不是加密"的安全说明） | 第 8 章 |
| `18-config-demo.yaml` | 三种注入方式并存的演示 Pod（环境变量 / 目录挂载 / subPath） | 第 8 章 |
| `20-api-deployment.yaml` | api 的 Deployment（含探针、资源、滚动更新策略） | 第 5 章 |
| `22-api-service.yaml` | api 的 Service | 第 6 章 |
| `28-scheduling-demo.yaml` | 资源与调度演示（QoS 三兄弟、OOM 炸弹、硬性打散、超高 requests） | 第 10 章 |
| `30-web.yaml` | web 前端 Deployment + Service（为第 7 章的路径分流提供第二个后端） | 第 7 章 |
| `35-worker.yaml` | worker 异步任务 Deployment（IO 密集、CPU 利用率低，用于演示「指标选错」） | 第 12 章 |
| `40-ingress.yaml` | Ingress 七层入口（按域名与路径分流 + TLS） | 第 7 章 |
| `45-pvc-demo.yaml` | PVC + 两个对照 Pod（PVC vs emptyDir），用于观察数据持久性差异 | 第 9 章 |
| `50-postgres.yaml` | headless Service + StatefulSet（含 volumeClaimTemplates，每个 Pod 独立 PVC） | 第 13 章 |
| `60-hpa.yaml` | 弹性伸缩：api 的 HPA（按 CPU）+ worker 的 HPA（按队列积压量）+ VPA（Off 模式当资源顾问） | 第 12 章 |
| `70-probes-demo.yaml` | 探针与自愈演示（CrashLoopBackOff 退避、慢启动死循环、startupProbe 修复、三探针职责分离） | 第 11 章 |
| `kustomization.yaml` | Kustomize 聚合清单（一条命令装起生产形态的全部资源） | 第 14 章 |

## 使用方式

第 14 章之前，建议**按章节单独 apply**，一次只观察一个概念的效果：

```bash
kubectl apply -f <本章对应的 yaml>
kubectl get pods -w
```

第 14 章会给出完整的一键部署流程与演练脚本。
