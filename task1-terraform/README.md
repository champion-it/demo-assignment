# Task 1 — Metabase + PostgreSQL บน Huawei Cloud (Terraform + docker-compose)

Provision **ECS เครื่องเดียว** บน Huawei Cloud ด้วย Terraform — ตอน boot cloud-init จะ install Docker + Docker Compose แล้วรัน Metabase + Postgres ด้วยกันใน docker-compose

```
                       Internet
                          │
                   ┌──────▼──────┐
                   │ EIP + ELB   │ (public 80, listener HTTP → 3000)
                   └──────┬──────┘
                          │ 3000 (SG: allow from ELB SG only)
                   ┌──────▼─────────────────────────────┐
                   │ Huawei ECS (Ubuntu 22.04)          │
                   │  cloud-init runs on first boot:    │
                   │   1. mkfs+mount /dev/vdb → /var/lib/docker
                   │   2. apt install docker-ce + compose-plugin
                   │   3. docker compose up -d           │
                   │                                     │
                   │  ┌──────────── docker host ───────┐ │
                   │  │ network: public  (bridge)      │ │
                   │  │   └── metabase :3000  ─────────┼─┘  ← 3000 published
                   │  │                                │
                   │  │ network: internal (internal!)  │   ← no host route
                   │  │   ├── metabase                 │
                   │  │   └── postgres :5432           │   ← 5432 NEVER published
                   │  │       (volume: pg_data)        │
                   │  └────────────────────────────────┘
                   │                                     │
                   │  EVS /dev/vdb → /var/lib/docker     │
                   │  (persistent across ECS rebuild)    │
                   └─────────────────────────────────────┘

Secret: CSMS — DB password (also written to /opt/metabase/.secrets/db_password
        on first boot via cloud-init write_files; 0600, root-owned)
```

## ทำไม design นี้ตอบโจทย์ทุกข้อ

| โจทย์ | คำตอบ |
|---|---|
| Provision ด้วย Terraform | provider `huaweicloud/huaweicloud` |
| โครงสร้างเหมาะสมสำหรับ Metabase + Postgres | ELB → ECS → docker-compose (Metabase + Postgres) — single-node ที่ deploy ได้ทันที |
| **DB ไม่เข้าถึงจาก public** | (1) Postgres container อยู่ใน Docker network `internal: true` — Docker block traffic ออก host (2) compose ไม่ publish port 5432 ออก ECS (3) ECS SG ก็ไม่เปิด 5432 |
| Secret management | random_password gen ใน Terraform → เก็บใน CSMS + render ลง `/opt/metabase/.secrets/db_password` (0600, root-only) — Postgres + Metabase อ่านผ่าน Docker secret file mount, ไม่ใช่ env var |

## โครงสร้างไฟล์

```
task1-terraform/
├── versions.tf                     # provider + Terraform version
├── variables.tf                    # input variables
├── main.tf                         # VPC / SG / EVS / ECS / ELB / CSMS
├── outputs.tf
├── templates/
│   ├── docker-compose.yml.tpl      # Metabase + Postgres stack
│   └── install.sh                  # boot script — install Docker + start stack
├── terraform.tfvars.example
├── .gitignore
└── README.md
```

## Prerequisites

- **Terraform >= 1.5**
- Huawei Cloud account + AK/SK — Console → My Credentials
- IAM permissions: `VPC / ECS / ELB / EVS / CSMS / IMS ReadOnly`
- Ubuntu 22.04 IMS image ID ของ region ที่จะ deploy

## วิธี Deploy

```bash
# 1. ตั้ง credentials เป็น env var
export HW_ACCESS_KEY="xxxxx"
export HW_SECRET_KEY="xxxxx"

# 2. คัดลอก tfvars + ใส่ image ID
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars     # แก้อย่างน้อย metabase_image_id

# 3. Deploy
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 4. รอ ~3-5 นาทีให้:
#    - cloud-init format + mount EVS
#    - apt install docker (~60s)
#    - docker pull metabase + postgres (~60s)
#    - Metabase first-run schema migration (~30s)
terraform output metabase_url
# → http://<EIP>
```

## วิธีทดสอบ

| ข้อที่ต้องตรวจ | วิธี |
|---|---|
| Metabase ใช้งานได้ | `curl $(terraform output -raw metabase_url)/api/health` → `{"status":"ok"}` |
| ELB backend Healthy | Console → ELB → listener → backend → `Healthy` |
| **DB ไม่ public (ระดับ docker)** | SSH เข้า ECS → `docker network inspect metabase_internal` → ดูว่ามี `"Internal": true` |
| **DB ไม่ public (ระดับ host)** | SSH เข้า ECS → `ss -tlnp \| grep 5432` → **ไม่ควรเจอ** (postgres bind ใน container เท่านั้น) |
| **DB ไม่ public (ระดับ network)** | จากเครื่องอื่น `nc -zv <ECS-public-IP> 5432` → connection refused (SG ไม่เปิด) |
| Stack รันด้วย compose | SSH เข้า ECS → `docker compose -f /opt/metabase/docker-compose.yml ps` |
| Secret ไม่อยู่ใน plaintext | `cat /opt/metabase/.secrets/db_password` ต้องอ่านได้เฉพาะ root (0600) |
| Persistent ผ่าน EVS | `df -h /var/lib/docker` ต้องเห็น `/dev/vdb` mount อยู่ |

## Configuration & Secret Management

| Config | Source |
|---|---|
| DB password | `random_password` → CSMS + cloud-init `write_files` → docker-compose secret file |
| HW AK/SK | env var (ห้าม hardcode / ห้าม commit) |
| Metabase env (non-secret) | docker-compose env block — Java timezone, MB_DB_HOST ฯลฯ |
| Network CIDR / image / flavor | `terraform.tfvars` |

### Secret rotation
1. แก้ password ใน CSMS (Console หรือ CLI)
2. SSH เข้า ECS → update `/opt/metabase/.secrets/db_password`
3. `docker compose down && docker compose up -d`

### Production hardening (ที่ assignment นี้ยังไม่ได้ทำ)
- ใช้ **IAM Agency** ผูก ECS → cloud-init ดึง password จาก CSMS API ที่ runtime แทนการฝังใน user_data
- HTTPS listener + SCM cert
- Postgres backup → OBS รายวัน (cronjob `pg_dump`)
- Log forwarding → LTS

## Assumptions

1. **Region default `ap-southeast-3`** (Singapore) — ปรับได้
2. **Single ECS, single AZ** — ไม่ HA; production ควรย้าย DB ไป RDS managed (multi-AZ HA + auto-backup)
3. **HTTP only** — listener 80 ไม่มี cert (ใส่ `huaweicloud_elb_certificate` + listener 443 ในของจริง)
4. **`metabase_image_id` กรอกเอง** — IMS ID ต่างกันตาม region และ update ตามเวลา
5. **DB password ใน user_data** — visible ผ่าน metadata service (จาก inside ECS เท่านั้น). ของ prod ใช้ IAM Agency + CSMS API
6. **EVS = single disk, single AZ** — ไม่ HA; backup ผ่าน EVS snapshot (ไม่อยู่ใน Terraform นี้)

## Destroy

```bash
terraform destroy
```

> ⚠️ EVS volume จะถูกลบด้วย → **ข้อมูล Postgres หาย**. ทำ snapshot ก่อนถ้าจำเป็น:  
> `huaweicloud evs snapshot create --volume-id <id>`

## Future Improvements

- ย้าย Postgres ไป Huawei **RDS managed** (HA + auto-backup)
- ย้าย Metabase ไป **CCE (K8s)** + Helm chart → HPA + rolling update
- เพิ่ม **WAF** หน้า ELB
- IAM Agency + CSMS read-at-runtime (ไม่ฝัง password ใน user_data)
- HTTPS + SCM cert
- Backup script `pg_dump` → OBS ผ่าน cronjob
- LTS log forwarding (Metabase access log + Postgres slow query)
- State backend ย้ายขึ้น **OBS** + lock
