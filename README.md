# AWS AI Agent — Infrastructure-Up Portfolio Project

A LangChain calculator agent deployed to AWS EC2. The point isn't the agent — it's the infra it runs on. This is Layer 1 of a four-layer project that builds toward containerized, Terraform-managed, CI/CD-deployed, observable AI infrastructure.

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
- **Instance left running** — instance is stopped when not actively in use. Termination is the plan once Layer 2 replaces this setup.
- **Free tier drift** — `t3.micro` is free-tier eligible, but `t3.small` and above are not. Stayed on `micro` and left the billing alarm as a backstop.

---

## What's next

This is the ugly version on purpose. The next layers make it reproducible and professional:

**Layer 2 — Containerize + Terraform** ✅
Done. Docker + full Terraform-managed VPC, security group, and EC2 instance. See the Layer 2 section above.

**Layer 3 — CI/CD**
GitHub Actions pipeline. Push to main, image builds, agent redeploys automatically. No more manual SSH to pull and rebuild.

**Layer 4 — Observability + self-hosted model**
Structured logging, cost dashboards, alerting. Swap the OpenAI API for a local Ollama model on a larger instance — the capstone that ties the whole infra story together.

---

## Repo structure

```
.
├── README.md
├── agent.py
├── requirements.txt
└── .gitignore        # covers .pem files, .env, __pycache__
```

---

*Layer 1 of 4 — deployed manually, documented honestly, improved in layers.*
