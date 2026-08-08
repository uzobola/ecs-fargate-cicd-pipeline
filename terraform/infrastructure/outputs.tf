# Repository names are useful for AWS CLI and CI/CD commands.
output "frontend_ecr_repository_name" {
  description = "Name of the frontend ECR repository."
  value       = aws_ecr_repository.frontend.name
}

output "backend_ecr_repository_name" {
  description = "Name of the backend ECR repository."
  value       = aws_ecr_repository.backend.name
}

# Repository URLs are the registry destinations used when tagging Docker images
# before pushing them to ECR.
output "frontend_ecr_repository_url" {
  description = "ECR URI used to push and pull the frontend image."
  value       = aws_ecr_repository.frontend.repository_url
}

output "backend_ecr_repository_url" {
  description = "ECR URI used to push and pull the backend image."
  value       = aws_ecr_repository.backend.repository_url
}

# Record the account and Region discovered from the authenticated provider
# session. These outputs are useful deployment evidence and troubleshooting
# context.
output "deployment_context" {
  description = "AWS account and Region used by this Terraform state."

  value = {
    account_id = data.aws_caller_identity.current.account_id
    region     = data.aws_region.current.region
  }
}


# Core VPC identifier used by later ALB, ECS, and security-group resources.
output "vpc_id" {
  description = "ID of the application VPC."
  value       = aws_vpc.main.id
}

# Record the Availability Zones selected dynamically for this deployment.
output "availability_zones" {
  description = "Availability Zones used by the application network."
  value       = local.selected_azs
}

# Preserve the AZ-to-subnet relationship rather than returning an unlabeled
# list. This makes later troubleshooting and routing validation clearer.
output "public_subnet_ids_by_az" {
  description = "Public subnet IDs keyed by Availability Zone."

  value = {
    for az, subnet in aws_subnet.public :
    az => subnet.id
  }
}

output "private_subnet_ids_by_az" {
  description = "Private subnet IDs keyed by Availability Zone."

  value = {
    for az, subnet in aws_subnet.private :
    az => subnet.id
  }
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the application VPC."
  value       = aws_internet_gateway.main.id
}

# Public NAT Gateway IDs keyed by Availability Zone.
#
# Retaining the AZ key makes it easy to prove that each private subnet uses
# local-AZ egress.
output "nat_gateway_ids_by_az" {
  description = "Public NAT Gateway IDs keyed by Availability Zone."

  value = {
    for az, nat in aws_nat_gateway.main :
    az => nat.id
  }
}

# Stable public IPv4 addresses assigned to the NAT Gateways.
output "nat_gateway_public_ips_by_az" {
  description = "NAT Gateway public IPv4 addresses keyed by Availability Zone."

  value = {
    for az, eip in aws_eip.nat :
    az => eip.public_ip
  }
}

# Shared route table used by both public subnets.
output "public_route_table_id" {
  description = "Route table used by the public-tier subnets."
  value       = aws_route_table.public.id
}

# Private route tables remain AZ-specific since their default routes point to
# different NAT Gateways.
output "private_route_table_ids_by_az" {
  description = "Private route table IDs keyed by Availability Zone."

  value = {
    for az, route_table in aws_route_table.private :
    az => route_table.id
  }
}

# Security-group identifiers are exposed for later ECS and ALB resources and
# make the trust-boundary configuration easy to inspect after deployment.
output "security_group_ids" {
  description = "Security groups used by the ALB and ECS application tiers."

  value = {
    alb      = aws_security_group.alb.id
    frontend = aws_security_group.frontend.id
    backend  = aws_security_group.backend.id
  }
}

# Public DNS name used to access the challenge application.
output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer."
  value       = aws_lb.application.dns_name
}

output "alb_arn" {
  description = "ARN of the public Application Load Balancer."
  value       = aws_lb.application.arn
}

# Target-group ARNs are exposed for deployment verification and can be used
# during ECS troubleshooting.
output "target_group_arns" {
  description = "Target groups used by the frontend and backend ECS services."

  value = {
    frontend = aws_lb_target_group.frontend.arn
    backend  = aws_lb_target_group.backend.arn
  }
}

output "http_listener_arn" {
  description = "ARN of the ALB HTTP listener."
  value       = aws_lb_listener.http.arn
}

# ECS identifiers are exposed so later Jenkins deployment steps do not need
# hardcoded cluster or service names.
output "ecs_cluster_name" {
  description = "Name of the ECS Fargate cluster."
  value       = aws_ecs_cluster.application.name
}

output "ecs_service_names" {
  description = "Frontend and backend ECS service names."

  value = {
    frontend = aws_ecs_service.frontend.name
    backend  = aws_ecs_service.backend.name
  }
}

output "ecs_task_definition_families" {
  description = "Task-definition family names used by the application services."

  value = {
    frontend = aws_ecs_task_definition.frontend.family
    backend  = aws_ecs_task_definition.backend.family
  }
}

output "cloudwatch_log_groups" {
  description = "CloudWatch log groups used by the ECS services."

  value = {
    frontend = aws_cloudwatch_log_group.frontend.name
    backend  = aws_cloudwatch_log_group.backend.name
  }
}

# ---------------------------------------------------------------------------
# Jenkins outputs
# ---------------------------------------------------------------------------

output "jenkins_instance_id" {
  description = "EC2 instance ID of the Jenkins CI/CD host."
  value       = aws_instance.jenkins.id
}

output "jenkins_public_ip" {
  description = "Stable public IPv4 address of the Jenkins CI/CD host."
  value       = aws_eip.jenkins.public_ip
}

output "jenkins_url" {
  description = "Public URL used to access Jenkins."
  value       = "http://${aws_eip.jenkins.public_ip}:8080"
}

output "jenkins_role_arn" {
  description = "IAM role assumed by the Jenkins EC2 host."
  value       = aws_iam_role.jenkins.arn
}

output "jenkins_ami_id" {
  description = "Amazon Linux 2023 AMI selected for the Jenkins host."
  value       = aws_instance.jenkins.ami
}