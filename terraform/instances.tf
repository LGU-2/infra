/*
 * ASG 밖의 인스턴스들이다.
 *
 * 모니터링은 ASG 에 넣지 않는다 (INF-24).
 * desired 0 이 EBS 까지 지워 Prometheus 와 Loki 데이터가 사라진다.
 *
 * 배치는 ASG 밖 단독이다 (INF-05).
 * 롤링으로 바꾸면 구버전과 신버전 배치가 겹쳐 "프로세스는 항상 하나" 전제가 깨진다.
 */

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = var.instance_types["monitoring"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.mon.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["monitoring"].name

  # 관측 데이터가 쌓인다. 앱보다 크게 잡는다.
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  /*
   * 관측 스택을 아직 올리지 않는다. Docker 만 깔아 둔 미완성 상태다.
   * Prometheus, Grafana, Loki, Alertmanager 는 컨테이너로 돌지만 그 compose 와 설정이 이 저장소에 없다.
   * INF-32 가 "Git 으로 관리하고 읽기 전용 마운트" 로 방향만 정해 두었고 갖다 놓는 경로는 미정이다.
   */
  user_data_base64 = base64encode(local.standalone_user_data)

  tags = {
    Name = "${var.project}-monitoring"
    Role = "monitoring"
  }

  lifecycle {
    # EBS 에 관측 데이터가 있다. 태우면 되돌릴 수 없다.
    prevent_destroy = true
  }
}

# 앱과 같은 jar 를 prod,batch 프로필로 띄운다. ALB 에 붙지 않는다.
resource "aws_instance" "batch" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = var.instance_types["batch"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.batch.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["batch"].name
  user_data_base64       = base64encode(local.batch_user_data)

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project}-batch"
    Role = "batch"
  }
}

/*
 * 시험 시간에만 기동한다 (월 약 40시간).
 * 상시 가동 전제의 예외라 count 로 끈다.
 */
resource "aws_instance" "load_test" {
  count = var.load_test_enabled ? 1 : 0

  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.instance_types["load_test"]
  subnet_id              = aws_subnet.public["a"].id
  vpc_security_group_ids = [aws_security_group.lt.id]
  iam_instance_profile   = aws_iam_instance_profile.instance["lt"].name
  user_data_base64       = base64encode(local.standalone_user_data)

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = "${var.project}-load-test"
    Role = "load-test"
  }
}
