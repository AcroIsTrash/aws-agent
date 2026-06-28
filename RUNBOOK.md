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

## Step 7 — Test the pipeline end-to-end

> **Repo layout note.** The agent source is *not* in this repo. The Dockerfile
> clones `AcroIsTrash/ai_agent` at build time and runs its `main.py`. This repo
> is the infra + pipeline. Consequence: the workflow triggers on push to
> **`aws-agent`** `main`, so a change to the *agent* (in `ai_agent`) does **not**
> trigger a deploy by itself — you change `ai_agent`, then trigger an
> `aws-agent` build (push to main, or a manual `workflow_dispatch` run).

### Prerequisites (all must be true or the first run fails)

- `AWS_ROLE_ARN` secret set; the IAM role's trust policy allows this repo's OIDC.
- `EC2_INSTANCE_ID` repo variable set (or switch the workflow to `secrets.`).
- ECR repo exists (`terraform apply`, Step 1).
- Instance profile applied and `awscli` present on the running box (Step 5).
  `user_data` only runs at first boot, so on an existing box install it once:
  `sudo apt-get install -y awscli`.

### Happy path — prove a change goes live

```bash
# 1. Make a small VISIBLE change in the agent repo (e.g. tweak a banner/prompt
#    string in ai_agent's main.py), commit, push to its main.

# 2. Trigger an aws-agent build so the image rebuilds (re-cloning ai_agent):
#    - merge/push to aws-agent main, OR
#    - Actions tab -> "Build and push agent image" -> Run workflow (dispatch)
```

- **Watch the Actions run**: `build-and-push` → `deploy`, both green.
- **Confirm the image landed**:
  ```bash
  aws ecr list-images --repository-name aws-agent --region "$REGION"
  ```
- **Confirm it's live on the box** (no SSH needed — same SSM path as the deploy):
  ```bash
  aws ssm start-session --target "$INSTANCE_ID"   # then on the box:
  docker run -it aws-agent          # local :latest tag points at the new image
  # ...exercise the agent, confirm your visible change shows.
  ```

### Failure path — prove a broken build does NOT deploy

This is the part that signals maturity: `deploy` is gated behind
`build-and-push` (`needs:`), so a failed build means deploy never runs.

```bash
# Introduce a deliberate, reversible build break and push to main, e.g.:
#   - a syntax error in the Dockerfile, or
#   - a bad dependency so `uv sync` fails.
```

- Expect: `build-and-push` goes **red**, `deploy` shows **skipped**.
- Confirm **no new image** in ECR and the box still runs the previous image.
- Revert the break, push again, confirm green.

### Where to look when something is silent

- **Actions logs** — the `deploy` step prints the box's stdout/stderr from the
  SSM command invocation.
- **SSM command history** — `aws ssm list-commands` / `get-command-invocation`.
- **On the box** — `sudo cat /var/log/cloud-init-output.log` for first-boot
  (user_data) issues like a failed docker build or missing awscli.

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
