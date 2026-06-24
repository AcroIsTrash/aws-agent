terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.0"
}

provider "aws" {
  region = "us-east-1"
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
  iam_instance_profile   = aws_iam_instance_profile.ec2.name # Layer 3 Step 2: SSM + ECR pull
  key_name               = "AgentServer"                     # key pair already in AWS from Layer 1

  # Install Docker, clone the repo, and pre-build the image.
  # The agent is a CLI REPL, so you run it interactively after SSHing in.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y docker.io git
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    # AWS CLI — required so the SSM deploy can authenticate to ECR (Layer 3 Step 3).
    # Without this the deploy's `aws ecr get-login-password` fails with `aws: not found`.
    snap install aws-cli --classic

    git clone https://github.com/AcroIsTrash/aws-agent.git /opt/aws-agent
    cd /opt/aws-agent
    docker build -t aws-agent .
  EOF

  tags = { Name = "aws-agent" }
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
