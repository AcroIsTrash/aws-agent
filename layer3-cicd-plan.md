# Layer 3 — Step 0: CI/CD Pipeline Plan

**Goal (from the README):** push to `main` → image builds → agent redeploys
automatically. No more manual SSH to pull and rebuild.

This document locks in the *shape* of the pipeline before any YAML is written.
The decisions — and the reasoning behind them — are the portfolio material.

---

## Decision 1 — Where the image lives: **Amazon ECR (private)**

| Option | Pros | Cons |
|--------|------|------|
| **Amazon ECR** ✅ | Keeps the whole stack inside the AWS story (consistent narrative); native IAM auth, no extra credentials; free tier covers low storage | One more AWS resource to manage |
| GitHub Container Registry (GHCR) | Simplest path from Actions (same platform) | Breaks the "all AWS" throughline; a second identity/permission system |

**Chosen: ECR.** The rest of the infra is AWS and Terraform-managed, so the
registry should be too. The repo is created as code (`aws_ecr_repository`, Step 1),
kept private, and the runner authenticates with the same IAM identity it already
needs for deploy. The slightly-harder option is the stronger portfolio signal:
it shows the pieces fitting into one coherent platform rather than bolting on the
path of least resistance.

---

## Decision 2 — How the new image reaches EC2: **AWS SSM Run Command**

| Option | Pros | Cons |
|--------|------|------|
| **SSM Run Command** ✅ | No inbound SSH needed — port 22 can eventually close; no long-lived SSH private key stored as a GitHub secret; more production-like; auditable command history in SSM | Instance needs an IAM instance profile + SSM agent (preinstalled on Ubuntu) |
| SSH from the runner + `docker pull`/`run` | Dead simple to wire up | Requires a private key in GitHub secrets and an open inbound SSH path from the runner — exactly the surface we spent Layer 2 being careful about |

**Chosen: SSM Run Command.** The deploy step becomes
`aws ssm send-command` targeting the instance, which runs a small script on the
box: log in to ECR, `docker pull` the new image, prune old ones. This removes the
need to expose SSH to GitHub's runners and removes a leakable long-lived secret —
the judgment signal that matters in a CI/CD layer.

**What this adds to the infra:** an IAM instance profile on the EC2 instance
granting `AmazonSSMManagedInstanceCore` + ECR pull. Defined in Terraform,
consistent with Layer 2.

---

## Decision 3 — What "redeploy" means for a CLI REPL agent

The agent is an interactive CLI REPL (`docker run -it ...`), **not** a
long-running service. So "redeploy" does **not** mean restart a daemon or do a
zero-downtime swap.

**It means:** the box always has the latest image pulled and tagged, ready to
`docker run`. The deploy step's only job is to make the newest image present on
the instance. No health checks, no rolling restart, no service manager — those
would be theater for a workload that nobody is holding a connection to.

(When Layer 4 turns this into a long-running service / self-hosted model, the
redeploy definition gets revisited — that's the right time, not now.)

---

## Authentication: prefer GitHub OIDC over static keys

Step 2 calls for a least-privilege IAM identity for the runner. The plan is to
use **GitHub OIDC → an IAM role** rather than a long-lived IAM user with access
keys, so there are no static credentials to rotate or leak. If OIDC proves
fiddly to wire up, fall back to a dedicated IAM user with keys in GitHub
secrets — but OIDC is the target. Either way the permissions are scoped to
**ECR push/pull + SSM SendCommand only**, never the AdministratorAccess user
from Layer 2.

---

## Resulting pipeline shape (GitHub Actions, on push to `main`)

1. **Checkout** the repo.
2. **Authenticate to AWS** via OIDC role assumption (least-privilege).
3. **Log in to ECR.**
4. **Build** the image; tag it both `:latest` and `:<git-sha>` (sha tag gives a
   rollback target and a traceable link from a running image back to a commit).
5. **Push** both tags to ECR.
6. **Deploy** via `aws ssm send-command` → the instance pulls `:latest` and
   prunes old images.

That's the contract for the rest of Layer 3:

- **Step 1** — ECR repo (Terraform).
- **Step 2** — least-privilege IAM (OIDC role preferred).
- **Steps 3+** — the Actions workflow that implements the six stages above.
