# OpenAppSec WAF 部署文档

> **主机**: 康邻堡垒机 k8s-master01 (118.31.175.168)
> **部署日期**: 2026-09-21
> **部署方式**: podman + docker-compose（单机非 K8s）
> **镜像**: `agent-unified.1.1.36.tar`（本地加载）
> **高级模型**: `open-appsec-advanced-model.tgz`（官网下载，2024-12-01 版本，12MB ML 流量打分模型）

---

## 一、部署架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         118.31.175.168 ( Rocky Linux 9 )                  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                    Podman Pod: appsec-agent                          │ │
│  │                                                                      │ │
│  │  ┌────────────────────────────────────────────────────────────────┐ │ │
│  │  │          容器: appsec-agent (agent-unified:1.1.36)             │ │ │
│  │  │                                                                │ │ │
│  │  │  ┌──────────────┐    ┌──────────────────────────────┐         │ │ │
│  │  │  │ nginx master │    │  cp-nano-http-transaction- │         │ │ │
│  │  │  │ (port 80)    │───▶│  handler ×8                │         │ │ │
│  │  │  └──────────────┘    │  (WAF 检测引擎)             │         │ │ │
│  │  │         │             └──────────────────────────────┘         │ │ │
│  │  │         │                        │                             │ │ │
│  │  │         ▼                        ▼                             │ │ │
│  │  │  ┌──────────────────────────────────────────────┐             │ │ │
│  │  │  │   /dev/shm/check-point/ (共享内存)          │             │ │ │
│  │  │  │   cp-nano-http-transaction-handler-{1..8}  │             │ │ │
│  │  │  │   cp-nano-attachment-registration          │             │ │ │
│  │  │  └──────────────────────────────────────────────┘             │ │ │
│  │  │                        ▲                                       │ │ │
│  │  │                        │                                       │ │ │
│  │  │                ┌──────┴──────┐                                 │ │ │
│  │  │                │   Backend   │                                 │ │ │
│  │  │                │ 3002 (Python │                                 │ │ │
│  │  │                │ server)      │                                 │ │ │
│  │  │                └─────────────┘                                 │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  系统进程 (与容器独立):                                                    │
│  ┌─────────────────┐         ┌─────────────────┐                        │
│  │ 系统 nginx      │         │ Python 后端     │                        │
│  │ nginx.service   │         │ server/app.py   │                        │
│  │ 监听 :18000     │         │ 监听 :3002      │                        │
│  │ (RPM nginx/1.30.4)│       └─────────────────┘                        │
│  └─────────────────┘                                                      │
└─────────────────────────────────────────────────────────────────────────────┘

外部流量:
用户 ──▶ 118.31.175.168:80 ──▶ nginx(容器内) ──▶ WAF检测 ──▶ Backend :3002
用户 ──▶ 118.31.175.168:18000 ──▶ 系统 nginx.service (与 openappsec 完全无关)
```

---

## 二、流量请求通路

```
正常请求流程:
┌──────────┐     ┌─────────────────────────────────────────────────────────┐
│  Client   │     │                    appsec-agent 容器                      │
│           │     │                                                         │
│ GET /     │────▶│ iptables/nftables (host network mode 直接进入)          │
│           │     │                         │                                │
│          ▼     │  ┌─────────────────────▼──────────────┐                   │
│  ┌──────────┐  │  │  nginx master (pid inside container) │               │
│  │  防火墙   │  │  │  /etc/nginx/nginx.conf             │               │
│  │  (如有)   │  │  │  /etc/nginx/conf.d/default.conf   │               │
│  └──────────┘  │  └───────────────┬────────────────────┘                   │
│           │     │                  │                                        │
│           │     │    ┌─────────────▼────────────────────┐                   │
│           │     │    │  ngx_cp_attachment_module        │                   │
│           │     │    │  (nginx 动态模块)                │                   │
│           │     │    │  检测请求 → 共享内存 socket     │                   │
│           │     │    └─────────────┬────────────────────┘                   │
│           │     │                  │                                        │
│           │     │  ┌───────────────▼────────────────────┐                   │
│           │     │  │  cp-nano-http-transaction-handler  │                   │
│           │     │  │  (8 个进程, WAF 检测引擎)          │                   │
│           │     │  │  读取共享内存中的请求               │                   │
│           │     │  │  检查: SQL注入/XSS/路径遍历等    │                   │
│           │     │  └───────────────┬────────────────────┘                   │
│           │     │                  │ 检查通过                                │
│           │     │  ┌───────────────▼────────────────────┐                   │
│           │     │  │  nginx proxy_pass                   │                   │
│           │     │  │  proxy_pass http://127.0.0.1:3002  │                   │
│           │     │  └──────────────────────────────────────┘                   │
│           │     │                         │                                │
│           │     │               ┌─────────▼─────────┐                     │
│           │     │               │ Backend:3002      │                     │
│           │     │               │ (Python server)   │                     │
│           │     │               └───────────────────┘                     │
│           │     └───────────────────────────────────────────────────────────┘│
│           │     │  响应原路返回                                              │
│   ◀───────┘     └───────────────────────────────────────────────────────────┘│

攻击请求流程 (被拦截):
┌──────────┐     ┌─────────────────────────────────────────────────────────┐
│  Client   │     │                    appsec-agent 容器                      │
│           │     │                                                         │
│ GET /?id= │────▶│ nginx → attachment_module → handler 检测到恶意特征       │
│  OR 1=1   │     │                                                         │
│           │     │  ┌──────────────────────────────────────────────────┐   │
│           │     │  │ cp-nano-http-transaction-handler                 │   │
│           │     │  │ 阻断请求 → 返回 403 Forbidden                    │   │
│           │     │  │ 自定义响应由 local_policy.yaml 定义              │   │
│           │     │  └──────────────────────────────────────────────────┘   │
│   ◀───────┘     │                                                         │
│  HTTP 403       └─────────────────────────────────────────────────────────┘│
│  (WAF 拦截)                                                          │
└──────────┘                                                            │
```

---

## 三、部署过程

### 3.1 前置条件

```bash
# 确认 podman / docker-compose 已安装
podman --version    # 示例: podman version 4.9.4
podman-compose --version

# 确认本地镜像已加载
podman images | grep unified
# ghcr.io/openappsec/agent-unified   1.1.36   xxx   2 hours ago

# 确认后端服务已启动 (端口 3002)
ss -tlnp | grep :3002
# LISTEN 0  128  127.0.0.1:3002  *:*  users:(("python",pid=72100))
```

### 3.2 目录结构

```
/opt/waf/open-appsec-deployment/
├── docker-compose.yaml        # 主编排文件 (简化版，仅 agent-unified)
├── .env                      # 环境变量
├── appsec-config/            # Agent 配置 (挂载到 /etc/cp/conf)
├── appsec-data/              # Agent 数据目录 (挂载到 /etc/cp/data)
├── appsec-logs/              # 日志目录 (挂载到 /var/log/nano_agent)
├── appsec-localconfig/
│   └── local_policy.yaml     # 本地声明式策略 (挂载到 /ext/appsec)
├── nginx-config/
│   └── default.conf          # nginx 代理配置 (挂载到 /etc/nginx/conf.d)
└── appsec-smartsync-storage/ # 学习数据存储
```

### 3.3 关键配置文件

#### docker-compose.yaml (最终版)

```yaml
version: "3.9"
services:
  appsec-agent:
    image: ghcr.io/openappsec/agent-unified:1.1.36
    container_name: appsec-agent
    environment:
      - SHARED_STORAGE_HOST=appsec-shared-storage
      - LEARNING_HOST=appsec-smartsync
      - TUNING_HOST=appsec-tuning-svc
      - https_proxy=${APPSEC_HTTPS_PROXY}
      - user_email=${APPSEC_USER_EMAIL}
      - AGENT_TOKEN=${APPSEC_AGENT_TOKEN}
      - autoPolicyLoad=${APPSEC_AUTO_POLICY_LOAD}
      - registered_server="NGINX"
    network_mode: host      # 关键: 使用宿主机网络, nginx 直接绑定宿主机端口 80
    ipc: host               # 关键: 共享内存通信
    restart: unless-stopped
    volumes:
      - ${APPSEC_CONFIG}:/etc/cp/conf
      - ${APPSEC_DATA}:/etc/cp/data
      - ${APPSEC_LOGS}:/var/log/nano_agent
      - ${APPSEC_LOCALCONFIG}:/ext/appsec
      - /mnt/check-point-shm:/dev/shm/check-point   # 共享内存 (WAF 检测通道)
      - ${NGINX_CONFIG}:/etc/nginx/conf.d             # nginx 配置文件
    command: /cp-nano-agent
```

#### nginx-config/default.conf

```nginx
server {
    listen       80;
    server_name  _;

    # openappsec WAF 过滤器
    # ngx_cp_attachment_module 通过共享内存 /dev/shm/check-point 与 agent 通信

    location / {
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }
}
```

#### appsec-localconfig/local_policy.yaml (关键)

```yaml
policies:
  default:
    triggers:
    - appsec-default-log-trigger
    mode: prevent-learn    # 关键: prevent=拦截, learn=学习
    practices:
    - webapp-default-practice
    custom-response: appsec-default-web-user-response

practices:
  - name: webapp-default-practice
    web-attacks:
      protections:
        csrf-protection: inactive
        error-disclosure: inactive
        non-valid-http-methods: false
        open-redirect: inactive
      minimum-confidence: critical   # 只拦截高置信度攻击

custom-responses:
  - name: appsec-default-web-user-response
    mode: response-code-only
    http-response-code: 403         # 拦截返回 403
```

### 3.4 部署命令

```bash
# 1. 清理旧环境 (如需要)
cd /opt/waf/open-appsec-deployment
podman-compose down
podman pod rm -f $(podman pod ps -q)
pkill -9 -f 'go/bin/app'    # 杀掉可能的残留进程

# 2. 启动 (不使用 COMPOSE_PROFILES=standalone, 避免辅助服务端口冲突)
podman-compose up -d

# 3. 等待容器完全启动
sleep 25

# 4. 确认 nginx 占用端口 80
ss -tlnp | grep :80

# 5. 让 nginx 重载配置 (确保 default.conf 生效)
podman exec appsec-agent nginx -t
podman exec appsec-agent nginx -s reload

# 6. 测试正常请求
curl http://127.0.0.1:80/
# 应返回后端 3002 的 HTML 内容

# 7. 测试 WAF 拦截
curl 'http://127.0.0.1:80/?id=1%20OR%201%3D1'  # SQL注入 → 403
curl 'http://127.0.0.1:80/?q=%3Cscript%3E'       # XSS → 403
```

---

## 四、问题排查与解决记录

### 4.1 问题一: standalone profile 的 postgres:18 拉取失败

**现象**:
```
Error: short-name resolution enforced but cannot prompt without a TTY
appsec-db 容器启动失败
```

**根因**: `docker-compose.yaml` 带了 `COMPOSE_PROFILES=standalone`，podman-compose 会尝试拉取 `postgres:18` 镜像（非全量路径），无 TTY 交互式确认导致拉取失败。

**解决**: 移除 `.env` 中的 `COMPOSE_PROFILES=standalone`，改为直接 `podman-compose up -d` 启动仅 `appsec-agent` 的服务（`agent-unified` 包已内置 postgres 客户端，无需额外镜像）。

---

### 4.2 问题二: appsec-shared-storage 容器抢占了 port 80

**现象**:
```
nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address in use)
nginx: still could not bind()
```

**根因**: `agent-unified` 镜像内置了 `/go/bin/app` (Go 二进制)，`smartsync-shared-files:1.1.36` 镜像也用同一个 `/go/bin/app` 作为 Entrypoint。在 `network_mode: host` 模式下，两个容器都试图绑定 host 端口，且 Go 程序无需 root 权限即可绑定低端口（通过 `CAP_NET_BIND_SERVICE`）。

**排查过程**:
```bash
# 发现有两个 /go/bin/app 进程在运行
ps aux | grep '/go/bin/app'
# root  4089989  ...  /go/bin/app   ← shared-storage 的进程
# root  4087159  ...  nginx: master  ← agent 的 nginx

# 查看进程所属容器
cat /proc/<pid>/cgroup
# 0::/machine.slice/machine-libpod_pod_xxx.slice/...container

# 确认 shared-storage 容器
podman ps | grep shared
# 07b81c3ac8b8  appsec-shared-storage  ghcr.io/openappsec/smartsync-shared-files:1.1.36
```

**解决**: 不使用 standalone profile，`appsec-shared-storage` 和 `appsec-smartsync` 等辅助容器不启动，避免端口冲突。`agent-unified` 镜像本身已集成所有必要组件。

---

### 4.3 问题三: nginx 配置文件未挂载进容器

**现象**:
```
curl http://127.0.0.1:80/  →  404 page not found
# 容器内 /etc/nginx/conf.d/ 为空
```

**根因**: `agent-unified` 镜像内的 entrypoint (`/cp-nano-agent`) 脚本会自动重新创建 `/etc/nginx/conf.d/` 目录并写入默认配置，原有挂载的 `nginx-config/` 内容被覆盖。`podman-compose.yaml` 中没有声明 `${NGINX_CONFIG}`  volume 挂载。

**排查过程**:
```bash
# 确认容器内配置文件状态
podman exec appsec-agent ls /etc/nginx/conf.d/
# (空目录)

# 对比宿主机配置
cat /opt/waf/open-appsec-deployment/nginx-config/default.conf
# (有正确配置)

# 在容器内手动写入配置后测试
podman exec appsec-agent sh -c 'cat > /etc/nginx/conf.d/default.conf <<EOF ...'
podman exec appsec-agent nginx -s reload
curl http://127.0.0.1:80/  →  后端页面出现
```

**解决**: 在 `docker-compose.yaml` 的 `appsec-agent` service 中补加 volume 声明：
```yaml
volumes:
  - ${NGINX_CONFIG}:/etc/nginx/conf.d    # 关键: 将宿主机 nginx 配置挂入容器
```

---

### 4.4 问题四: /go/bin/app 僵尸进程不断复活 port 80

**现象**:
```
pkill -9 -f '/go/bin/app'
# 立即有新 PID 的 /go/bin/app 重新绑定 port 80
```

**根因**: `appsec-shared-storage` 容器内的 `/go/bin/app` 主进程由 conmon (容器运行时监控进程) 管理。即使手动 `kill -9`，conmon 会在 5 秒内检测到主进程退出并自动重启容器，导致 port 80 一直被占用。

**解决**: 直接停止并删除容器，而非杀死进程：
```bash
podman stop appsec-shared-storage
# conmon 不再复活，port 80 彻底释放
```

---

## 五、容器内部进程结构

```
appsec-agent 容器内进程树:
──────────────────────────────────────────────────────────
root  817   nginx: master process nginx (监听容器内 port 80)
root  10869 nginx: worker process (×8, 处理连接)
root  1383  cp-nano-http-transaction-handler --id=1  ← WAF 核心检测引擎
root  1426  cp-nano-http-transaction-handler --id=2
root  1469  cp-nano-http-transaction-handler --id=3
root  1521  cp-nano-http-transaction-handler --id=4
root  1567  cp-nano-http-transaction-handler --id=5
root  1613  cp-nano-http-transaction-handler --id=6
root  1659  cp-nano-http-transaction-handler --id=7
root  1705  cp-nano-http-transaction-handler --id=8
root  1004  cp-nano-orchestration              ← 主编排/管理进程
root  1037  cp-nano-attachment-registrator   ← Cloud 注册
root  1071  cp-nano-agent-cache               ← Redis 缓存 (127.0.0.1:6379)
root  939   cp-nano-watchdog                  ← 看门狗, 监控进程存活
root  1     {cp-nano-agent} /bin/bash /cp-nano-agent  ← 容器 entrypoint
──────────────────────────────────────────────────────────

共享内存通道 /dev/shm/check-point/:
  cp-nano-http-transaction-handler-{1..8}   ← 8个检测引擎 socket
  cp-nano-attachment-registration          ← Cloud 注册 socket
  cp-nano-attachment-registration-expiration-socket
```

---

## 六、验证测试结果

| 测试场景 | 命令 | 预期状态码 | 实际结果 |
|---|---|---|---|
| 正常请求 | `curl http://127.0.0.1:80/` | 200 | ✅ 200 |
| SQL 注入 | `curl 'http://127.0.0.1:80/?id=1 OR 1=1'` | 403 | ✅ 403 |
| XSS 攻击 | `curl 'http://127.0.0.1:80/?q=<script>alert(1)</script>'` | 403 | ✅ 403 |
| 路径遍历 | `curl 'http://127.0.0.1:80/../../../etc/passwd'` | 400 | ✅ 400 |

---

## 七、与系统 nginx 的关系

系统中有两套独立的 nginx，**完全隔离，互不影响**：

| 项目 | 进程 | 端口 | 来源 | 配置文件 |
|---|---|---|---|---|
| 系统 nginx | `nginx.service` (RPM) | **18000** | 操作系统包 | `/etc/nginx/nginx.conf` |
| openappsec nginx | `appsec-agent` 容器内 | **80** | agent-unified 镜像 | `/opt/waf/open-appsec-deployment/nginx-config/` |

---

## 九（续）、后续建议

1. **配置 https**: 当前仅监听 80，建议配置证书启用 443
2. **调整防护级别**: `local_policy.yaml` 中 `minimum-confidence: critical` 可降为 `high` 以拦截更多攻击
3. **持久化配置**: 将 `local_policy.yaml` 的改动通过 Git 管理
4. **日志集中**: 当前日志输出到 `appsec-logs/` 和 `stdout`，建议接入 ELK/Graylog
5. **standalone profile 完整部署**: 解决 postgres 镜像拉取问题后，可启用完整的学习和调优服务
6. **模型更新**: 定期从 [openappsec.io](https://www.openappsec.io) 下载新版 `open-appsec-advanced-model.tgz`，覆盖后 `podman-compose restart` 即可

---

## 八、高级 ML 模型

### 8.1 模型包信息

| 项目 | 值 |
|---|---|
| 文件 | `/opt/waf/dockerimages/open-appsec-advanced-model.tgz` |
| 大小 | 824KB（压缩）/ 12MB（解压后 waap.data）|
| 版本日期 | 2024-12-01 |
| 模型文件 | `waap.data`（ML 流量威胁打分模型） |
| License | Check Point ML Model License V2 |

### 8.2 加载原理

容器启动时，agent 检查 `/advanced-model/open-appsec-advanced-model.tgz` 是否存在：
- 存在 → 自动解压 `waap.data` 到 `/etc/cp/conf/waap/waap.data`，覆盖镜像内置默认模型
- 不存在 → 使用镜像内置的默认 `waap.data`

### 8.3 验证模型是否生效

```bash
# 检查容器内模型文件时间戳（应为 2024-12-01）
podman exec appsec-agent stat /etc/cp/conf/waap/waap.data | grep Modify
# Modify: 2024-12-01 09:56:47.000000000 +0000  ← 高级模型

# 对比镜像原始模型时间戳（应为 2026-09-20）
podman exec appsec-agent stat /etc/cp/conf/waap/4.data | grep Modify
# Modify: 2026-09-20 22:00:00.021769301 +0000  ← 镜像内置模型

# 确认模型文件大小（高级模型约 12MB）
podman exec appsec-agent ls -lh /etc/cp/conf/waap/waap.data
# -rwxr-xr-x 1 8619 80 12M Dec  1  2024 /etc/cp/conf/waap/waap.data
```

### 8.4 模型更新步骤

如需更新为新版模型：
```bash
# 1. 将新 tgz 包放入原位置（覆盖原文件）
cp /path/to/new/open-appsec-advanced-model.tgz /opt/waf/dockerimages/open-appsec-advanced-model.tgz

# 2. 重启容器使模型生效
cd /opt/waf/open-appsec-deployment
podman-compose restart

# 3. 验证
podman exec appsec-agent stat /etc/cp/conf/waap/waap.data | grep Modify
```

### 8.5 docker-compose.yaml 中的模型挂载

```yaml
volumes:
  - /opt/waf/dockerimages/open-appsec-advanced-model.tgz:/advanced-model/open-appsec-advanced-model.tgz:ro
```
