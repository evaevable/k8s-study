# CloudNote 案例清单

本目录存放贯穿案例 **CloudNote（云笔记服务）** 的 Kubernetes 清单文件。
它们会随着课程章节的推进逐步添加。

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
| `00-namespace.yaml` | 命名空间 `cloudnote` | 第 8 章 |
| `10-config.yaml` | ConfigMap + Secret | 第 8 章 |
| `20-api-deployment.yaml` | api 的 Deployment 与 Service | 第 5、6 章 |
| `30-web.yaml` | web 前端 Deployment 与 Service | 第 5、6 章 |
| `40-ingress.yaml` | Ingress 七层入口 | 第 7 章 |
| `50-postgres.yaml` | StatefulSet + PVC | 第 9、13 章 |
| `60-hpa.yaml` | 自动扩缩容 | 第 12 章 |
| `70-probes-demo.yaml` | 探针与故障恢复演示 | 第 11 章 |
| `kustomization.yaml` | 一键部署全部 | 第 14 章 |

## 使用方式

第 14 章之前，建议**按章节单独 apply**，一次只观察一个概念的效果：

```bash
kubectl apply -f <本章对应的 yaml>
kubectl get pods -w
```

第 14 章会给出完整的一键部署流程与演练脚本。
