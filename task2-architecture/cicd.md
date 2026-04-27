# CI/CD Pipeline

> Flow diagram: [`diagrams/cicd-pipeline.svg`](diagrams/cicd-pipeline.svg) (เปิดในเบราว์เซอร์ได้เลย)

## 1. หลักการ

- **CI = GitLab CI** (build, test, scan, push image, bump gitops)
- **CD = ArgoCD + Kustomize** บน CCE (GitOps pull model)
- **Secret = Vault** — CI ใช้ AppRole, runtime ใช้ Kubernetes auth + **Vault Secrets Operator (VSO)**
- **แยก 2 repo**:
  - **app repo** — โค้ด + `Dockerfile` + `.gitlab-ci.yml` ของแต่ละ service
  - **gitops repo** — Kustomize manifests (`base/` + `overlays/{dev,staging,prod}`) — ArgoCD อ่านจากที่นี่เท่านั้น

เหตุผลที่แยก 2 repo:
- App developer commit โค้ดได้อิสระ
- การแก้ manifest prod ต้องผ่าน MR ที่อีกคนอนุมัติ → audit ชัด
- Rollback ง่าย — แค่ `git revert` commit ใน gitops repo
- ArgoCD ไม่ต้องมีสิทธิ์อ่าน source code

## 2. CI Pipeline (GitLab CI — app repo)

Stages:

```
┌┬───────┬───────┬──────┬────────────┬─────────────────┬──────────────────┐
││ test  │ build │ scan │ push-image │ integration-test│ bump-gitops (dev)│
└┴───────┴───────┴──────┴────────────┴─────────────────┴──────────────────┘
```

| Stage | Tool | ทำงานเมื่อ |
|---|---|---|
| unit-test | pytest / jest + coverage | ทุก push, fail ถ้า coverage drop |
| build | Kaniko / buildx → **SWR** (Huawei Software Repository) | branch `main` + MR |
| scan | Trivy  | ทุก build; block `HIGH/CRITICAL` CVE |
| push-image | ติด tag `:sha-<short>` + `:vX.Y.Z` (semver) | `main` + git tag |
| integration-test | spawn ephemeral namespace ใน `cce-dev` | MR เท่านั้น |
| bump-gitops | แก้ `overlays/dev/<service>/kustomization.yaml` image tag → push gitops repo | main merge เท่านั้น |


### ตัวอย่าง `.gitlab-ci.yml` 

```yaml
stages: [test, build, scan, integration, deploy]

variables:
  REGISTRY: swr.ap-southeast-3.myhuaweicloud.com/corp
  IMAGE: $REGISTRY/$CI_PROJECT_NAME

build:
  stage: build
  image: gcr.io/kaniko-project/executor:latest
  script:
    - /kaniko/executor --context=. --destination=$IMAGE:sha-$CI_COMMIT_SHORT_SHA
  only: [main, merge_requests, tags]

scan:
  stage: scan
  image: aquasec/trivy:latest
  script:
    - trivy image --exit-code 1 --severity HIGH,CRITICAL $IMAGE:sha-$CI_COMMIT_SHORT_SHA

bump-gitops:
  stage: deploy
  <<: *vault_login
  script:
    - export GITOPS_TOKEN=$(vault kv get -field=token kv/ci/gitops)
    - git clone https://oauth2:$GITOPS_TOKEN@gitlab.corp/gitops.git
    - cd gitops/overlays/dev/$CI_PROJECT_NAME
    - kustomize edit set image app=$IMAGE:sha-$CI_COMMIT_SHORT_SHA
    - git commit -am "dev: bump $CI_PROJECT_NAME to sha-$CI_COMMIT_SHORT_SHA [skip ci]"
    - git push
  only: [main]
  environment: dev
```

## 3. CD Pipeline (ArgoCD บน CCE)

- **ArgoCD** ติดตั้งใน namespace `platform` ของแต่ละ cluster
- **ApplicationSet** สร้าง ArgoCD Application ทีละ service ต่อ env อัตโนมัติ จาก list ใน gitops repo
- Path: `overlays/<env>/<service>` → ใช้ Kustomize build
- Sync policy:

| Env | Sync | Approval | Extra |
|---|---|---|---|
| dev | **auto** | — | self-heal เปิด |
| staging | **auto** | — | smoke test เป็น PostSync hook |
| prod | **manual** | 2-person approval | progressive rollout (Argo Rollouts — canary 10% → 50% → 100%) |

### Secret ใน manifest — Vault Secrets Operator (VSO)

Gitops repo **ไม่มี secret value** เลย — มีแต่ VSO custom resource ที่ชี้ Vault path:

**Static secret (KV v2)**
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata: { name: api-static-secrets, namespace: app }
spec:
  vaultAuthRef: default-app
  namespace: platform
  mount: kv
  type: kv-v2
  path: api
  refreshAfter: 5m
  destination: { name: api-static-secrets, create: true }
  rolloutRestartTargets:
    - { kind: Deployment, name: api }
```

**Dynamic DB credentials (TTL 1h, auto-rotated)**
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata: { name: api-db, namespace: app }
spec:
  vaultAuthRef: default-app
  namespace: platform
  mount: database
  path: creds/api
  renewalPercent: 50          
    name: api-db
    create: true
    transformation:
      templates:
        DATABASE_URL:
          text: 'postgres://{{ .Secrets.username }}:{{ .Secrets.password }}@db:5432/app?sslmode=require'
  rolloutRestartTargets:
    - { kind: Deployment, name: api }
```


### Database migration
- รันเป็น ArgoCD **sync wave -1** (`argocd.argoproj.io/sync-wave: "-1"`) → migrate ก่อน pod rollout
- Migration tool: Alembic (Python) / Flyway — idempotent + reversible
- DB credentials สำหรับ migration job ก็มาจาก Vault

## 4. Environment Promotion

```
feature branch ──MR──> main ──CI──> SWR image:sha-abcd
                                        │
                                        ▼ (auto bump-gitops)
                                 overlays/dev  ──ArgoCD──> cce-dev
                                        │
                                        │ ▼ smoke test pass
                                        │
                                        │ scheduled / manual "promote dev→staging" MR
                                        │ (helper: promote.sh dev staging)
                                        ▼
                                 overlays/staging ──ArgoCD──> cce-staging
                                        │
                                        │ ▼ regression suite pass
                                        │
                                        │ git tag vX.Y.Z + 2-approver MR
                                        ▼
                                 overlays/prod   ──ArgoCD (manual sync + canary)──> cce-prod
```

- **dev**: auto promote ทุก main merge
- **staging**: กดเองหรือ scheduled (e.g. ทุก 17:00) — รัน full regression test หลัง deploy
- **prod**: ต้อง git tag `vX.Y.Z` + MR approve โดยอีกคน + ArgoCD manual sync + Argo Rollouts canary

### promote.sh (helper)
```bash
#!/usr/bin/env bash
# Copy image tag from one overlay to another.
SRC=$1; DST=$2  # e.g. dev staging
SVC=$3          # service name
IMG=$(yq '.images[0].newTag' overlays/$SRC/$SVC/kustomization.yaml)
yq -i ".images[0].newTag = \"$IMG\"" overlays/$DST/$SVC/kustomization.yaml
git checkout -b promote/$SVC-$DST-$IMG
git commit -am "promote $SVC $SRC → $DST: $IMG"
git push -u origin HEAD
glab mr create -t "Promote $SVC $IMG → $DST" -a reviewer
```

## 5. Vault Bootstrap & Day-2

| งาน | วิธี |
|---|---|
| Install | Helm chart `hashicorp/vault` ผ่าน ArgoCD เอง (Vault อยู่ใน gitops repo เหมือน app) |
| Auto-unseal | Huawei KMS key (Terraform managed) — ไม่ต้องเก็บ unseal key |
| Initial setup | one-time bootstrap job: enable auth methods (k8s, oidc, approle), create policies, configure DB engine |
| Policy as code | HCL files ใน `vault-config/` repo → `vault policy write` ผ่าน CI |
| Disaster recovery | snapshot ทุกชั่วโมงไป OBS; cross-region replication สำหรับ prod |
| Upgrade | rolling restart ทีละ pod (StatefulSet); KMS auto-unseal handle ให้เอง |

## 6. Rollback

| Scenario | วิธี | 
|---|---|
| Bad app release | `argocd app rollback <app> <rev>` หรือ `git revert` ใน gitops repo | 
| Bad migration | migration tool's `downgrade` + app rollback | 
| Bad infra change | `terraform apply` previous state (revert commit) | 
| Vault data corrupt | restore snapshot จาก OBS (`vault operator raft snapshot restore`) |
| Full DR | restore RDS snapshot + Vault snapshot + Velero restore + re-deploy |

## 7. Quality Gates

| Gate | Block เมื่อ |
|---|---|
| Unit tests | fail หรือ coverage < 80% |
| Trivy scan | HIGH/CRITICAL CVE |
| Integration test | any fail |
| Prod sync | ต้อง 2 approver + CAB ticket 
| Vault policy MR | ต้อง security team approve |
