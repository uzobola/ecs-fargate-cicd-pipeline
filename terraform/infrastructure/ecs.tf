# ---------------------------------------------------------------------------
# ECS cluster
# ---------------------------------------------------------------------------

# ECS provides the orchestration control plane for the application.
#
# Fargate supplies the underlying compute capacity, so this project does not
# provision or manage EC2 container hosts.
resource "aws_ecs_cluster" "application" {
  name = "${var.project_name}-cluster"

  tags = {
    Name = "${var.project_name}-cluster"
  }
}


# ---------------------------------------------------------------------------
# CloudWatch application logs
# ---------------------------------------------------------------------------

# Keep frontend and backend logs separate so each service has an independent
# operational and IAM boundary.
resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/${var.project_name}/frontend"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-frontend-logs"
    Tier = "frontend"
  }
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project_name}/backend"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-backend-logs"
    Tier = "backend"
  }
}


# ---------------------------------------------------------------------------
# ECS task execution-role trust policy
# ---------------------------------------------------------------------------

# ECS tasks may assume the execution roles.
#
# These roles are used by the Fargate/ECS infrastructure for actions such as
# pulling images and publishing container logs. They are not application task
# roles and are not intended for application AWS API calls.
data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    sid     = "AllowECSTasksToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}


# ---------------------------------------------------------------------------
# Frontend execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "frontend_execution" {
  name = "${var.project_name}-frontend-execution-role"

  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = {
    Name = "${var.project_name}-frontend-execution-role"
    Tier = "frontend"
  }
}

# Scope frontend execution permissions to:
#
# - ECR authorization
# - the frontend ECR repository
# - the frontend CloudWatch log group
#
# ecr:GetAuthorizationToken does not support repository-level resource scoping,
# so that action requires Resource "*".
data "aws_iam_policy_document" "frontend_execution" {
  statement {
    sid    = "ECRAuthorization"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "PullFrontendImage"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]

    resources = [
      aws_ecr_repository.frontend.arn
    ]
  }

  statement {
    sid    = "WriteFrontendLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}/frontend:*"
    ]
  }
}

resource "aws_iam_role_policy" "frontend_execution" {
  name   = "${var.project_name}-frontend-execution"
  role   = aws_iam_role.frontend_execution.id
  policy = data.aws_iam_policy_document.frontend_execution.json
}


# ---------------------------------------------------------------------------
# Backend execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "backend_execution" {
  name = "${var.project_name}-backend-execution-role"

  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = {
    Name = "${var.project_name}-backend-execution-role"
    Tier = "backend"
  }
}

data "aws_iam_policy_document" "backend_execution" {
  statement {
    sid    = "ECRAuthorization"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "PullBackendImage"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]

    resources = [
      aws_ecr_repository.backend.arn
    ]
  }

  statement {
    sid    = "WriteBackendLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}/backend:*"
    ]
  }
}

resource "aws_iam_role_policy" "backend_execution" {
  name   = "${var.project_name}-backend-execution"
  role   = aws_iam_role.backend_execution.id
  policy = data.aws_iam_policy_document.backend_execution.json
}


# ---------------------------------------------------------------------------
# Frontend task definition
# ---------------------------------------------------------------------------

# Requirements:
#
#   512 CPU units = 0.5 vCPU
#   1024 MiB      = 1 GB memory
#
# awsvpc gives each Fargate task its own network interface and private IP.
resource "aws_ecs_task_definition" "frontend" {
  family = "${var.project_name}-frontend"

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "512"
  memory = "1024"

  execution_role_arn = aws_iam_role.frontend_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "frontend"
      image     = "${aws_ecr_repository.frontend.repository_url}:${var.app_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.frontend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  # Do not register the task definition until the execution policy is attached.
  depends_on = [
    aws_iam_role_policy.frontend_execution
  ]

  tags = {
    Name = "${var.project_name}-frontend-task"
    Tier = "frontend"
  }
}


# ---------------------------------------------------------------------------
# Backend task definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  family = "${var.project_name}-backend"

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "512"
  memory = "1024"

  execution_role_arn = aws_iam_role.backend_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = "${aws_ecr_repository.backend.repository_url}:${var.app_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "CORS_ORIGIN"
          value = "http://${aws_lb.application.dns_name}"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  depends_on = [
    aws_iam_role_policy.backend_execution
  ]

  tags = {
    Name = "${var.project_name}-backend-task"
    Tier = "backend"
  }
}


# ---------------------------------------------------------------------------
# Frontend ECS service
# ---------------------------------------------------------------------------

# The service maintains the requested number of running frontend tasks.
#
# desired_count begins at 1 to satisfy the requirements.
# Application Auto Scaling manages runtime changes between 1 and 4.
resource "aws_ecs_service" "frontend" {
  name    = "${var.project_name}-frontend"
  cluster = aws_ecs_cluster.application.id

  task_definition = aws_ecs_task_definition.frontend.arn

  desired_count = 1
  launch_type   = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  health_check_grace_period_seconds = 60

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets = [
      for az in local.selected_azs :
      aws_subnet.private[az].id
    ]

    security_groups = [
      aws_security_group.frontend.id
    ]

    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 3000
  }

  # Application Auto Scaling is allowed to change desired_count.
  #
  # Jenkins will later register new task-definition revisions and update the
  # service. Those deployment revisions belong to CI/CD rather than Terraform.
  lifecycle {
    ignore_changes = [
      desired_count,
      task_definition
    ]
  }

  depends_on = [
    aws_lb_listener.http
  ]

  tags = {
    Name = "${var.project_name}-frontend-service"
    Tier = "frontend"
  }
}


# ---------------------------------------------------------------------------
# Backend ECS service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "backend" {
  name    = "${var.project_name}-backend"
  cluster = aws_ecs_cluster.application.id

  task_definition = aws_ecs_task_definition.backend.arn

  desired_count = 1
  launch_type   = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  health_check_grace_period_seconds = 60

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets = [
      for az in local.selected_azs :
      aws_subnet.private[az].id
    ]

    security_groups = [
      aws_security_group.backend.id
    ]

    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8080
  }

  lifecycle {
    ignore_changes = [
      desired_count,
      task_definition
    ]
  }

  depends_on = [
    aws_lb_listener_rule.backend_api
  ]

  tags = {
    Name = "${var.project_name}-backend-service"
    Tier = "backend"
  }
}


# ---------------------------------------------------------------------------
# Frontend Application Auto Scaling
# ---------------------------------------------------------------------------

# Requirements:
#
#   minimum = 1
#   desired = 1
#   maximum = 4
#   CPU target = 50%
#
# desired_count is initialized by the ECS service. The scalable target defines
# the permitted runtime range.
resource "aws_appautoscaling_target" "frontend" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"

  resource_id = "service/${aws_ecs_cluster.application.name}/${aws_ecs_service.frontend.name}"

  min_capacity = 1
  max_capacity = 4
}

resource "aws_appautoscaling_policy" "frontend_cpu" {
  name = "${var.project_name}-frontend-cpu-50"

  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.frontend.service_namespace
  scalable_dimension = aws_appautoscaling_target.frontend.scalable_dimension
  resource_id        = aws_appautoscaling_target.frontend.resource_id

  target_tracking_scaling_policy_configuration {
    target_value = 50

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_out_cooldown = 60
    scale_in_cooldown  = 60
  }
}


# ---------------------------------------------------------------------------
# Backend Application Auto Scaling
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "backend" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"

  resource_id = "service/${aws_ecs_cluster.application.name}/${aws_ecs_service.backend.name}"

  min_capacity = 1
  max_capacity = 4
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name = "${var.project_name}-backend-cpu-50"

  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.backend.service_namespace
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension
  resource_id        = aws_appautoscaling_target.backend.resource_id

  target_tracking_scaling_policy_configuration {
    target_value = 50

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_out_cooldown = 60
    scale_in_cooldown  = 60
  }
}