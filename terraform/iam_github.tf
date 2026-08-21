/*
 * GitHub Actions 에 장기 액세스 키를 두지 않는다.
 * OIDC 로 토큰을 받아 역할을 맡고, 신뢰 조건에 저장소와 브랜치를 못 박는다.
 *
 * 배포는 fm-backend 의 main 브랜치에서만 된다.
 * 다른 브랜치나 다른 저장소에서 이 역할을 맡으려 하면 STS 가 거부한다.
 */

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  github_roles = {
    deploy = {
      description = "deploy on merge to fm-backend main"
      subject     = "repo:${var.github_org}/${var.github_backend_repo}:ref:refs/heads/main"
    }
    tf_plan = {
      description = "terraform plan from fm-infra pull requests"
      subject     = "repo:${var.github_org}/${var.github_infra_repo}:pull_request"
    }
  }
}

data "aws_iam_policy_document" "github_assume" {
  for_each = local.github_roles

  statement {
    effect  = "Allow"
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

    # 이 조건이 없으면 GitHub 의 아무 저장소나 역할을 맡을 수 있다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value.subject]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each = local.github_roles

  name               = "${var.project}-gha-${each.key}"
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.github_assume[each.key].json
}

/*
 * 배포 절차가 하는 일만 준다.
 * SSM 값 갱신, desired 조정, 대상 상태 조회, 구 인스턴스 종료다.
 * 인프라를 만들거나 지우는 권한은 주지 않는다. 그건 Terraform 이 한다.
 */
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "UpdateCurrentSha"
    effect    = "Allow"
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/current-sha"]
  }

  statement {
    sid    = "RollInstances"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]

    resources = ["*"]

    # 이 프로젝트의 ASG 만 건드릴 수 있다.
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid    = "ObserveOnly"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "ec2:DescribeInstances",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeLoadBalancers",
      "rds:DescribeDBInstances",
      "elasticache:DescribeReplicationGroups",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "route53:GetHealthCheckStatus",
      "cloudwatch:GetMetricStatistics",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.github["deploy"].id
  policy = data.aws_iam_policy_document.deploy.json
}

/*
 * plan 은 모든 리소스를 읽어야 실제 상태와 코드를 비교할 수 있다.
 * 서비스마다 읽기 액션 이름이 달라 직접 나열하면 계속 빠진다. AWS 관리형 정책을 쓴다.
 */
resource "aws_iam_role_policy_attachment" "tf_plan_readonly" {
  role       = aws_iam_role.github["tf_plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# 상태 파일을 읽고 쓰는 것은 잠금 때문에 필요하다. plan 이 잠금을 잡았다 푼다.
data "aws_iam_policy_document" "tf_plan_state" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::tfstate-${var.project}", "arn:aws:s3:::tfstate-${var.project}/*"]
  }
}

resource "aws_iam_role_policy" "tf_plan_state" {
  name   = "tf-plan-state"
  role   = aws_iam_role.github["tf_plan"].id
  policy = data.aws_iam_policy_document.tf_plan_state.json
}

output "github_role_arns" {
  description = "GitHub Actions 변수에 넣을 값. deploy 는 fm-backend, tf_plan 은 fm-infra"
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}
