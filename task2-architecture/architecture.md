# Architecture — Internal Web Application

> Full diagram: [`diagrams/architecture.svg`](diagrams/architecture.svg) (เปิดในเบราว์เซอร์ได้เลย)

## 1. ภาพรวม

ระบบ web application ภายในองค์กรที่ประกอบด้วย 3 service หลัก:

| Service | Tech | หน้าที่ |
|---|---|---|
| **Web** | Next.js  | UI ให้ผู้ใช้ภายใน |
| **API** | FastAPI  | REST/gRPC API ต่อกับ DB + external sources |
| **Airflow** | Apache Airflow (KubernetesExecutor) | ETL / batch jobs / data sync |

รันทั้งหมดบน **Huawei CCE (managed Kubernetes)** โดยแยก namespace:

| Namespace | สิ่งที่อยู่ข้างใน |
|---|---|
| `app` | Web + API |
| `airflow` | Airflow webserver / scheduler / KubernetesExecutor pods |
| `platform` | ArgoCD, Vault, Vault Secrets Operator (VSO), Ingress controller |
| `monitoring` | Prometheus, Loki, Grafana, Alertmanager |

## 2. องค์ประกอบสำคัญ

### 2.1 Kubernetes (CCE)
- **1 cluster ต่อ environment** (dev / staging / prod) — แยกกันสมบูรณ์เพื่อ blast radius
- ใช้ **Kustomize** เป็น config overlay: `base/` + `overlays/{dev,staging,prod}`
- **ArgoCD** ติดตั้งใน namespace `platform` ของแต่ละ cluster → GitOps pull model
- **HPA** บน Web + API (CPU + custom metric จาก Prometheus)
- **Airflow** ใช้ KubernetesExecutor — task แต่ละตัว spawn pod เอง ไม่ต้อง pre-provision worker

### 2.2 Data & Storage (managed services)
- **RDS PostgreSQL** — app DB + Airflow metadata (คนละ database ใน instance เดียว หรือแยก instance สำหรับ prod)
- **DCS (Redis)** — API cache + Celery/queue broker หากจำเป็น
- **OBS (Object Storage)** — file upload, Airflow logs, build artifacts, Vault snapshots, Velero backups

### 2.3 Ingress / Edge
- **ELB**  + **TLS cert จาก SCM** → terminate HTTPS ที่ ELB
- **Cloud DNS** → domain เช่น `app.corp.internal`, `airflow.corp.internal`, `argocd.corp.internal`, `vault.corp.internal`

### 2.4 External Connectivity
| ปลายทาง | วิธีเชื่อม |
|---|---|
| 3rd-party APIs (public internet) | NAT Gateway + outbound allowlist |
| On-premise DB | **Direct Connect** หรือ **VPN** ผูกกับ VPC |
| อีก cloud provider | **VPC Peering** หรือ IPsec VPN |


### 2.5 Secret & Config Management — **HashiCorp Vault (self-hosted ใน CCE)**

Vault เป็น **single source of truth ของ secret ทั้งหมด** — ไม่มี secret อยู่ใน Git, Kustomize หรือ ArgoCD repo

#### Topology
- Vault ติดตั้งใน namespace `platform` 
- Snapshot ขึ้น **OBS** อัตโนมัติทุกชั่วโมง (cronjob)
- Audit log → Loki 

#### Auth methods ที่เปิด
| Method | ใครใช้ | ทำอะไร |
|---|---|---|
| **Kubernetes auth** | pod ใน CCE | ใช้ ServiceAccount JWT แลก Vault token → อ่าน secret ของ namespace ตัวเอง |
| **OIDC** (GitLab/Okta) | คน (DevOps/SRE) | login Vault UI / CLI ผ่าน SSO |
| **AppRole** | GitLab CI runner | CI ดึง secret ตอน build/deploy ผ่าน role-id + secret-id (rotated) |

#### Secret engines ที่ใช้
| Engine | Path | Use case |
|---|---|---|
| **KV v2** | `kv/{env}/{service}` | static secrets (API key, third-party token) |
| **Database** | `database/creds/{role}` | **dynamic credentials** — Vault สร้าง user PostgreSQL ชั่วคราว TTL 1 ชั่วโมง |
| **Transit** | `transit/keys/{key}` | encryption-as-a-service (เข้ารหัสคอลัมน์ sensitive ใน DB โดยไม่ต้องจัดการ key เอง) |
| **PKI** | `pki/issue/{role}` | สร้าง mTLS cert สำหรับ service-to-service |

#### วิธีที่ pod ใน app/airflow ใช้ secret — **Vault Secrets Operator (VSO)**

VSO เป็น operator อย่างเป็นทางการของ HashiCorp ที่ sync secret จาก Vault → k8s `Secret` ผ่าน CRD — ตัวเดียวรองรับทั้ง static, dynamic, และ PKI cert

```
Vault (KV / database / pki engines)
   ▲
   │ VSO subscribe + sync (ใช้ Kubernetes auth)
   │
VaultStaticSecret  / VaultDynamicSecret  / VaultPKISecret CR
            (ใน gitops repo)
   │
   ▼
Kubernetes Secret (managed by VSO) ──► pod env / volume mount
```

**CRD ที่ใช้**

| CRD | Use case | ตัวอย่าง |
|---|---|---|
| `VaultConnection` | คอนฟิก endpoint + TLS ของ Vault (cluster-scoped, ตั้งครั้งเดียว) | `address: http://vault.platform.svc:8200` |
| `VaultAuth` | คอนฟิก auth method (k8s ServiceAccount → Vault role) | `method: kubernetes`, `role: api` |
| `VaultStaticSecret` | sync KV v2 → k8s Secret (refresh ทุก N วินาที) | API key, third-party token |
| `VaultDynamicSecret` | ขอ dynamic credentials → k8s Secret + **auto-rotate** ก่อน lease หมด | DB user TTL 1h, AWS STS, RabbitMQ |
| `VaultPKISecret` | issue cert จาก PKI engine + auto-renew | mTLS cert ระหว่าง service |

- Git เก็บแค่ CR (ไม่มี secret value)
- VSO sync เป็น native k8s `Secret` → pod consume แบบมาตรฐาน (envFrom / volume mount)
- **Dynamic secret** VSO หมุน lease ให้เอง + rolling-restart pod เมื่อ secret rotate (configurable)


#### Non-secret config
- เก็บใน **ConfigMap** + Kustomize overlay ต่อ env
- Feature flag, log level, URL ของ external service, flag toggle ฯลฯ



### 2.6 Observability
| ด้าน | เครื่องมือ | เก็บที่ไหน |
|---|---|---|
| Metrics | Prometheus + kube-state-metrics + node-exporter | in-cluster + remote write → Thanos / Huawei AOM |
| Logs | Loki (promtail DaemonSet) | OBS backend |
| Traces | OpenTelemetry + Tempo | Tempo backend |
| Dashboards | Grafana | shared |
| Alerting | Alertmanager → Discord / LINE Notify / email / Slack | |

## 3. Environment Isolation

| มิติ | dev | staging | prod |
|---|---|---|---|
| CCE cluster | `cce-dev` | `cce-staging` | `cce-prod` (multi-AZ) |
| VPC | dev VPC | staging VPC | prod VPC (peered กับ shared services) |
| RDS | single-AZ, small | single-AZ, prod-size | **multi-AZ HA** + read replica |
| Vault | 3-node HA, share KMS key | 3-node HA, แยก KMS key | 3-node HA + DR cluster (Performance Replication ไป cross-region), แยก KMS key |
| Domain | `*.dev.corp.internal` | `*.staging.corp.internal` | `*.corp.internal` |
| IAM Agency | dev agency | staging agency | prod agency (least-priv, separate audit log) |
| Data | synthetic | masked-prod snapshot | real |

Terraform state แยก per env (`envs/dev/`, `envs/staging/`, `envs/prod/`) — **ไม่ใช้** workspace เดียวร่วมกัน เพื่อให้ plan/apply ไม่เผลอกระทบ prod

## 4. Reliability

### 4.1 Prevention
- **HPA + PodDisruptionBudget** ทุก service
- **Readiness / Liveness / Startup probes** ของแต่ละ pod
- **Resource requests + limits** กันปัญหา noisy-neighbor
- **NetworkPolicy** default-deny ทุก namespace
- **Image scan (Trivy)** เป็น CI gate — block `HIGH/CRITICAL`
- **Database migration** รันเป็น `Job` ก่อน rollout (ArgoCD sync wave -1)
- **Vault HA**: 3-node Raft, quorum loss = read-only mode (ไม่หยุดให้บริการ static secret cache)

### 4.2 Monitoring
- **Health check** 3 ระดับ:
  - K8s probe (pod) → restart pod
  - ELB health check → remove instance
  - Synthetic check (Blackbox exporter) → alert team
- **Key SLIs**: request latency p95/p99, error rate, saturation (CPU/mem/DB connections), Airflow DAG success rate / SLA miss
- **Vault SLIs**: seal status, leader election, request latency, token TTL distribution
- **Golden dashboards** ต่อ service ใน Grafana
- **Log**: structured JSON, correlation ID, PII-redacted

### 4.3 Incident Response
- **Alert routing**: severity-based → Alertmanager → Discord / Slack 

- **Backup**:
  - RDS automated backup + cross-region snapshot รายวัน
  - **Vault snapshot** → OBS รายชั่วโมง + restore drill ทุกเดือน
  - Velero backup ของ K8s manifests + PV
- **Vault sealed scenario**: KMS auto-unseal ทำงานเอง; ถ้า KMS ล่มต้อง break-glass operator key (เก็บใน sealed envelope, 3-of-5 Shamir)
- **Post-mortem**: blameless, tracked ใน wiki, action items กลับเข้า backlog

## 5. Security Summary

- RDS / DCS / OBS: private endpoint only, ไม่มี EIP
- Vault API: cluster-internal เท่านั้น (`vault.platform.svc:8200`); 
- Cluster API endpoint: whitelist CIDR ของ office/VPN
- mTLS ระหว่าง service ผ่าน Vault PKI engine (cert TTL 24 ชม., auto-renew)
- Audit log ของ CCE + RDS + Vault ส่งเข้า LTS → immutable retention 1 ปี
- Rotation: Vault dynamic DB creds หมุนทุก 1 ชม.; static KV secret rotate ทุก 90 วัน (Vault rotate API + ESO sync)
- Vault token: short TTL (1 ชม.) + renewable; root token disabled หลัง bootstrap
