/*
 * Ubuntu 24.04 LTS.
 * t3 와 t3a 는 x86, t4g 는 ARM 이라 이미지를 따로 찾는다.
 */
data "aws_ami" "ubuntu_x86" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

/*
 * 앱과 배치는 같은 jar 를 쓰고 프로필로만 갈린다.
 * 앱에는 batch 가 절대 들어가면 안 된다 (INF-12-07).
 * 들어가면 앱 대수만큼 스케줄러가 함께 돌고, 분산 락이 없어 아무것도 막지 못한다.
 */
locals {
  common_bootstrap = file("${path.module}/templates/common-bootstrap.sh")
  alloy_config     = file("${path.module}/../observability/alloy/config.alloy")

  # 최초 부팅과 재배포가 같은 코드를 쓴다
  refresh_env = templatefile("${path.module}/templates/refresh-env.sh.tftpl", {
    project    = var.project
    region     = var.region
    github_org = var.github_org
  })

  # 모니터링도 같은 이유로 갱신 경로가 필요하다. 다만 읽는 값과 쓰는 자리가 달라 별도다
  refresh_monitoring_env = templatefile("${path.module}/templates/refresh-monitoring-env.sh.tftpl", {
    project     = var.project
    region      = var.region
    db_username = var.db_username
  })

  /*
   * ASG 밖 인스턴스용이다. Docker 와 AWS CLI 만 깔고 끝난다.
   * 모니터링은 관측 스택을, 부하 생성은 k6 를 컨테이너로 돌리지만 그것을 올리는 것은 이 스크립트가 아니다.
   */
  standalone_user_data = "#!/bin/bash\n${local.common_bootstrap}"

  monitoring_user_data = templatefile("${path.module}/templates/monitoring-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    infra_repo       = var.github_infra_repo
    db_username      = var.db_username
    refresh_env      = local.refresh_monitoring_env
  })

  compose_args = {
    project     = var.project
    github_org  = var.github_org
    db_name     = var.db_name
    db_username = var.db_username
  }

  app_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod", role = "app" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod" })
  })

  batch_user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    common_bootstrap = local.common_bootstrap
    project          = var.project
    region           = var.region
    github_org       = var.github_org
    refresh_env      = local.refresh_env
    alloy            = local.alloy_config
    compose          = templatefile("${path.module}/templates/compose.yaml.tftpl", merge(local.compose_args, { profiles = "prod,batch", role = "batch" }))
    unit             = templatefile("${path.module}/templates/systemd.service.tftpl", { project = var.project, profiles = "prod,batch" })
  })
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.ubuntu_x86.id
  instance_type = var.instance_types["app"]

  iam_instance_profile {
    name = aws_iam_instance_profile.instance["app"].name
  }

  vpc_security_group_ids = [aws_security_group.app.id]
  user_data              = base64encode(local.app_user_data)

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 토큰을 요구한다. SSRF 로 자격증명이 새는 경로를 막는다.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project}-app"
      Role = "app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * max_size 가 2여야 배포 절차가 성립한다.
 * 신규를 먼저 띄우므로 배포 중 일시적으로 2대가 된다. desired 를 2로 두면 띄울 자리가 없다.
 *
 * desired_capacity 는 배포 스크립트가 조절한다. Terraform 이 되돌리면 배포가 깨진다.
 */
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-app"
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  min_size         = 0
  desired_capacity = 1
  max_size         = 2

  # ELB 헬스체크를 본다. 프로세스는 살아 있는데 응답을 못 하는 경우를 잡는다.
  health_check_type         = "ELB"
  health_check_grace_period = 300

  target_group_arns = [
    aws_lb_target_group.app.arn,
    aws_lb_target_group.liveness.arn,
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

/*
 * 스케일 인 때 배치가 돌고 있으면 기다린다 (OPS-1-04).
 * heartbeat_timeout 은 배치 최대 실행 시간 + 여유여야 하는데 아직 측정 전이다.
 * 부하 시험 후 실제 값으로 줄인다.
 */
resource "aws_autoscaling_lifecycle_hook" "app_terminating" {
  name                   = "${var.project}-drain"
  autoscaling_group_name = aws_autoscaling_group.app.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300
  default_result         = "CONTINUE"
}
