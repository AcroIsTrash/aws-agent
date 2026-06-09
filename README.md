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
- **API key exposure** — `.pem` file and any file containing the key are in `.gitignore`. Verified before the first `git push`.
- **Instance left running** — instance is stopped when not actively in use. Termination is the plan once Layer 2 replaces this setup.
- **Free tier drift** — `t3.micro` is free-tier eligible, but `t3.small` and above are not. Stayed on `micro` and left the billing alarm as a backstop.

---

## What's next

This is the ugly version on purpose. The next layers make it reproducible and professional:

**Layer 2 — Containerize + Terraform**
Docker container for the agent. Terraform to provision the VPC, subnets, security groups, and EC2 instance as code. Nothing manually clicked in the console. This layer reinforces networking fundamentals directly.

**Layer 3 — CI/CD**
GitHub Actions pipeline. Push to main, tests run, agent redeploys automatically. No more `scp`.

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
