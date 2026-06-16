---
title: AWS AI Agent — Infrastructure-Up Portfolio
description: A LangChain agent deployed to AWS — but the point isn't the agent, it's the infrastructure underneath it. Built in four layers from a bare EC2 box to a containerized, Terraform-managed, CI/CD deployment.
status: active
startDate: 2026-04-01
order: 1
featured: true
tags: ['AWS', 'Terraform', 'Docker', 'EC2', 'LangChain', 'Infrastructure']
repo: https://github.com/AcroIsTrash/aws-agent
---

### The idea

One project, built in layers, that tells a single story: *I understand the infrastructure AI runs on, from the network layer up.* A trivial agent on well-built infrastructure signals more than a clever agent running on a laptop. So the agent itself is deliberately simple — a LangChain calculator tool — and all the work goes into the layers underneath it.

### Layer 1 — Deploy it ugly

Get the agent running on a server that isn't my laptop, document it honestly, and push it public. A `t3.micro` EC2 instance, Ubuntu, the API key in an environment variable, and a billing alarm set *before* launching anything — because the only genuinely bad outcome here is a forgotten instance running up a surprise bill.

### Layer 2 — Containerize + Terraform

Everything Layer 1 did by hand is now defined as code. Nothing is clicked in the console. A full VPC, subnet, internet gateway, route table, and security group — the networking maps directly onto what you'd see on a CCNA exam, which is the point. The instance runs a user-data script on first boot that installs Docker, clones the repo, and pre-builds the image.

The honest friction points — silent user-data failures you only find in `cloud-init-output.log`, a `docker build` that failed because the Dockerfile wasn't committed yet, local-only Terraform state — are written up in the README, because that's the part that actually signals judgment.

### Layers 3 & 4 — What's next

- **CI/CD:** a GitHub Actions pipeline so a push to main rebuilds the image and redeploys automatically — no more manual SSH to pull and rebuild.
- **Observability + self-hosted model:** structured logging, cost dashboards, alerting, and swapping the hosted API for a local Ollama model on a larger instance. The capstone that ties the whole infrastructure story together.

Shipped ugly on purpose, improved in layers.
