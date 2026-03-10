# Node.js Production DevOps Pipeline

A production-ready Node.js web application with full CI/CD automation, containerisation, IaC, blue/green deployments, HTTPS, secrets management, and observability.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Running Locally](#running-locally)
3. [API Endpoints](#api-endpoints)
4. [CI/CD Pipeline](#cicd-pipeline)
5. [Deploying to AWS](#deploying-to-aws)
6. [Accessing the App](#accessing-the-app)
7. [Security Decisions](#security-decisions)
8. [Infrastructure Decisions](#infrastructure-decisions)
9. [Observability](#observability)
10. [Secrets Management](#secrets-management)

---

## Architecture Overview

```
Internet
   │
   ▼
Route 53 (DNS)
   │
   ▼
Application Load Balancer  (HTTPS :443, HTTP :80 → redirect)
   │  ┌─────────── Blue TG ───────────┐
   │  └─────────── Green TG ──────────┘
   │
   ▼ (Public Subnet)
EC2 t3.micro  (Docker host – free tier eligible)
   ├── nodejs-app container  (non-root, port 3000)
   └── redis:7-alpine container  (internal only, no public port)
```

**Key components:**

| Layer | Technology | Notes |
|---|---|---|
| Compute | EC2 t3.micro | Free-tier eligible; Docker host for app + DB |
| Networking | VPC + ALB | Public ALB, private app + DB subnets |
| TLS | ACM + ALB | Auto-renewing certificates, TLS 1.3 |
| Database | Redis 7 in Docker | Runs on EC2, AOF persistence, LRU eviction, 128 MB cap |
| Deployment | SSH + Docker Compose | Pull new image → recreate app container; health-check gated rollback |
| IaC | Terraform ≥ 1.7 | Remote state in S3 + DynamoDB lock |
| CI/CD | GitHub Actions | OIDC auth (no long-lived AWS keys) |
| Secrets | SSM Parameter Store | SecureString, injected at runtime |
| Logs | CloudWatch Logs | Structured JSON via Winston |

---

## Running Locally

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) ≥ 24
- [Node.js](https://nodejs.org/) 20+ (for running tests without Docker)

### 1 – Clone and configure

```bash
git clone https://github.com/your-org/nodejs-devops-app.git
cd nodejs-devops-app

# Create your local secrets file (gitignored)
cp .env.example .env.local
# Edit .env.local if you need different credentials
```

### 2 – Start the stack

```bash
docker compose up --build
```

This starts:
- **app** on `http://localhost:3000`
- **db** (PostgreSQL) on `localhost:5432`

### 3 – Verify

```bash
curl http://localhost:3000/health
# → {"status":"ok","timestamp":"..."}

curl http://localhost:3000/status
# → {"status":"ok","uptime":...,"redis":"connected"}

curl -X POST http://localhost:3000/process \
  -H "Content-Type: application/json" \
  -d '{"data": "hello world"}'
# → {"processed":true,"input":"hello world","processedAt":"..."}
```

### 4 – Run tests

```bash
# Without Docker
npm ci
npm test

# Inside Docker (CI mode with coverage)
docker build --target test .
```

### 5 – Stop

```bash
docker compose down          # keep volumes
docker compose down -v       # also remove DB data
```

---

## API Endpoints

| Method | Path | Description | Success |
|---|---|---|---|
| `GET` | `/health` | Liveness probe – always fast | `200 {"status":"ok"}` |
| `GET` | `/status` | Readiness probe – checks DB | `200` / `503` |
| `POST` | `/process` | Process a JSON payload | `200 {"processed":true,...}` |

### POST /process – request body

```json
{ "data": "<any JSON value>" }
```

Returns `400` if `data` field is missing.

---

## CI/CD Pipeline

File: `.github/workflows/ci-cd.yml`

```
push / PR to main
       │
       ▼
  ┌─────────┐
  │  test   │  npm ci → npm run test:ci (Jest + coverage)
  └────┬────┘
       │ (main branch only)
       ▼
  ┌─────────┐
  │  build  │  Docker multi-arch build (amd64 + arm64)
  │         │  Push to GHCR with SHA + latest tags
  │         │  Trivy CVE scan (CRITICAL/HIGH = fail)
  └────┬────┘
       │
       ▼
  ┌──────────────┐
  │deploy-staging│  ECS rolling update → smoke test
  └──────┬───────┘
         │  ⏸ Manual approval (GitHub Environment protection)
         ▼
  ┌────────────────┐
  │deploy-production│  CodeDeploy blue/green → smoke test
  └────────────────┘
```

### Required GitHub Secrets / Variables

| Name | Where | Description |
|---|---|---|
| `EC2_SSH_PRIVATE_KEY` | Repository secret | Private key for SSH to staging EC2 |
| `EC2_HOST_STAGING` | Repository secret | Elastic IP / hostname of staging EC2 |
| `EC2_SSH_PRIVATE_KEY_PROD` | Repository secret | Private key for SSH to production EC2 |
| `EC2_HOST_PROD` | Repository secret | Elastic IP / hostname of production EC2 |

> **No static AWS access keys are used.** The pipeline uses GitHub OIDC to assume IAM roles directly — see [AWS OIDC docs](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services).

### Setting up Manual Approval

1. Go to **Settings → Environments → production**
2. Enable **Required reviewers** and add your team
3. All production deployments will pause and wait for approval

---

## Deploying to AWS

### Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.7
- [AWS CLI](https://aws.amazon.com/cli/) configured
- A domain in Route 53
- An S3 bucket + DynamoDB table for Terraform state (see `terraform/main.tf`)

### 1 – Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2 – Initialise and plan

```bash
terraform init
terraform workspace new staging   # or 'production'
terraform plan -out=tfplan
```

### 3 – Apply

```bash
terraform apply tfplan
```

Terraform will:
- Create VPC, subnets, IGW, NAT Gateways, security groups
- Provision RDS PostgreSQL (encrypted, in private subnets)
- Create ECS cluster + Fargate service
- Provision ALB with HTTPS listener + ACM certificate
- Create DNS record in Route 53
- Store a random DB password in SSM Parameter Store

### 4 – Push an image and trigger CI

```bash
git push origin main
```

The GitHub Actions pipeline builds, scans, and deploys automatically.

---

## Accessing the App

| Environment | URL |
|---|---|
| Local | `http://localhost:3000` |
| Staging | `https://app.example.com` (replace with your domain) |
| Production | `https://app.example.com` |

Health check:
```bash
curl https://app.example.com/health
```

---

## Security Decisions

### Container security
- **Multi-stage Dockerfile** – final image contains only production deps and app source; no build tools, no dev dependencies.
- **Non-root user** (`nodeapp`, UID 1001) – the process cannot escalate privileges even if compromised.
- **Read-only root filesystem** – `readOnlyRootFilesystem: true` in both Docker Compose and ECS task definition; only `/tmp` is writable.
- **dumb-init** as PID 1 – correct signal handling and zombie reaping.
- **Drop ALL Linux capabilities** – ECS task definition drops all capabilities; none are added back.
- **Trivy CVE scan** in CI – the pipeline fails on CRITICAL or HIGH vulnerabilities before an image is deployed.

### Network security
- App containers run in **private subnets** – no public IPs.
- **Security groups** are least-privilege: ALB accepts 80/443 from `0.0.0.0/0`; app containers only accept traffic from the ALB SG; RDS only accepts traffic from the app SG.
- **HTTP → HTTPS redirect** enforced at the ALB level (301).
- **TLS 1.3** policy (`ELBSecurityPolicy-TLS13-1-2-2021-06`) on the HTTPS listener.

### Secrets management
- **No secrets in GitHub** – the pipeline uses GitHub OIDC to assume AWS IAM roles; no static access keys.
- **SSM Parameter Store** (`SecureString`) – DB password is generated by Terraform and stored encrypted; it is injected into containers at runtime via the ECS task definition `secrets` field, never as a plain environment variable or in source code.
- `.env.local` and `terraform.tfvars` are **gitignored**.

### IAM
- Separate **execution role** (agent) and **task role** (application) follow least-privilege.
- OIDC deploy roles should be scoped to the specific repository and branch.

---

## Infrastructure Decisions

### EC2 t3.micro + Docker Compose over ECS/RDS
For a portfolio project, ECS Fargate + RDS would cost ~$50–100/month with nothing running. A single **t3.micro** (free tier) running both the app and PostgreSQL in Docker costs **$0** within the free tier, or ~$8/month after. The tradeoff is that the DB and app share one host — acceptable for a demo, and easy to migrate to RDS later by just changing the `DATABASE_URL`.

### Blue/Green deployment
CodeDeploy shifts traffic between two target groups (Blue and Green) at the ALB level. If health checks fail on the new version, CodeDeploy rolls back automatically — zero downtime in either direction.

### Redis persistence
Redis runs with **AOF (Append-Only File)** persistence (`appendonly yes`, `appendfsync everysec`) so process logs survive container restarts. A named Docker volume (`redis-data`) backs the `/data` directory. `maxmemory 128mb` with `allkeys-lru` eviction keeps memory bounded — perfect for a t3.micro.

### Remote Terraform state
State is stored in S3 (encrypted) with a DynamoDB table for locking, allowing multiple engineers to safely run Terraform without state corruption.

### Zero-downtime deploys on a single EC2
The deploy script pulls the new image first, then runs `docker compose up -d --no-deps app`. Compose replaces only the app container; the DB container keeps running. A health-check loop confirms the new container is healthy before the pipeline proceeds — if it fails, it immediately redeploys the previous image.

---

## Observability

### Logs
- Application emits **structured JSON logs** via Winston (level, message, timestamp, metadata).
- ECS ships all stdout/stderr to **CloudWatch Logs** (`/ecs/nodejs-app-<env>`).
- ALB access logs are stored in S3 (30-day retention).

### Health checks
- **Docker / ECS health check**: `GET /health` every 30 s; 3 failures → unhealthy.
- **ALB health check**: `GET /health` every 30 s; 2 successes → healthy, 3 failures → deregistered.
- **`GET /status`** checks the DB connection and returns `503` if degraded — used for readiness rather than liveness.

### CloudWatch Alarms (recommended additions)
```
ECS CPU > 80%  →  SNS notification
ALB 5xx rate > 1%  →  SNS notification
RDS FreeStorageSpace < 2 GB  →  SNS notification
```

---

## Project Structure

```
.
├── src/
│   ├── app.js          # Express app (routes, middleware)
│   └── server.js       # HTTP server + graceful shutdown
├── tests/
│   └── app.test.js     # Jest + Supertest integration tests
├── scripts/
├── terraform/
│   ├── main.tf         # Provider + backend config
│   ├── variables.tf    # Input variables
│   ├── vpc.tf          # VPC, subnets, SGs
│   ├── alb.tf          # ALB, ACM, Route 53
│   ├── ec2.tf          # EC2 instance, IAM, security group, user-data
│   ├── logging.tf      # CloudWatch log group + IAM
│   └── outputs.tf      # Output values
├── .github/
│   └── workflows/
│       └── ci-cd.yml   # GitHub Actions pipeline
├── Dockerfile          # Multi-stage, non-root, dumb-init
├── docker-compose.yml  # Local dev stack (app + PostgreSQL)
├── package.json
├── .env.example        # Template for .env.local (gitignored)
└── README.md
```
