# Runbook — Layer 3 operational procedures

Step-by-step commands for deploying and verifying the infra. This is the *how*;
the *why* lives in `layer3-cicd-plan.md` and the README. Run these from a local
clone with the AWS CLI authenticated (`aws sts get-caller-identity` should
return your account).

---

## Step 1 — Stand up the ECR repository and push the first image

### Phase A — Create the registry (Terraform; no Docker needed)

`main.tf` defines the whole stack, so target *only* the ECR resources to avoid
touching the Layer 2 VPC/EC2 (a fresh clone has no state file and would
otherwise try to recreate — and collide with — existing infra).

```bash
terraform init
terraform apply \
  -target=aws_ecr_repository.agent \
  -target=aws_ecr_lifecycle_policy.agent
```

Grab the registry URI it outputs:

```bash
terraform output ecr_repository_url
# => <acct>.dkr.ecr.us-east-1.amazonaws.com/aws-agent
```

### Phase B — Manual push smoke test (Docker required, running)

Proves the auth → build → tag → push path works by hand, before the CI runner
does it unattended. The Docker login here authenticates to **ECR** using your
AWS creds — it is *not* a Docker Hub login.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
REPO="$REGISTRY/aws-agent"

# 1. Authenticate Docker to ECR (token valid ~12h)
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# 2. Build the image
docker build -t aws-agent .

# 3. Tag by git SHA — the repo is IMMUTABLE, so there is no moving :latest
SHA=$(git rev-parse --short HEAD)
docker tag aws-agent:latest "$REPO:$SHA"

# 4. Push
docker push "$REPO:$SHA"
```

### Verify

```bash
aws ecr list-images --repository-name aws-agent --region "$REGION"
# should list the image tagged with your git SHA
```

---

## Teardown (stay on free tier)

ECR storage for one small image is negligible, but to remove the repo entirely:

```bash
terraform destroy \
  -target=aws_ecr_lifecycle_policy.agent \
  -target=aws_ecr_repository.agent
```

`force_delete = true` on the repo lets this succeed even if images remain.

---

## Notes / gotchas

- **Full `terraform apply` builds everything** (VPC, security group, EC2 +
  the registry). Use `-target` for Step 1 in isolation. Only run a full apply
  when you intend to rebuild the whole stack from scratch.
- **No state in a fresh clone.** `terraform.tfstate` is gitignored. If you
  already have Layer 2 infra running, a non-targeted apply will try to recreate
  it and error on name collisions (e.g. `aws-agent-sg`).
- **ECR login expires (~12h).** Re-run the `get-login-password | docker login`
  step if a later push is rejected with an auth error.
