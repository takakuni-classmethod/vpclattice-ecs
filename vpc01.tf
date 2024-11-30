#############################################
# VPC
#############################################
module "vpc_1" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.16.0"

  name               = "${local.prefix}-01"
  azs                = ["ap-northeast-1a", "ap-northeast-1c"]
  public_subnets     = ["10.0.10.0/24", "10.0.20.0/24"]
  private_subnets    = ["10.0.1.0/24", "10.0.2.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
}

#############################################
# Security Group
#############################################
data "aws_ec2_managed_prefix_list" "vpclattice" {
  name = "com.amazonaws.${local.region}.vpc-lattice"
}

module "security_group_01_ecs" {
  source                  = "terraform-aws-modules/security-group/aws"
  version                 = "5.2.0"
  name                    = "${local.prefix}-01-ecs-sg"
  vpc_id                  = module.vpc_1.vpc_id
  ingress_prefix_list_ids = [data.aws_ec2_managed_prefix_list.vpclattice.id]
  ingress_rules           = ["all-all"]
  egress_cidr_blocks      = ["0.0.0.0/0"]
  egress_rules            = ["all-all"]
}

#############################################
# ECR
#############################################
resource "aws_ecr_repository" "this" {
  name         = "${local.prefix}-01"
  force_delete = true
}

resource "terraform_data" "image_build" {

  triggers_replace = [
    filesha256("docker/Dockerfile"),
  ]

  provisioner "local-exec" {
    command = "docker build -t ${aws_ecr_repository.this.repository_url}:latest docker"
  }
  provisioner "local-exec" {
    command = "docker push ${aws_ecr_repository.this.repository_url}:latest"
  }
}

#############################################
# ECS
#############################################
module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws//modules/cluster"

  cluster_name = "${local.prefix}-01"

  # Capacity provider
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }
}

resource "aws_iam_role" "this_ecs_taskexec" {
  name = "${local.prefix}-01-ecs-taskexec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "this_ecs_taskexec" {
  name = "${local.prefix}-01-ecs-taskexec-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "logs:CreateLogGroup"
        Effect   = "Allow"
        Resource = "*"
    }, ]
  })
}

resource "aws_iam_role_policy_attachment" "this_ecs_taskexec_cwl" {
  role       = aws_iam_role.this_ecs_taskexec.name
  policy_arn = aws_iam_policy.this_ecs_taskexec.arn
}

resource "aws_iam_role_policy_attachment" "this_ecs_taskexec_managed" {
  role       = aws_iam_role.this_ecs_taskexec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "this_ecs_infra" {
  name = "${local.prefix}-01-ecs-infra-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "this_ecs_infra" {
  role       = aws_iam_role.this_ecs_infra.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForVpcLattice"
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${local.prefix}-01"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.this_ecs_taskexec.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "web"
      image     = "${aws_ecr_repository.this.repository_url}:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          name          = "web-8080-http"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = "/ecs/${local.prefix}-01",
          mode                  = "non-blocking",
          awslogs-create-group  = "true",
          max-buffer-size       = "25m",
          awslogs-region        = "ap-northeast-1",
          awslogs-stream-prefix = "ecs"
        },
      }
    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = "${local.prefix}-01"
  cluster         = module.ecs_cluster.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc_1.private_subnets
    security_groups  = [module.security_group_01_ecs.security_group_id]
    assign_public_ip = false
  }

  vpc_lattice_configurations {
    port_name        = "web-8080-http"
    role_arn         = aws_iam_role.this_ecs_infra.arn
    target_group_arn = aws_vpclattice_target_group.this.arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.this_ecs_infra,
    aws_iam_role_policy_attachment.this_ecs_taskexec_cwl,
    aws_iam_role_policy_attachment.this_ecs_taskexec_managed,
  ]
}

#############################################
# VPC Lattice
#############################################
resource "aws_vpclattice_target_group" "this" {
  name = "${local.prefix}-ecs-tg"
  type = "IP"

  config {
    vpc_identifier  = module.vpc_1.vpc_id
    ip_address_type = "IPV4"
    port            = 8080
    protocol        = "HTTP"
  }
}

resource "aws_vpclattice_service" "this_01" {
  name      = "${local.prefix}-01-svc"
  auth_type = "NONE"
}

resource "aws_vpclattice_listener" "this_01" {
  name               = "${local.prefix}-01-listener"
  protocol           = "HTTP"
  service_identifier = aws_vpclattice_service.this_01.id
  default_action {
    fixed_response {
      status_code = 404
    }
  }
}

resource "aws_vpclattice_listener_rule" "this_default_01" {
  name                = "${local.prefix}-01-listener-default-rule"
  listener_identifier = aws_vpclattice_listener.this_01.listener_id
  service_identifier  = aws_vpclattice_service.this_01.id
  priority            = 1
  match {
    http_match {
      path_match {
        case_sensitive = true
        match {
          prefix = "/"
        }
      }
    }
  }
  action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.this.id
      }
    }
  }
}

resource "aws_vpclattice_listener_rule" "this_headers_01" {
  name                = "${local.prefix}-01-listener-headers-rule"
  listener_identifier = aws_vpclattice_listener.this_01.listener_id
  service_identifier  = aws_vpclattice_service.this_01.id
  priority            = 2
  match {
    http_match {
      path_match {
        case_sensitive = true
        match {
          prefix = "/headers"
        }
      }
    }
  }
  action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.this.id
      }
    }
  }
}

resource "aws_vpclattice_service_network_service_association" "this_01" {
  service_identifier         = aws_vpclattice_service.this_01.id
  service_network_identifier = aws_vpclattice_service_network.this.id
}
