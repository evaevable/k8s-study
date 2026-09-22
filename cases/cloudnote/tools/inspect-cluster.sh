#!/usr/bin/env bash
# ============================================================================
# 第 3 章配套工具：集群透视脚本
#
# 一次性把控制面与数据面的关键信息打印出来，方便对照章节内容阅读。
# 只读操作，不会修改集群里的任何东西。
#
# 用法：
#   bash cases/cloudnote/tools/inspect-cluster.sh
#   bash cases/cloudnote/tools/inspect-cluster.sh cloudnote   # 指定要观察的命名空间
# ============================================================================
set -uo pipefail

NS="${1:-cloudnote}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "找不到 kubectl，请先安装并配置好 kubeconfig。"
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "连不上集群。请先按第 1 章【积木 1-10】起一个集群。"
  exit 1
fi

line() { printf '\n\033[1m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }
title() { printf '\n\033[1;36m## %s\033[0m\n' "$1"; }

title "1. 集群基本信息（API Server 地址就是 6443 端口）"
kubectl cluster-info

title "2. 控制面与数据面的组件清单"
line
printf '控制面通常位于 kube-system，且以静态 Pod 形式出现（名字带节点名后缀）\n'
kubectl get pods -n kube-system -o wide 2>/dev/null || echo "（无权限读取 kube-system）"

title "3. 节点状态（Ready / NotReady，以及各自的角色）"
kubectl get nodes -o wide
line
printf '节点上的可分配资源：\n'
kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods'

title "4. 节点上的污点（Scheduler 会据此过滤节点）"
for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  taints=$(kubectl get node "$n" -o jsonpath='{.spec.taints[*].key}')
  printf '  %-40s %s\n' "$n" "${taints:-<无污点>}"
done

title "5. 谁在当控制面的 Leader（选主结果）"
kubectl get lease -n kube-system 2>/dev/null || echo "（读不到 Lease 对象）"

title "6. API Server 暴露的 API 组（YAML 里 apiVersion 的来源）"
kubectl api-versions

title "7. 最常用的资源类型（K8s 的「对象字典」节选）"
kubectl api-resources --namespaced=true 2>/dev/null | head -25

title "8. 健康检查端点（可以直接用 curl 访问）"
line
printf '想看原始 JSON，先执行：kubectl proxy --port=8001 &\n'
printf '然后：\n'
printf '  curl -s http://localhost:8001/healthz\n'
printf '  curl -s http://localhost:8001/readyz?verbose\n'
printf '  curl -s http://localhost:8001/api/v1/nodes | head -30\n'

title "9. 命名空间 ${NS} 里的当前状态"
kubectl get all -n "$NS" 2>/dev/null || echo "（命名空间 ${NS} 不存在或为空）"

title "10. 最近的集群事件（按时间倒序，只取 15 条）"
kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -15

printf '\n\033[1;32m完成。\033[0m对照第 3 章正文逐节阅读效果最佳。\n\n'
