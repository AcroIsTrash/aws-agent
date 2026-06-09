# Portfolio Project Plan: The Infrastructure-Up AI Project

## The throughline

One project, built in layers, that tells a single story:

> **"I understand the infrastructure AI runs on, from the network layer up."**

This is the seam most portfolios miss. Bootcamp grads know app-layer AI but not networking. Network engineers know packets but not AI infra. The goal is to sit in the gap between them — and to *show judgment*, not just that things run.

**Guiding rules:**
- It's **one project that grows**, not four separate projects. Each layer is a small addition to a thing that already works.
- **Ship ugly, then improve in layers.** Something public and working beats something perfect and unstarted.
- The **README is the portfolio.** Recruiters read the README, not the code. Document *why* you made each trade-off — that's the part that signals judgment.
- **CCNA is the priority.** Layer 1 reinforces CCNA so it's nearly free against study time. Later layers are real additional time — pace them, don't turn this into a second full-time push.
- **Cloud platform: AWS.** Decided. Stay on free tier while learning.

---

## The four layers (overview)

| Layer | What it demonstrates | Status |
|-------|---------------------|--------|
| **1. Deploy the agent (ugly)** | Can stand up cloud infra and run an AI workload that isn't on my laptop | **← flesh out below** |
| **2. Containerize + Terraform networking** | Reproducibility + the networking layer (reinforces CCNA directly) | Noted, not yet detailed |
| **3. CI/CD automation** | The "automation" differentiator the field is shifting toward | Noted, not yet detailed |
| **4. Observability, cost controls + self-hosted model** | The judgment / orchestrator layer + AI-infra fluency (Ollama capstone) | Noted, not yet detailed |

> Layers 2–4 are intentionally left as headlines for now. Detail them when Layer 1 is shipped and public.

---

## Layer 1 — Deploy the existing agent to AWS (the ugly version)

**Goal:** Get the LangChain calculator agent I already have running on a server that isn't my laptop, document it, push it public. That's it. No containers, no Terraform, no pipeline yet.

**Scope guardrails:**
- Keep the agent pointed at its current **hosted LLM API** (API key in an env var, one outbound call). **Do NOT connect Ollama yet** — a free-tier instance can't run a local model, and it muddies the story. Ollama is the Layer 4 capstone.
- Calculator-tool-only agent is fine. Simple is the point. A trivial agent on well-built infra reads as competence; a clever agent on a laptop reads as a hobby.

### Step 0 — Set a billing alarm FIRST (before launching anything)
- In **AWS Budgets**, create a budget with an alert at **~$5**.
- Do this before launching a single resource. The catastrophic outcome here isn't "built it wrong," it's "left something running and got a surprise bill." Five minutes; closes the only genuinely bad door.

### Step 1 — Launch the server
- Launch a single **EC2 `t3.micro`** instance (free-tier eligible).
- Choose Amazon Linux or Ubuntu (either is fine; Ubuntu if you want familiarity).
- Create/download the key pair so you can SSH in. Save it somewhere you won't lose it.

### Step 2 — Get in and set up the environment
- SSH into the instance.
- Install Python and your dependencies (whatever the agent needs — `pip install` the requirements).
- Get the code onto the box (git clone from your repo, or scp it up).

### Step 3 — Wire up the one thing that will fight you
- The agent calls a hosted LLM API, so it needs:
  - The **API key** set as an environment variable on the instance (not hard-coded, not committed to git).
  - An **outbound connection** allowed — usually fine by default, but if it can't reach the API, check the **security group** rules.
- **Expect friction here.** A security group rule or a port or an env var will probably trip you up for an evening. That's normal, not failure. The write-up of how you solved it is portfolio material.

### Step 4 — Run it
- Run the agent. Confirm it responds (give it a calculator query, watch it call the tool).
- It's running on cloud infra now. Layer 3 (from the original arc), ugliest possible version — done.

### Step 5 — Write the README as you go
Include:
- **What** I deployed and **how** (instance type, OS, steps).
- **What broke** and how I fixed it. ← the honest signal recruiters respect most.
- **What I'd improve** next (this naturally previews Layers 2–4).

### Step 6 — Push public
- Public GitHub repo. README front and center.
- `.gitignore` the API key / any secrets. Never commit credentials.

### Step 7 — (Optional but smart) Tear it down
- If you're not actively iterating, **stop or terminate the instance** so it's not idling on the meter.
- You can relaunch when you start Layer 2.

---

## Definition of done for Layer 1
- [ ] Billing alarm set at ~$5
- [ ] Agent runs on EC2, reachable, responds to a query
- [ ] Public GitHub repo with a README covering what / how / what broke / what's next
- [ ] No secrets committed
- [ ] Instance stopped/terminated if idle

When all boxes are checked: **Layer 1 is shipped.** Come back and flesh out Layer 2 (containerize + Terraform the networking — the layer that reinforces CCNA).

---

## Reminder to self
The perfectionism loop dies when there's already something public that works. The assignment this week is the *ugly* deploy — not a nice one. Make it good in layers, after it exists.
