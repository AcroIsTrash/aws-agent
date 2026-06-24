# Layer 3, Step 2: least-privilege IAM for the CI/CD pipeline.
#
# There are TWO separate identities here, and keeping them straight is the point:
#
#   1. Runner role (aws-agent-github-actions) — the GitHub Actions job, authed via
#      OIDC with NO stored AWS keys. Allowed to push to ECR + fire one SSM command.
#   2. EC2 instance profile (aws-agent-ec2) — the deploy *target* box. Allowed to
#      be managed by SSM + PULL from ECR.
#
# The runner is the deployer; the instance profile is the deploy target's
# permission to receive the command and pull the image. Full reasoning lives in
# layer3-cicd-plan.md -> "Authentication".

data "aws_caller_identity" "current" {}

# ── 1. Trust GitHub's OIDC issuer (one provider per AWS account) ───────────────
# Why OIDC instead of a long-lived IAM user with access keys: the runner mints a
# short-lived token per job, AWS trusts GitHub's issuer, and credentials expire
# in ~1h. There is no static secret sitting in GitHub to leak or rotate.
#
# The provider needs a CA thumbprint; fetch it dynamically with the tls provider
# rather than pasting a magic string. (Add `tls` to required_providers in main.tf.)

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ── 2. Runner role — the deployer identity ─────────────────────────────────────
# TRUST POLICY ("who may assume me"): only an OIDC token from the provider above,
# AND only from THIS repo on the main branch. The sub condition is the security —
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
          # Exact branch (repo's default is master). To allow tags or many
          # branches, switch this block to StringLike with a wildcard, e.g.
          # "repo:AcroIsTrash/aws-agent:*".
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
      {
        # The workflow polls the command status to fail on a bad deploy. These
        # read-only actions don't support resource-level scoping, so "*".
        Sid    = "SSMPollStatus"
        Effect = "Allow"
        Action = [
          "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation",
        ]
        Resource = "*"
      },
    ]
  })
}

# ── 3. EC2 instance profile — the deploy-target identity ───────────────────────
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
