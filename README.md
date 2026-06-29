# AWS AI Agent — Infrastructure-Up Portfolio Project

A LangChain calculator agent deployed to AWS EC2. The point isn't the agent — it's the infra it runs on. This is a four-layer project building toward containerized, Terraform-managed, CI/CD-deployed, observable AI infrastructure.

---

## What this is

A minimal LangChain agent with a calculator tool, running on a cloud server instead of a laptop. The agent accepts a natural-language math query, calls the OpenAI API, uses the calculator tool when needed, and returns a result.

The code is intentionally simple. A trivial agent on well-built infra signals more than a clever agent on a local machine.

---

## Infrastructure

| Component | Choice | Reason |
|-----------|--------|--------|
| Cloud provider | AWS | Standard in the field; free tier available |
| Instance type | `t3.micro` | Free-tier eligible; adequate for a lightweight API-calling agent |
| OS | Ubuntu Server | Familiarity; large support surface |
| LLM API | OpenAI | Hosted — no GPU required on the instance, no local model overhead |
| Container runtime | Docker | Reproducible environment; image built once, runs consistently anywhere |
| IaC | Terraform | Declarative infra; full VPC and networking defined as code, nothing clicked in the console |

---

## How it's set up

**1. Billing alarm first**
Before launching any resources, a budget alert was set in AWS Budgets at $5. This is the first step every time — the only genuinely bad outcome here is an unexpected bill from a forgotten running instance.

**2. EC2 launch**
Launched a `t3.micro` Ubuntu instance via the AWS Console. Created a key pair and saved the `.pem` file locally with `chmod 400` permissions.

**3. SSH and environment setup**
```bash
ssh -i AgentServer.pem ubuntu@<public-ip>
sudo apt update && sudo apt install python3-pip -y
pip install langchain langchain-openai
```

**4. API key handling**
The OpenAI API key is set as an environment variable on the instance — not hard-coded, not committed to the repo.

```bash
export OPENAI_API_KEY="sk-..."
```

For persistence across sessions, this goes in `~/.bashrc`.

**5. Code deployment**
Agent code transferred to the instance via `scp` or `git clone`. No CI/CD yet — that's Layer 3.

**6. Security group**
The instance needs outbound HTTPS (port 443) to reach the OpenAI API. AWS allows this by default. Inbound SSH (port 22) is restricted to my IP only — not `0.0.0.0/0`.

---

## Layer 2 — Containerize + Terraform

Everything that Layer 1 did by hand is now defined as code. Nothing is clicked in the console.

### Networking

The VPC setup mirrors what you'd see on a CCNA exam — each resource has a specific job:

| Resource | Purpose |
|----------|---------|
| `aws_vpc` | Isolated network boundary — all resources live inside `10.0.0.0/16` |
| `aws_subnet` | A slice of the VPC CIDR placed in one AZ; marked public so instances get a public IP |
| `aws_internet_gateway` | The VPC's on-ramp to the internet — without this, no traffic leaves |
| `aws_route_table` | Routing rules — sends `0.0.0.0/0` (all traffic) to the IGW |
| `aws_route_table_association` | Wires the route table to the subnet so the subnet actually uses the rules |

### Security group

Inbound SSH (port 22) and all outbound traffic allowed. The SSH rule is open to `0.0.0.0/0` — acceptable for a dev project, not for production (see caveats below).

### EC2 + Docker bootstrap

The instance runs a user data script on first boot: installs Docker, clones this repo, and pre-builds the image. The agent is a CLI REPL — SSH in and `docker run` to use it.

```bash
ssh -i AgentServer.pem ubuntu@<ip>
sudo docker run -it -e OPENAI_API_KEY="sk-..." aws-agent
```

### Friction points

- **IAM credentials** — Terraform requires programmatic AWS access. Root credentials work but are not recommended; an IAM user with `AdministratorAccess` is the right call.
- **User data debugging** — the bootstrap script runs as root at first boot with no interactive terminal. Errors are silent until you check `sudo cat /var/log/cloud-init-output.log`. `set -e` in the script ensures a failure stops execution rather than silently continuing.
- **Dockerfile not in git** — the `docker build` in user data failed on first deploy because the Dockerfile hadn't been committed yet. The fix is obvious in hindsight: verify `docker images` and check the cloud-init log before assuming the build ran.
- **Terraform state** — `terraform.tfstate` is local only. Committing it would expose resource IDs and is covered by `.gitignore`. In production this would live in an S3 backend with state locking via DynamoDB.

---

## Running the agent

```bash
python3 agent.py
```

Sample interaction:
```
> What is 347 multiplied by 19?
> Using calculator tool...
> 347 × 19 = 6593
```

---

## What could have gone wrong (and how I got ahead of it)

Nothing dramatic broke, but these were the real friction points to watch for:

- **Security group blocking outbound API calls** — checked the rule explicitly before assuming connectivity. Default AWS egress is open, but worth verifying rather than debugging blindly later.
- **SSH open to `0.0.0.0/0`** — the Layer 2 Terraform security group allows inbound SSH from any IP (`0.0.0.0/0`). This is not production standard; in production, inbound SSH should be restricted to a known CIDR (your office IP, a bastion host, or a VPN range). Left open here for development convenience.
- **API key exposure** — `.pem` file and any file containing the key are in `.gitignore`. Verified before the first `git push`.
- **Instance left running** — the instance was stopped when not actively in use, then **terminated** (along with its root EBS volume) once Layer 2 replaced this setup. The Layer 1 box was console-built and never Terraform-managed, so `terraform destroy` didn't touch it; it was terminated by hand on 2026-06-23.
- **Free tier drift** — `t3.micro` is free-tier eligible, but `t3.small` and above are not. Stayed on `micro` and left the billing alarm as a backstop.

---

## Layer 3 — CI/CD

Push to `master` → image builds → agent redeploys automatically. No manual SSH, no `scp`.

### Pipeline shape

One GitHub Actions job (`build-and-deploy`) does everything:

1. Authenticates to AWS via **GitHub OIDC** — no long-lived keys stored in GitHub secrets. The runner assumes a least-privilege IAM role scoped to this repo only.
2. Logs in to **Amazon ECR** (private registry, inside the same AWS account as the instance).
3. **Builds** the image from the Dockerfile; **tags it by git SHA** and pushes to ECR. The repo is `IMMUTABLE` — a tag, once pushed, can never be overwritten, so every SHA is a reliable rollback target.
4. **Deploys** via **AWS SSM Run Command** — tells the instance to pull the new image by tag. No inbound SSH from the runner, no SSH key in GitHub secrets. The instance needs only an IAM instance profile with SSM + ECR-pull permissions.

### Key decisions

| Decision | What was chosen | Why |
|----------|-----------------|-----|
| Image registry | Amazon ECR (private) | Keeps the whole stack inside AWS; native IAM auth, no separate credentials |
| Deploy mechanism | SSM Run Command | No inbound SSH path needed; no long-lived key to store or leak |
| Runner auth | GitHub OIDC → IAM role | Short-lived token per job; nothing to rotate |
| Image tags | Immutable SHA-only | Every running image traces to an exact commit; rollback = re-deploy an older SHA |

### Friction points

- **Instance profile ghost association** — Terraform's destroy/recreate of the IAM instance profile left the EC2 instance bound to the old (deleted) profile ID. AWS propagates the profile by name, not ID, but the metadata service still returned 404 until a manual disassociate + reassociate was run. Lesson: when Terraform recreates a same-named IAM resource, verify the EC2 association is pointing at the new one.
- **user_data race with the IGW** — the bootstrap script ran at first boot before the Internet Gateway route was fully propagated, causing `apt-get update` to fail silently (masked by `set -e` exiting early). Fixed with a retry loop; Docker and the AWS CLI had to be installed manually on the existing instance.
- **`awscli` removed from Ubuntu noble** — the `awscli` apt package was dropped in Ubuntu 24.04. The fix is the AWS CLI v2 installer from `awscli.amazonaws.com`, not the apt package.

---

## What's next

**Layer 2 — Containerize + Terraform** ✅
Docker + full Terraform-managed VPC, security group, ECR registry, and EC2 instance. Nothing clicked in the console.

**Layer 3 — CI/CD** ✅
GitHub Actions pipeline: OIDC auth → ECR build/push by SHA → SSM deploy. Proven with a live failure test (broken build skips deploy) and recovery.

**Layer 4 — Observability + self-hosted model**
Structured logging to CloudWatch, cost and latency dashboards, alerting. Then swap the OpenAI API for a local Ollama model on a larger instance — the capstone that ties the whole infra story together.

---

## Repo structure

```
.
├── README.md
├── RUNBOOK.md                   # step-by-step operational procedures
├── layer3-cicd-plan.md          # pipeline design decisions and trade-offs
├── Dockerfile                   # clones ai_agent at build time; image built by CI
├── main.tf                      # VPC, EC2, ECR
├── iam.tf                       # IAM roles: runner (OIDC) + EC2 instance profile
├── .github/workflows/deploy.yml # the pipeline
└── .gitignore
```

The agent source lives in a separate repo ([AcroIsTrash/ai_agent](https://github.com/AcroIsTrash/ai_agent)). The Dockerfile clones it at build time — this repo is the infra and pipeline only.

---

*Layer 3 of 4 — push to master, it deploys itself.*
