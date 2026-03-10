# Node.js DevOps Pipeline

A Node.js web application built with a full DevOps pipeline including containerisation,
CI/CD automation, and cloud infrastructure on AWS.

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

The first time takes a couple of minutes to pull images and build.
You'll know it's ready when you see this in the logs:
```
app | {"message":"Server listening","port":3000}
app | {"message":"Redis connected"}
```

**4. Run tests**
```bash
npm install
npm test
```

**5. Stop the app**
```bash
docker compose down
```

---

## How to Access the App

Locally the app runs on `http://localhost:3000`

On AWS the app is accessed via the Load Balancer DNS:
```bash
terraform output application_url
```

**Endpoints:**

| Method | Path | What it does |
|---|---|---|
| GET | `/health` | Quick liveness check |
| GET | `/status` | Shows Redis connection status |
| POST | `/process` | Accepts a JSON payload and stores it in Redis |

**Example requests:**
```bash
curl http://localhost:3000/health

curl http://localhost:3000/status

curl -X POST http://localhost:3000/process \
  -H "Content-Type: application/json" \
  -d '{"data": "hello world"}'
```

---

## How to Deploy the Application

**What you need**
- AWS account
- Terraform 1.7+
- AWS CLI

**1. Configure AWS CLI**
```bash
aws configure
```

**2. Create an SSH key**
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

Update `terraform/main.tf` with your bucket name:
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

Edit `terraform.tfvars`:
```hcl
aws_region        = "us-east-1"
project_name      = "nodejs-app"
environment       = "staging"
container_image   = "ghcr.io/ezekiel200483/nodejs-devops-app:latest"
ec2_instance_type = "t3.micro"
ec2_public_key    = "ssh-rsa AAAA..."
ssh_allowed_cidr  = "0.0.0.0/0"
```

**5. Run Terraform**
```bash
terraform init
terraform plan
terraform apply
```

**6. Add these secrets to GitHub**

Go to your repo → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `EC2_SSH_PRIVATE_KEY` | Run `cat ~/.ssh/nodejs-app-key` |
| `EC2_HOST_STAGING` | EC2 IP from terraform output |
| `EC2_SSH_PRIVATE_KEY_PROD` | Same as staging |
| `EC2_HOST_PROD` | Same as staging |
| `ALB_DNS` | ALB DNS from terraform output |
| `ALB_DNS_PROD` | Same as ALB_DNS |

**7. Deploy**
```bash
git push origin main
```

Check the GitHub Actions tab to watch the pipeline run.
Production deployment requires manual approval — go to Actions, click the
deploy-production job and hit Approve.

**To tear everything down:**
```bash
terraform destroy
```

---

## Key Decisions

### Security

I made the container run as a non-root user because if someone exploits a
vulnerability in the app, they won't have root access to the underlying host.
This is something I've seen recommended widely and it's a simple change that
makes a real difference.

I also set the container filesystem to read-only so nothing can be written to
the app directory at runtime. Only /tmp is writable, which the app uses for
temporary files.

On the EC2 side I enforced IMDSv2, which means any request to the instance
metadata service has to include a session token. This protects against a class
of attacks where a vulnerability in the app is used to steal AWS credentials
from the metadata endpoint.

For secrets I made sure nothing sensitive ever touches the codebase. Database
credentials and SSH keys live in GitHub Secrets and AWS SSM Parameter Store.
The .env.local and terraform.tfvars files are in .gitignore so there's no
chance of accidentally committing them.

### CI/CD

I structured the pipeline so tests always run first. If any test fails the
pipeline stops and nothing gets built or deployed. This means the Docker image
in the registry is always from passing code.

For deployments I added a health check loop that waits up to 60 seconds after
starting the new container. If the app doesn't become healthy in time it
automatically rolls back to the previous version. I added this after running
into a situation where a bad deploy would have caused downtime without it.

Production deployments require a manual approval step. I did this because
deploying to production automatically on every push felt risky — having a
human review what's going out gives a chance to catch anything before it
affects users.

### Infrastructure

I chose to run the app on a single EC2 t3.micro with Docker Compose rather
than ECS and RDS. The main reason was cost — ECS Fargate and RDS together
would run around $50-100 a month even with nothing happening, while a t3.micro
stays within the AWS free tier. For a project at this scale the tradeoff makes
sense and the containerisation approach is the same either way.

I picked Redis over PostgreSQL for the database because it fits what the
/process endpoint actually needs. Each job gets stored with an expiry time,
there's a list of recent jobs capped at 100 entries, and memory usage stays
low. PostgreSQL would be overkill for this use case.

I set up the Load Balancer with two target groups even though there's only one
server right now. This means when a new version deploys, traffic can be shifted
from the old container to the new one at the ALB level rather than having any
gap in service.

I stored Terraform state in S3 with a DynamoDB lock table. The reason for this
is that if state is only stored locally and something happens to the machine,
or if someone else needs to run Terraform, the state would be out of sync and
changes could conflict or get lost. Remote state solves that problem.
