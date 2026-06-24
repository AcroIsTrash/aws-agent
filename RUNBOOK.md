# Runbook — Layer 3 operational procedures

Step-by-step commands for deploying and verifying the infra. This is the *how*;
the *why* lives in `layer3-cicd-plan.md` and the README. Run these from a local
clone with the AWS CLI authenticated (`aws sts get-caller-identity` should
return your account).

> **Current state (2026-06-23):** the account is a clean slate. The Layer 1
> console instance has been **terminated** (root volume deleted with it) and the
> Layer 2 Terraform stack has been **destroyed** — `terraform state list` is
> empty. The only surviving resource is the `AgentServer` key pair, which
> `main.tf` reuses by design. Because nothing is live, a full `terraform apply`
> now rebuilds the whole stack from scratch with **no name collisions**; the
> `-target` step below is therefore optional (it just brings up ECR alone
> without paying for EC2).

---

## Step 1 — Stand up the ECR repository and push the first image

### Phase A — Create the registry (Terraform; no Docker needed)

`main.tf` defines the whole stack. To bring up *only* the registry — without
also standing up the VPC/EC2 — target the ECR resources. This is the right move
when the rest of the stack is already running (a non-targeted apply would try to
recreate it and collide) **or**, as now, when the stack is torn down and you
just want ECR up without paying for an EC2 instance. Drop the `-target` flags if
you actually want a full rebuild.

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

## Step 2 — Least-privilege IAM for the pipeline (Terraform)

Step 2 creates the **identities** the CI/CD pipeline needs — and nothing more.
There are **two separate identities**, and keeping them straight is the whole
point:

| Identity | Who/what it is | What it's allowed to do |
|----------|----------------|-------------------------|
| **Runner role** (`aws-agent-github-actions`) | The GitHub Actions job, authenticated via OIDC — *no stored AWS keys* | Push images to ECR + fire `ssm:SendCommand` |
| **EC2 instance profile** (`aws-agent-ec2`) | The deploy *target* box | Be managed by SSM + **pull** from ECR |

The runner is the *deployer*; the instance profile is the *deploy target's*
permission to receive the command and pull the image. Why OIDC instead of a
long-lived IAM user with access keys: the runner mints a short-lived token per
job, AWS trusts GitHub's issuer, and credentials expire in ~1h — there is no
static secret sitting in GitHub to leak or rotate. (Full reasoning:
`layer3-cicd-plan.md` → "Authentication".)

All of this is **as code**, consistent with Layer 2. None of it touches the
VPC/EC2, so it applies cleanly with the stack torn down.

### Terraform to add (suggested: a new `iam.tf`)

The OIDC provider needs a CA thumbprint; fetch it dynamically with the `tls`
provider rather than pasting a magic string. Add `tls` to `required_providers`
in `main.tf` first:

```hcl
# main.tf → terraform { required_providers { ... } }
tls = {
  source  = "hashicorp/tls"
  version = "~> 4.0"
}
```

```hcl
# iam.tf
data "aws_caller_identity" "current" {}

# ── 1. Trust GitHub's OIDC issuer (one provider per account) ──────────────────
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ── 2. Runner role — the deployer identity ────────────────────────────────────
# TRUST POLICY ("who may assume me"): only an OIDC token from the provider above,
# AND only from THIS repo on the master branch. The sub condition is the security —
# without it, any repo on GitHub could assume this role.
resource "aws_iam_role" "github_actions" {
  name = "aws-agent-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Exact branch. To allow tags or many branches, switch this block to
          # StringLike with a wildcard, e.g. "repo:AcroIsTrash/aws-agent:*".
          "token.actions.githubusercontent.com:sub" = "repo:AcroIsTrash/aws-agent:ref:refs/heads/master"
        }
      }
    }]
  })
}

# PERMISSION POLICY ("what I can do once inside"): ECR push + one deploy command.
# Never AdministratorAccess. If this role leaked, the blast radius is "push an
# image and run one SSM command", not "own the account".
resource "aws_iam_role_policy" "github_actions" {
  name = "ecr-push-and-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth" # GetAuthorizationToken only works on "*"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.agent.arn # scoped to THIS repo
      },
      {
        Sid      = "SSMSendToAgent"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ec2:us-east-1:${data.aws_caller_identity.current.account_id}:instance/*"
        # Tag-scoped instead of a hard instance ARN, so this policy does NOT
        # depend on the EC2 existing yet. Only the box tagged Name=aws-agent.
        Condition = { StringEquals = { "ssm:resourceTag/Name" = "aws-agent" } }
      },
      {
        Sid      = "SSMRunShellDoc"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:us-east-1::document/AWS-RunShellScript"
      },
    ]
  })
}

# ── 3. EC2 instance profile — the deploy-target identity ──────────────────────
resource "aws_iam_role" "ec2" {
  name = "aws-agent-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AWS-managed policies: SSM agent connectivity + read-only ECR pull.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "aws-agent-ec2"
  role = aws_iam_role.ec2.name
}

# Output the role ARN — the workflow references it as role-to-assume (NOT a
# secret; OIDC means no key to store).
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
```

One small edit to `main.tf`: attach the profile to the instance so the box gets
the identity when it next comes up.

```hcl
# main.tf → resource "aws_instance" "agent"
iam_instance_profile = aws_iam_instance_profile.ec2.name
```

### Phase A — Create the identities (no EC2 needed)

These resources don't touch the VPC/EC2, so target them and leave the box down.
(The instance *profile* is created here; it only attaches to the instance later,
when you bring up EC2 with a full apply.)

```bash
terraform init   # re-run: it pulls the new tls provider

terraform apply \
  -target=aws_iam_openid_connect_provider.github \
  -target=aws_iam_role.github_actions \
  -target=aws_iam_role_policy.github_actions \
  -target=aws_iam_role.ec2 \
  -target=aws_iam_role_policy_attachment.ssm_core \
  -target=aws_iam_role_policy_attachment.ecr_read \
  -target=aws_iam_instance_profile.ec2
```

Grab the role ARN for the workflow (Step 3):

```bash
terraform output github_actions_role_arn
# => arn:aws:iam::854970834208:role/aws-agent-github-actions
```

### Verify

The resources exist:

```bash
aws iam list-open-id-connect-providers
aws iam get-role --role-name aws-agent-github-actions \
  --query "Role.AssumeRolePolicyDocument"   # confirm the sub/aud conditions
aws iam get-role-policy --role-name aws-agent-github-actions \
  --policy-name ecr-push-and-deploy          # confirm least-privilege actions
aws iam get-instance-profile --instance-profile-name aws-agent-ec2
```

> **End-to-end trust can only be proven once a workflow runs** (Step 3): a real
> Actions job mints the OIDC token and assumes the role. Until then you've
> verified the resources are correct, not that the handshake succeeds. The first
> green pipeline run is the actual proof.

---

## Step 3 — The CI/CD pipeline (GitHub Actions workflow)

Step 1 gave you a registry; Step 2 gave the pipeline permission to use it.
Step 3 is the pipeline itself: one file, `.github/workflows/deploy.yml`, that
runs on every push to `master`. It automates exactly what you did by hand in
Step 1's smoke test, then adds a deploy step.

**The runner runs on GitHub's servers, not your laptop.** After this, `git push`
*is* the deploy.

### Pipeline stages (push to `master`)

1. **Checkout** the code.
2. **Assume the Step 2 role via OIDC** — no stored keys, just the role ARN. This
   is where the OIDC handshake is proven for real.
3. **Log in to ECR.**
4. **Build + tag by git SHA** (the repo is `IMMUTABLE`, so there is *no* moving
   `:latest` — deploy by SHA, see note below).
5. **Push** the image to ECR.
6. **Deploy** via `ssm:SendCommand`: the box logs in to ECR, pulls the new SHA,
   prunes old images. *This is the only stage that needs a running EC2.*

### The workflow file

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [master]

# OIDC requires id-token:write. contents:read is for the checkout.
permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: aws-agent

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # Mint the OIDC token and assume the Step 2 role. The ARN is not a secret.
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::854970834208:role/aws-agent-github-actions
          aws-region: ${{ env.AWS_REGION }}

      - name: Log in to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag (by SHA), and push
        env:
          REGISTRY: ${{ steps.login-ecr.outputs.registry }}
        run: |
          SHA=$(git rev-parse --short HEAD)
          docker build -t "$REGISTRY/$ECR_REPOSITORY:$SHA" .
          docker push "$REGISTRY/$ECR_REPOSITORY:$SHA"
          echo "IMAGE_TAG=$SHA" >> "$GITHUB_ENV"
          echo "REGISTRY=$REGISTRY" >> "$GITHUB_ENV"

      # Tell the box (matched by tag) to pull the new image. Skips cleanly if no
      # instance is running yet — Step 6 only matters once EC2 is up.
      - name: Deploy to EC2 via SSM
        run: |
          IMAGE="$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"
          aws ssm send-command \
            --document-name "AWS-RunShellScript" \
            --targets "Key=tag:Name,Values=aws-agent" \
            --comment "Deploy $IMAGE_TAG" \
            --parameters commands="[\
              \"aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY\",\
              \"docker pull $IMAGE\",\
              \"docker image prune -f\"]"
```

### Phase A — Prove build + push (no EC2 needed)

Commit the workflow and push to `master`. Stages 1–5 run on GitHub's runner with
no box required; stage 6 finds no matching instance and simply affects nothing.

```bash
git add .github/workflows/deploy.yml
git commit -m "Add Layer 3 Step 3: CI/CD deploy workflow"
git push origin master

# Watch the run from the terminal:
gh run watch
# or open it:  gh run view --web
```

**Verify:** the run is green through "Build, tag, and push", and a new
SHA-tagged image appears in ECR:

```bash
aws ecr list-images --repository-name aws-agent --region us-east-1
```

### Phase B — Prove the deploy stage (EC2 required, briefly)

Only when you want to confirm stage 6 end-to-end. Bring the box up, push again
(or re-run the job) so the deploy targets a live instance, confirm the pull, then
tear the box back down to stay free.

```bash
terraform apply            # full apply: brings up VPC + EC2 with the instance profile
# ... trigger the workflow (push a commit or `gh run rerun <id>`) ...

# Confirm the SSM command landed and the image is on the box:
aws ssm list-command-invocations --region us-east-1 \
  --query "CommandInvocations[0].{Status:Status,Instance:InstanceId}" --output table

terraform destroy          # back to free tier when done
```

> **End-to-end trust is proven here, not before.** The first green Phase A run is
> the real confirmation that the Step 2 OIDC role assumption works. Phase B
> confirms the SSM deploy path.

### Note — IMMUTABLE means deploy by SHA, not `:latest`

`layer3-cicd-plan.md` sketched the deploy pulling `:latest`. That predates the
`IMMUTABLE` decision in Step 1: an immutable repo can't have a moving `:latest`
tag. So the pipeline tags and deploys by **git SHA** — which is strictly better
anyway (every running image traces back to an exact commit, and rollback is just
deploying an older SHA). The plan doc is the older intent; this runbook is the
built reality.

---

## Teardown (stay on free tier)

ECR storage for one small image is negligible, but to remove the repo entirely:

```bash
terraform destroy \
  -target=aws_ecr_lifecycle_policy.agent \
  -target=aws_ecr_repository.agent
```

`force_delete = true` on the repo lets this succeed even if images remain.

The Step 2 IAM resources cost nothing to leave in place (IAM is free), so there's
usually no reason to tear them down. If you must:

```bash
terraform destroy \
  -target=aws_iam_instance_profile.ec2 \
  -target=aws_iam_role_policy_attachment.ecr_read \
  -target=aws_iam_role_policy_attachment.ssm_core \
  -target=aws_iam_role.ec2 \
  -target=aws_iam_role_policy.github_actions \
  -target=aws_iam_role.github_actions \
  -target=aws_iam_openid_connect_provider.github
```

---

## Notes / gotchas

- **Full `terraform apply` builds everything** (VPC, security group, EC2 +
  the registry). Use `-target` for Step 1 in isolation. Only run a full apply
  when you intend to rebuild the whole stack from scratch — which, given the
  current torn-down state, is exactly what a non-targeted apply will do.
- **No state in a fresh clone.** `terraform.tfstate` is gitignored. If Layer 2
  infra is already running, a non-targeted apply will try to recreate it and
  error on name collisions (e.g. `aws-agent-sg`). Not a risk today (the stack is
  destroyed), but it returns the moment the stack is live again.
- **ECR login expires (~12h).** Re-run the `get-login-password | docker login`
  step if a later push is rejected with an auth error.
- **The OIDC provider is account-global.** There is one
  `token.actions.githubusercontent.com` provider per AWS account, shared by every
  repo that uses it. Don't delete it if another project depends on it — only the
  *role* is specific to this repo.
- **The `sub` condition is the security boundary, not the permission policy.** A
  too-broad `sub` (e.g. `repo:AcroIsTrash/aws-agent:*`) lets any branch/PR/tag
  assume the role. Keep it pinned to `ref:refs/heads/master` unless you have a
  reason to widen it.
- **No AWS secret in GitHub.** With OIDC the workflow only needs the role ARN
  (`role-to-assume`), which is not sensitive. If you ever see `aws_access_key_id`
  in a secret, that's the old static-key path — not this setup.
- **`permissions: id-token: write` is mandatory for OIDC.** Without it the runner
  can't mint the token and the "Configure AWS credentials" step fails with a
  "Credentials could not be loaded" / missing-token error. This is the #1 reason
  a first OIDC workflow fails.
- **Pushing the `gh workflow` scope file.** The `gh` token here has the
  `workflow` scope, so committing `.github/workflows/*.yml` and pushing is
  allowed. A token without it is rejected on push with a `refusing to allow ...
  workflow` error.
- **A re-run of the same commit can fail the push step.** The repo is IMMUTABLE,
  so a SHA tag can't be overwritten. Re-running a job for a commit whose image is
  already pushed will error on `docker push`. That's expected — make a new commit
  to get a new SHA, or skip the push on re-runs.
