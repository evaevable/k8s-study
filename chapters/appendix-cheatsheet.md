# 附录　命令速查表 · YAML 骨架 · 术语中英对照

> **用法**：这一篇是**工具性内容**，不要求通读。按"我要做什么"去查，而不是按字母顺序背。

---

## 一、kubectl 命令速查（按场景分组）

### 1. 看状态（最常用）

```bash
kubectl get pods -n <ns> -o wide                    # 状态 + 所在节点 + IP
kubectl get pods -A                                 # 所有命名空间
kubectl get pods -w                                 # 持续观察变化
kubectl get pods --show-labels                      # 看标签（排查 selector 不一致）
kubectl get all -n <ns>                             # 命名空间里的主要资源
kubectl get events -n <ns> --sort-by=.lastTimestamp  # 最近发生了什么
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

### 2. 排查问题（黄金三条）

```bash
kubectl describe pod <pod> -n <ns>                            # K8s 在抱怨什么
kubectl describe pod <pod> -n <ns> | sed -n '/Events/,$p'      # 只看事件
kubectl logs <pod> -n <ns> --tail=50                          # 应用日志
kubectl logs <pod> -n <ns> --previous                         # 上一次崩溃的现场（CrashLoop 必用）
kubectl logs -l app=api -n <ns> --prefix                      # 一组 Pod 的日志（带 Pod 名前缀）
kubectl logs <pod> -n <ns> -c <container>                     # 多容器时指定容器
```

### 3. 深入容器

```bash
kubectl exec -it <pod> -n <ns> -- sh                          # 进容器
kubectl exec <pod> -n <ns> -- env | grep DB                   # 看环境变量
kubectl exec <pod> -n <ns> -- cat /etc/app/config.yaml        # 看挂载的配置
kubectl exec <pod> -n <ns> -- ls -la /etc/app/                # 看软链接结构
kubectl debug -it <pod> -n <ns> --image=busybox:1.36 --target=<container>
kubectl debug node/<node> -it --image=busybox:1.36            # 进节点排错
```

### 4. 发布与回滚（第 5 章）

```bash
kubectl rollout status deployment/<name> -n <ns>              # 等发布完成
kubectl rollout history deployment/<name> -n <ns>             # 版本历史
kubectl rollout undo deployment/<name> -n <ns>                # 回滚
kubectl rollout undo deployment/<name> -n <ns> --to-revision=2
kubectl rollout restart deployment/<name> -n <ns>             # 重启（改配置后用）
kubectl rollout pause / resume deployment/<name> -n <ns>      # 暂停 / 恢复推进
kubectl set image deployment/<name> -n <ns> <c>=<image>       # 换镜像
kubectl set env deployment/<name> -n <ns> KEY=value           # 改环境变量
kubectl scale deployment/<name> -n <ns> --replicas=5          # 改副本数
kubectl annotate deployment/<name> -n <ns> \
  kubernetes.io/change-cause="升级到 v1.2.3" --overwrite       # 给版本历史写说明
```

### 5. 网络与流量（第 6、7 章）

```bash
kubectl get svc,endpoints -n <ns>                    # Service 与后端列表
kubectl get endpointslices -n <ns>                   # 新式的后端列表
kubectl get ingress -n <ns>                          # 七层入口（看 ADDRESS）
kubectl get ingressclass                             # 有哪些控制器
kubectl get networkpolicy -n <ns>                    # 网络策略
kubectl port-forward svc/<name> 8080:80 -n <ns>      # 端口转发（本地调试）
kubectl port-forward pod/<name> 8080:80 -n <ns>
kubectl proxy --port=8001                            # 直接访问 API Server
curl -s http://localhost:8001/healthz
```

### 6. 存储（第 9 章）

```bash
kubectl get pvc,pv -n <ns>                           # 存储声明与存储对象
kubectl get storageclass                             # 存储类
kubectl get sc -o custom-columns=\
'NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode'
kubectl describe pvc <name> -n <ns> | sed -n '/Events/,$p'    # 看绑定过程
kubectl patch pvc <name> -n <ns> -p \
  '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'     # 扩容
```

### 7. 资源与调度（第 10 章）

```bash
kubectl top pod -n <ns>                              # 实际用量（需 metrics-server）
kubectl top node
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'   # 已分配情况
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory'
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
kubectl taint nodes <node> key=value:NoSchedule      # 加污点
kubectl taint nodes <node> key=value:NoSchedule-     # 移除污点（末尾的减号）
kubectl label node <node> disktype=ssd                # 打标签
```

### 8. 弹性（第 12 章）

```bash
kubectl get hpa,vpa -n <ns>                          # 伸缩状态
kubectl describe hpa <name> -n <ns> | sed -n '/Events/,$p'    # 看伸缩决策记录
kubectl patch hpa <name> -n <ns> -p '{"spec":{"maxReplicas":20}}'
kubectl describe vpa <name> -n <ns> | sed -n '/Recommendation/,$p'   # VPA 给的资源建议
```

### 9. 节点维护（第 15 章）

```bash
kubectl cordon <node>                                # 标记不可调度（不驱逐已有 Pod）
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # 排空
kubectl uncordon <node>                              # 恢复可调度
kubectl get pdb -n <ns>                              # 中断预算
```

### 10. 权限与集群信息

```bash
kubectl auth can-i --list -n <ns>                    # 我能做什么
kubectl auth can-i delete pods -n <ns> --as=system:serviceaccount:<ns>:<sa>
kubectl api-resources                                # 集群支持哪些资源
kubectl api-versions                                 # 有哪些 API 组
kubectl get --raw /readyz?verbose                    # 控制面健康检查
kubectl cluster-info
kubectl version
kubectl explain pod.spec.containers.resources        # 查字段说明（比搜文档准）
kubectl explain deployment.spec.strategy --recursive # 递归展开
kubectl get <obj> -o json | jq .                     # 需要 jq 时
```

### 11. 修改对象

```bash
kubectl apply -f <file>                              # 声明式（推荐）
kubectl apply -k <dir>                               # 用 Kustomize
kubectl apply -f <file> --dry-run=server             # 【强烈推荐】先试跑，让服务端校验
kubectl diff -f <file>                               # 看会改什么，不改动集群
kubectl edit deployment/<name> -n <ns>               # 交互式编辑（临时救急）
kubectl patch <obj> <name> -n <ns> --type=merge -p '{...}'
kubectl patch <obj> <name> -n <ns> --type=json -p '[{...}]'
kubectl delete -f <file>
kubectl delete pod <pod> -n <ns> --force --grace-period=0   # 卡在 Terminating 时的最后手段
```

> **`--dry-run=server` 和 `kubectl diff` 是两个被严重低估的命令**：
> - `--dry-run=server` 会**真的送到 API Server 校验**（包括准入控制），但不落库
> - `kubectl diff` 告诉你"这次 apply 会改什么"
>
> **每次改生产前先跑一遍这两个，能避免大量事故。**

---

## 二、常用 YAML 骨架（可直接抄）

### 生产级 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: default
  labels:
    app: app
  annotations:
    kubernetes.io/change-cause: "v1.0.0 初始发布"
spec:
  replicas: 3
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      automountServiceAccountToken: false
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: app
      containers:
        - name: app
          image: registry.example.com/app:v1.0.0
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef: { name: app-config }
              prefix: APP_
            - secretRef: { name: app-secret }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 500m, memory: 384Mi }
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }   # 只检查进程自身！
            periodSeconds: 15
            failureThreshold: 3
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: {}
```

### 生产级 Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: default
spec:
  type: ClusterIP
  selector:
    app: app                # ← 必须与 Pod 标签逐字一致
  ports:
    - name: http
      port: 8080
      targetPort: http      # ← 用端口名，解耦
      protocol: TCP
```

### 生产级 StatefulSet（含 headless Service）

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db
spec:
  clusterIP: None           # headless：给每个 Pod 稳定 DNS
  selector:
    app: db
  ports:
    - port: 5432
      name: db
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db           # 必填
  replicas: 3
  podManagementPolicy: OrderedReady
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
        - name: db
          image: postgres:16-alpine
          ports:
            - { name: db, containerPort: 5432 }
          env:
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            periodSeconds: 5
  volumeClaimTemplates:     # 每个 Pod 一个独立 PVC
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests: { storage: 10Gi }
```

### 生产级 HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - { type: Percent, value: 100, periodSeconds: 15 }
        - { type: Pods, value: 4, periodSeconds: 15 }
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - { type: Percent, value: 10, periodSeconds: 60 }
      selectPolicy: Max
```

### 生产级 Job / CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "0 3 * * *"
  timeZone: "Asia/Shanghai"       # 默认是 UTC！
  concurrencyPolicy: Forbid       # 默认 Allow 是危险值
  startingDeadlineSeconds: 100
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      ttlSecondsAfterFinished: 7200
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: postgres:16-alpine
              command: ["sh", "-c", "echo 执行备份; sleep 5"]
```

### NetworkPolicy（默认拒绝 + 按需放行）

```yaml
# ① 默认拒绝所有入站
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
---
# ② 放行指定来源
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: app-allow
spec:
  podSelector:
    matchLabels:
      app: app
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: web
      ports:
        - { protocol: TCP, port: 8080 }
```

### LimitRange（给没写 resources 的 Pod 设默认值）

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: default
spec:
  limits:
    - type: Container
      default:          { cpu: 500m, memory: 256Mi }
      defaultRequest:   { cpu: 100m, memory: 128Mi }
      max:              { cpu: "2",  memory: 2Gi }
```

### ResourceQuota（限制命名空间总量）

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "50"
    persistentvolumeclaims: "10"
    services.loadbalancers: "2"
```

---

## 三、术语中英对照

### 核心对象

| 英文 | 中文 / 说明 | 首次出现 |
|---|---|---|
| **Pod** | 最小调度单元，"一台逻辑小机器" | 第 2 章 |
| **Deployment** | 无状态应用控制器，管滚动更新与回滚 | 第 5 章 |
| **ReplicaSet** | 保证副本数量的控制器（被 Deployment 管理） | 第 4 章 |
| **StatefulSet** | 有状态应用控制器，提供稳定身份与存储 | 第 13 章 |
| **DaemonSet** | 每个节点一个 | 第 13 章 |
| **Job / CronJob** | 一次性任务 / 定时任务 | 第 13 章 |
| **Service** | 给一组 Pod 提供稳定地址与负载均衡 | 第 6 章 |
| **Ingress** | 七层入口（域名 + 路径路由） | 第 7 章 |
| **ConfigMap / Secret** | 非敏感配置 / 敏感配置 | 第 8 章 |
| **Volume / PV / PVC / StorageClass** | 卷 / 存储对象 / 存储声明 / 存储类 | 第 9 章 |
| **Namespace** | 逻辑隔离的"抽屉" | 第 1 章 |
| **HPA / VPA** | 横向 / 纵向自动伸缩 | 第 12 章 |
| **ServiceAccount** | Pod 访问 API 时的身份 | 第 15 章 |
| **Role / RoleBinding** | 命名空间级权限 | 第 15 章 |
| **ClusterRole / ClusterRoleBinding** | 集群级权限 | 第 15 章 |
| **NetworkPolicy** | 网络访问策略 | 第 15 章 |
| **PodDisruptionBudget (PDB)** | 自愿中断时的可用性下限 | 第 15 章 |
| **LimitRange / ResourceQuota** | 命名空间级的默认值与配额 | 第 10 章 |
| **CustomResourceDefinition (CRD)** | 自定义资源类型 | 第 4 章 |
| **Operator** | CRD + 控制器 = 把运维知识代码化 | 第 4 章 |

### 控制面与组件

| 英文 | 说明 | 首次出现 |
|---|---|---|
| **Control Plane** | 控制面：做决策、存状态 | 第 3 章 |
| **Data Plane** | 数据面：真正搬运流量的那条路径 | 第 3 章 |
| **kube-apiserver** | 唯一入口（收、验、存、播） | 第 3 章 |
| **etcd** | 唯一事实来源（只存不思考） | 第 3 章 |
| **kube-scheduler** | 决定 Pod 去哪台节点（只写 `nodeName`） | 第 3 章 |
| **kube-controller-manager** | 几十个控制器的集合 | 第 3 章 |
| **kubelet** | 节点管家，只管自己名下的 Pod | 第 3 章 |
| **kube-proxy** | 规则写入器（不是代理！） | 第 3、6 章 |
| **containerd / CRI-O** | 容器运行时（通过 CRI 接口） | 第 3 章 |
| **CNI** | 容器网络接口，负责分配 Pod IP | 第 3 章 |
| **CSI** | 容器存储接口 | 第 9 章 |
| **CoreDNS** | 集群内 DNS | 第 6 章 |
| **metrics-server** | 提供资源基础指标（HPA 依赖它） | 第 12 章 |

### 概念与机制

| 英文 | 中文 / 说明 | 首次出现 |
|---|---|---|
| **Desired State** | 期望状态（你写的 `spec`） | 第 1 章 |
| **Actual State** | 实际状态（系统上报的 `status`） | 第 1 章 |
| **Reconciliation Loop** | 调和循环 | 第 1、4 章 |
| **Level-triggered** | 水平触发（状态驱动）—— K8s 的选择 | 第 4 章 |
| **Edge-triggered** | 边缘触发（事件驱动） | 第 4 章 |
| **Declarative** | 声明式（写目标，不写步骤） | 第 1 章 |
| **Imperative** | 命令式（写步骤） | 第 1 章 |
| **Idempotent** | 幂等（跑 N 次 == 跑 1 次） | 第 4 章 |
| **Atomicity** | 原子性（不会做一半）—— 与幂等正交 | 第 4 章 |
| **Eventual Consistency** | 最终一致 | 第 4 章 |
| **Optimistic Concurrency** | 乐观并发（`resourceVersion`） | 第 4 章 |
| **List-Watch** | 先全量拉、再增量订阅 | 第 4 章 |
| **Informer** | 本地缓存 + 事件分发 | 第 4 章 |
| **WorkQueue** | 去重 + 限速重试的队列 | 第 4 章 |
| **OwnerReference** | 所有权（管"管得着"、级联删除） | 第 4 章 |
| **Label / Selector** | 标签 / 选择器（管"找得到"） | 第 1、4 章 |
| **EndpointSlice** | Service 的后端地址列表（自动维护） | 第 6 章 |
| **ClusterIP** | 虚拟 IP（一组 TCP/UDP 地址改写规则） | 第 6 章 |
| **NodePort / LoadBalancer** | 对外的两种 Service 类型 | 第 6 章 |
| **Headless Service** | `clusterIP: None`，DNS 返回所有 Pod IP | 第 6 章 |
| **sessionAffinity** | 会话粘性（ClientIP） | 第 6 章 |
| **TLS Termination** | TLS 终止（在入口解密） | 第 7 章 |
| **Taint / Toleration** | 污点 / 容忍（节点拒绝 Pod） | 第 10 章 |
| **Affinity** | 亲和性（Pod 挑节点 / Pod 之间） | 第 10 章 |
| **Topology Spread** | 拓扑打散（比 antiAffinity 更好） | 第 10 章 |
| **QoS Class** | 服务质量等级（决定驱逐顺序） | 第 10 章 |
| **Compressible / Incompressible** | 可压缩（CPU）/ 不可压缩（内存） | 第 10 章 |
| **Eviction** | 驱逐（kubelet 因节点压力杀 Pod） | 第 10 章 |
| **Probe** | 探针（liveness / readiness / startup） | 第 11 章 |
| **CrashLoopBackOff** | 崩溃退避中（不是"崩了"） | 第 11 章 |
| **Backoff** | 指数退避重启 | 第 11 章 |
| **VolumeSnapshot** | 卷快照 | 第 9 章 |
| **Reclaim Policy** | 回收策略（Delete / Retain） | 第 9 章 |
| **Dynamic Provisioning** | 动态供给（按需创建存储） | 第 9 章 |
| **Access Modes** | 访问模式（RWO / ROX / RWX / RWOP） | 第 9 章 |
| **Scale Subresource** | `scale` 子资源（HPA 依赖它） | 第 12 章 |
| **Stabilization Window** | 稳定窗口（缩容前先观察） | 第 12 章 |
| **North-South / East-West** | 南北向 / 东西向流量 | 第 7 章 |
| **GitOps** | 用 Git 作为唯一事实来源 | 第 15 章 |
| **Pod Security Admission** | Pod 安全准入（替代 PSP） | 第 15 章 |
| **PodDisruptionBudget** | 自愿中断时的可用性下限 | 第 15 章 |

### 易混淆词组（重点区分）

| 容易混的 | 区别 | 章节 |
|---|---|---|
| **容器重启 vs Pod 重建** | 前者 Pod IP 不变、`RESTARTS` +1；后者 IP 变、`RESTARTS` 归零 | 第 11 章 |
| **Deployment vs Service** | 前者管"有没有人在干活"，后者管"怎么找到干活的人" | 第 1 章 |
| **Service vs Ingress** | 前者看 IP:端口（L4），后者看 HTTP 内容（L7） | 第 6、7 章 |
| **Ingress vs Ingress Controller** | 前者是声明（路由表），后者是实现（路由器） | 第 7 章 |
| **ConfigMap vs Secret** | 结构层一样，差异在策略层；Secret 默认**不加密**，只是 base64 | 第 8 章 |
| **requests vs limits** | 前者调度依据（预留），后者运行时天花板 | 第 10 章 |
| **OOMKilled vs Evicted** | 前者自己超了自己的 limits；后者节点整体撑不住 | 第 10 章 |
| **PV vs PVC** | 前者是"一套真实的房子"（集群级），后者是"需求单"（命名空间级） | 第 9 章 |
| **RWO vs RWOP** | 前者是"一个节点可读写"，后者才是"一个 Pod" | 第 9 章 |
| **NoSchedule vs NoExecute** | 前者不赶走已运行的 Pod，后者会驱逐 | 第 10 章 |
| **StatefulSet vs Operator** | 前者只给地基（身份/存储/顺序），后者封装完整运维能力 | 第 13 章 |
| **持久化 vs 备份** | PVC 防不住人为误删；备份必须独立于 K8s 存储 | 第 9 章 |
| **HPA vs VPA vs CA** | 管 Pod 数量 / 管单 Pod 资源 / 管机器数量 | 第 12 章 |

---

## 四、学习路径建议

### 如果你刚看完这门课

```
① 动手（最重要）
   bash cases/cloudnote/tools/capstone-lab.sh deploy
   bash cases/cloudnote/tools/capstone-lab.sh verify
   bash cases/cloudnote/tools/capstone-lab.sh fault

② 造一次真实故障
   选一个你自己的测试服务，故意把 liveness 探针配错、把 requests 写错、把镜像 tag 写错
   —— 亲眼看到那些状态，比读一百遍文档有用

③ 做一次完整的发布与回滚
   改一个环境变量 → 观察滚动更新 → 故意发坏版本 → 回滚
```

### 如果你要继续深入

| 方向 | 学什么 | 为什么 |
|---|---|---|
| **网络** | CNI 实现（Calico / Cilium）、Service Mesh、Gateway API | 网络是 K8s 最复杂也最容易出事的一层 |
| **存储** | CSI 驱动原理、快照与克隆、分布式存储（Ceph / Longhorn） | 数据安全是底线 |
| **安全** | RBAC 深入、OPA/Gatekeeper、Falco、供应链安全 | 生产环境的硬要求 |
| **平台工程** | Operator 开发（kubebuilder）、ArgoCD/Flux、多集群管理 | 从"用 K8s"到"做平台" |
| **源码** | client-go、controller-runtime、APIServer 的准入链 | 理解"为什么这样设计"的终极方式 |

### 三个长期习惯

1. **遇到问题先分层，再收敛** —— 不要跳步猜（第 15 章）
2. **把每次事故的根因写下来** —— 你的事故手册比任何教程都值钱
3. **记住 K8s 的边界** —— 它管"存在性"，不管"正确性"（第 11、14 章）

---

*课程结束。回到仓库 README 可以看完整课程表；任何一章都可以单独重读，因为每章都是自洽的积木块结构。*
