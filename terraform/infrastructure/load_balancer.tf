# ---------------------------------------------------------------------------
# Public Application Load Balancer
# ---------------------------------------------------------------------------

# The Application Load Balancer is the single public entry point for both the
# frontend and backend services.
#
# It spans the two public subnets created in Phase 3C so the load-balancing tier
# is not tied to one Availability Zone.
#
# ECS tasks will remain in private subnets. Only the ALB receives direct public
# application traffic.
resource "aws_lb" "application" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = [
    for az in local.selected_azs :
    aws_subnet.public[az].id
  ]

  # Reject malformed HTTP header fields rather than forwarding them to the
  # application targets.
  drop_invalid_header_fields = true

  # This challenge environment must be removable after validation.
  # A production environment may choose deletion protection based on its
  # operational controls.
  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
    Tier = "edge"
  }
}


# ---------------------------------------------------------------------------
# Frontend target group
# ---------------------------------------------------------------------------

# ECS Fargate tasks using awsvpc networking are registered in ALB target groups
# by IP address rather than EC2 instance ID.
#
# The frontend Nginx container listens on TCP/3000.
resource "aws_lb_target_group" "frontend" {
  name = "${var.project_name}-frontend-tg"

  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  # The frontend serves a static application. A successful response from "/"
  # confirms that Nginx is reachable and serving the compiled application.
  health_check {
    enabled = true

    protocol = "HTTP"
    path     = "/"
    port     = "traffic-port"

    matcher = "200-399"

    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # The application uses short HTTP requests, so a 30-second deregistration
  # delay is sufficient for this challenge and avoids unnecessarily slow ECS
  # deployment draining later.
  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-frontend-tg"
    Tier = "frontend"
  }
}


# ---------------------------------------------------------------------------
# Backend target group
# ---------------------------------------------------------------------------

# The backend Express container listens on TCP/8080.
#
# It has an explicit /health endpoint, which gives the load balancer a dedicated
# liveness signal instead of using the application API response itself.
resource "aws_lb_target_group" "backend" {
  name = "${var.project_name}-backend-tg"

  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled = true

    protocol = "HTTP"
    path     = "/health"
    port     = "traffic-port"

    matcher = "200"

    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-backend-tg"
    Tier = "backend"
  }
}


# ---------------------------------------------------------------------------
# HTTP listener
# ---------------------------------------------------------------------------

# Port 80 is the public listener for the challenge environment.
#
# Requests that do not match a more specific listener rule are sent to the
# frontend target group.
#
# A production deployment would normally terminate TLS on the ALB with an ACM
# certificate and redirect HTTP to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}


# ---------------------------------------------------------------------------
# Backend path routing
# ---------------------------------------------------------------------------

# Route API requests to the backend target group.
#
# Both patterns are included deliberately:
#
#   /api    -> backend
#   /api/*  -> backend
#
# All other paths fall through to the listener's default frontend action.
resource "aws_lb_listener_rule" "backend_api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = [
        "/api",
        "/api/*"
      ]
    }
  }
}
