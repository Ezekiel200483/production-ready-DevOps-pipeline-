# Node.js DevOps Pipeline

A Node.js web application built with a complete DevOps pipeline including 
containerisation, CI/CD automation, and cloud infrastructure on AWS with 
HTTPS using a custom domain.

---

## How to Run the Application Locally

**What you need installed**
- Docker Desktop
- Node.js 20+
- Git

**1. Clone the repo**
```bash
git clone https://github.com/ezekiel200483/nodejs-devops-app.git
cd nodejs-devops-app
```

**2. Copy the env file**
```bash
cp .env.example .env.local
```

**3. Start the app**
```bash
docker compose up --build
```



First time takes a couple of minutes. You'll know it's ready when you see:
```
app | {"message":"Server listening","port":3000}
app | {"message":"Redis connected"}
```
<img width="1440" height="900" alt="compose d" src="https://github.com/user-attachments/assets/9eb08769-2d22-495c-b415-045627d0d358" />

**4. Run the tests**
```bash
npm install
npm test
```

**5. Stop everything**
```bash
docker compose down
```

---

## How to Access the App

The app is live at **https://app.ezekiel.ink**

Open these directly in your browser:
```
https://app.ezekiel.ink/health
https://app.ezekiel.ink/status
```

For the POST endpoint use curl or Postman:
```bash
curl -X POST https://app.ezekiel.ink/process \
  -H "Content-Type: application/json" \
  -d '{"data": "hello world"}'
```

Locally the app runs on `http://localhost:3000` with the same endpoints.

**Available endpoints:**

| Method | Path | What it does |
|---|---|---|
| GET | `/health` | Quick liveness check — always returns ok |
| GET | `/status` | Shows Redis connection status |
| POST | `/process` | Accepts JSON data, stores it in Redis, returns a result |

---

## How to Deploy the Application

**What you need**
- AWS account
- Terraform 
- AWS CLI
- A domain name pointed to AWS Route 53

**1. Configure AWS CLI**
```bash
aws configure
```

**2. Generate an SSH key**
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/nodejs-app-key -N ""
```

**3. Create Terraform state storage**
```bash
aws s3api create-bucket \
  --bucket nodejs-app-tfstate-yourname \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket nodejs-app-tfstate-yourname \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Update the bucket name in `terraform/main.tf`:
```hcl
backend "s3" {
  bucket = "nodejs-app-tfstate-yourname"
}
```

**4. Set your variables**
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Fill in `terraform.tfvars`:
```hcl
aws_region        = "us-east-1"
project_name      = "nodejs-app"
environment       = "staging"
container_image   = "ghcr.io/ezekiel200483/nodejs-devops-app:latest"
ec2_instance_type = "t3.micro"
ec2_public_key    = "ssh-rsa AAAA..."
ssh_allowed_cidr  = "0.0.0.0/0"
domain_name       = "ezekiel.ink"
app_subdomain     = "app"
```

**5. Deploy**
```bash
terraform init
terraform plan
terraform apply
```

Takes about 5-10 minutes. The ACM certificate validation is the slowest part.

**6. Add GitHub secrets**

Go to repo → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `EC2_SSH_PRIVATE_KEY` | Run `cat ~/.ssh/nodejs-app-key` |
| `EC2_HOST_STAGING` | EC2 IP from terraform output |
| `EC2_SSH_PRIVATE_KEY_PROD` | Same as staging |
| `EC2_HOST_PROD` | Same as staging |

**7. Push to deploy**
```bash
git push origin main
```

Watch it run in the GitHub Actions tab. Production deployment requires 
manual approval — click into the deploy-production job and hit Approve.

**To destroy everything:**
```bash
terraform destroy
```

---

## Key Decisions

### Security

I ran the app as a non-root user inside Docker. The reason for this is simple
— if someone finds a vulnerability in the app and exploits it, they still
can't touch anything outside the container. It's a small change that removes
a whole class of risk.

The container filesystem is also set to read-only. Nothing can be written to
the app directory while it's running, only /tmp is writable. This means even
if someone gets code execution inside the container they can't modify the
application files.

For HTTPS I used AWS Certificate Manager to provision a TLS certificate for
app.ezekiel.ink and attached it to the Load Balancer. All HTTP traffic on
port 80 gets redirected to HTTPS automatically. The certificate renews itself
so there's nothing to maintain.

On the EC2 I enforced IMDSv2 which requires a session token for any request
to the instance metadata service. This blocks a common attack where a
vulnerability in the app is used to steal the AWS credentials attached to
the server.

Nothing sensitive is hardcoded anywhere. SSH keys and server addresses live
in GitHub Secrets. The .env.local and terraform.tfvars files are in
.gitignore so there's no way to accidentally commit them.

### CI/CD

The pipeline runs tests before anything else. If a test fails the whole
pipeline stops — no image gets built, nothing gets deployed. This means
whatever is in the registry has always passed the test suite.

After deploying the new container the pipeline waits and checks the /health
endpoint every 5 seconds for up to 60 seconds. If the container never becomes
healthy it rolls back to the previous version without any manual intervention.
I added this after seeing how easy it is for a deploy to silently fail without
anyone noticing.

Production requires a manual approval before the deploy runs. I did this
deliberately because pushing straight to production on every commit felt like
a bad idea — having someone review what's going out gives a chance to catch
anything before real users are affected.

Every Docker image gets tagged with the Git commit SHA so you can always
trace exactly which version of the code is running, and roll back to any
previous commit if something goes wrong.

### Infrastructure

I used a single EC2 t3.micro running Docker Compose rather than ECS and RDS.
The honest reason is cost — ECS Fargate with RDS would run $50-100 a month
at minimum just sitting there. The t3.micro sits within the AWS free tier so
it costs nothing to run. The containerisation approach is the same either way
so nothing is lost from a learning perspective.

Redis made more sense than PostgreSQL for what the /process endpoint actually
does. It stores job results with an automatic expiry time, keeps a list of the
last 100 jobs, and uses very little memory on a small server. PostgreSQL would
have been overkill.

The Load Balancer sits in front of the EC2 and handles HTTPS termination. The
app itself just runs on HTTP port 3000 internally — it doesn't need to know
anything about SSL. The ALB also gives a stable domain entry point that stays
the same even if the server behind it changes.

I set up two target groups on the ALB even though there's only one server. The
reason is that this makes it possible to do zero-downtime deployments later by
shifting traffic from the old container to the new one at the network level
rather than having a gap in service.

Terraform state goes into S3 with a DynamoDB lock table. If state only lived
locally and the laptop was lost or someone else needed to run Terraform, the
infrastructure would become unmanageable. Remote state means it's always
accessible and two people can never apply conflicting changes at the same time.
