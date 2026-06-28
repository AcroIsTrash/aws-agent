terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.0"
}

variable "aws_region" {
  description = "AWS region for all resources"
  default     = "us-east-1"
}

provider "aws" {
  region = var.aws_region
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "aws-agent-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags                    = { Name = "aws-agent-public" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "aws-agent-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "aws-agent-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security group ────────────────────────────────────────────────────────────

resource "aws_security_group" "agent" {
  name        = "aws-agent-sg"
  description = "SSH in, all traffic out"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aws-agent-sg" }
}

# ── Container registry (ECR) ──────────────────────────────────────────────────
# Layer 3, Step 1: a private registry to hold the agent image. CI builds the
# image once and pushes it here; EC2 pulls it. The repo is created empty —
# the first image arrives via the manual push verification, then the pipeline.

resource "aws_ecr_repository" "agent" {
  name = "aws-agent"

  # IMMUTABLE: a tag, once pushed, can never be overwritten. This makes the
  # git-SHA tags from the pipeline a trustworthy rollback target — :a1b2c3d
  # always means that exact build. Trade-off: you deploy by SHA tag, never by
  # re-pushing a moving :latest.
  image_tag_mutability = "IMMUTABLE"

  # Free CVE scan on every push. Cheap portfolio point, surfaces known
  # vulnerabilities in the image without any extra tooling.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Dev convenience: let `terraform destroy` delete the repo even if it still
  # holds images. In production you'd leave this false so the registry can't be
  # torn down by accident.
  force_delete = true

  tags = { Name = "aws-agent" }
}

# Auto-expire old untagged images so storage stays near-zero on free tier.
# Untagged images pile up every time an immutable tag is replaced by a newer
# build; nothing references them, so reap them after a day.
resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 1 day"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}

# ── IAM: EC2 instance profile (SSM + ECR pull) ────────────────────────────────
# Layer 3, Step 5: the CI/CD deploy uses SSM Run Command to tell the box to pull
# the new image. For that the instance needs (1) SSM agent connectivity and
# (2) permission to pull from ECR — both granted through this instance profile.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "aws-agent-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "aws-agent-ec2" }
}

# Lets SSM Run Command reach the instance (the deploy mechanism).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only ECR so the box can `docker pull` — it never pushes.
resource "aws_iam_role_policy_attachment" "ecr_pull" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "agent" {
  name = "aws-agent-ec2"
  role = aws_iam_role.agent.name
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "agent" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.agent.id]
  key_name               = "AgentServer" # key pair already in AWS from Layer 1
  iam_instance_profile   = aws_iam_instance_profile.agent.name

  # Install Docker, git, and the AWS CLI. The CLI is needed so the SSM deploy
  # can run `aws ecr get-login-password` on the box. The SSM agent itself ships
  # preinstalled on Canonical's Ubuntu AMI — the instance profile is what
  # actually activates it.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y docker.io git awscli
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    git clone https://github.com/AcroIsTrash/aws-agent.git /opt/aws-agent
    cd /opt/aws-agent
    docker build -t aws-agent .
  EOF

  tags = { Name = "aws-agent" }
}

# ── GitHub Actions OIDC (runner identity) ─────────────────────────────────────
# Layer 3, Step 2: the CI runner assumes this role via OIDC — no static AWS keys
# stored in GitHub. Trust is scoped to this exact repo so forks can't assume it.

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience GitHub Actions requests when minting the OIDC token.
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint (stable; rotated by GitHub, not by us).
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope to this repo only — any branch/event. Tighten to :ref:refs/heads/master
    # if you want to restrict to master pushes only.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:AcroIsTrash/aws-agent:*"]
    }
  }
}

resource "aws_iam_role" "github_runner" {
  name               = "aws-agent-github-runner"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json
  tags               = { Name = "aws-agent-github-runner" }
}

# Least-privilege for the build-and-push job: push to this ECR repo only.
data "aws_iam_policy_document" "runner_ecr_push" {
  # GetAuthorizationToken is account-scoped — cannot be narrowed to one repo.
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/aws-agent"
    ]
  }
}

resource "aws_iam_policy" "runner_ecr_push" {
  name   = "aws-agent-runner-ecr-push"
  policy = data.aws_iam_policy_document.runner_ecr_push.json
}

resource "aws_iam_role_policy_attachment" "runner_ecr" {
  role       = aws_iam_role.github_runner.name
  policy_arn = aws_iam_policy.runner_ecr_push.arn
}

# Least-privilege for the deploy job: SSM SendCommand on this instance + the
# standard document; GetCommandInvocation to read the result back.
data "aws_iam_policy_document" "runner_ssm_deploy" {
  statement {
    actions   = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      aws_instance.agent.arn,
    ]
  }

  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  # The deploy step calls sts:GetCallerIdentity to derive the account ID.
  statement {
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "runner_ssm_deploy" {
  name   = "aws-agent-runner-ssm-deploy"
  policy = data.aws_iam_policy_document.runner_ssm_deploy.json
}

resource "aws_iam_role_policy_attachment" "runner_ssm" {
  role       = aws_iam_role.github_runner.name
  policy_arn = aws_iam_policy.runner_ssm_deploy.arn
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "instance_public_ip" {
  description = "SSH in with: ssh -i AgentServer.pem ubuntu@<ip>"
  value       = aws_instance.agent.public_ip
}

output "ecr_repository_url" {
  description = "Registry URI to tag/push against: <acct>.dkr.ecr.<region>.amazonaws.com/aws-agent"
  value       = aws_ecr_repository.agent.repository_url
}

output "github_runner_role_arn" {
  description = "Set this as the AWS_ROLE_ARN secret in the GitHub repo"
  value       = aws_iam_role.github_runner.arn
}
