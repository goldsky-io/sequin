# ==============================================================================
# CORE INFRASTRUCTURE OUTPUTS
# ==============================================================================

output "sequin_url" {
  description = "URL to access your Sequin application"
  value       = "http://${aws_lb.sequin-main.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the load balancer - use this to access your Sequin application"
  value       = aws_lb.sequin-main.dns_name
}

output "vpc_id" {
  description = "ID of the VPC (created or existing)"
  value       = local.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = local.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = local.private_subnet_ids
}

# ==============================================================================
# ECS CLUSTER OUTPUTS
# ==============================================================================

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.sequin.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.sequin.arn
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.sequin-main.name
}

output "ecs_task_definition_arn" {
  description = "ARN of the ECS task definition"
  value       = aws_ecs_task_definition.sequin-main.arn
}

# ==============================================================================
# LOAD BALANCER OUTPUTS
# ==============================================================================

output "target_group_arn" {
  description = "ARN of the load balancer target group"
  value       = aws_lb_target_group.sequin-main.arn
}

output "load_balancer_arn" {
  description = "ARN of the application load balancer"
  value       = aws_lb.sequin-main.arn
}

output "load_balancer_zone_id" {
  description = "Zone ID of the load balancer for Route53 alias records"
  value       = aws_lb.sequin-main.zone_id
}

# ==============================================================================
# SECURITY GROUP OUTPUTS
# ==============================================================================

output "ecs_security_group_id" {
  description = "ID of the ECS security group"
  value       = aws_security_group.sequin-ecs-sg.id
}

output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.sequin-alb-sg.id
}

output "bastion_security_group_id" {
  description = "ID of the bastion security group (if created)"
  value       = var.create_bastion ? aws_security_group.sequin-bastion-sg[0].id : null
}

# ==============================================================================
# IAM ROLE OUTPUTS
# ==============================================================================

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = aws_iam_role.sequin-ecs-task-execution-role.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role"
  value       = aws_iam_role.sequin-ecs-task-role.arn
}

output "ecs_instance_role_arn" {
  description = "ARN of the ECS instance role"
  value       = aws_iam_role.sequin-ecs-instance-role.arn
}

# ==============================================================================
# DATABASE OUTPUTS (CONDITIONAL)
# ==============================================================================

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (if created)"
  value       = var.create_rds ? aws_db_instance.sequin-database[0].endpoint : null
}

output "rds_port" {
  description = "RDS PostgreSQL port (if created)"
  value       = var.create_rds ? aws_db_instance.sequin-database[0].port : null
}

output "rds_database_name" {
  description = "RDS database name (if created)"
  value       = var.create_rds ? aws_db_instance.sequin-database[0].db_name : null
}

output "sequin_pg_url" {
  description = "PostgreSQL URL for Sequin configuration"
  value       = local.pg_url
  sensitive   = true
}

# ==============================================================================
# REDIS OUTPUTS (CONDITIONAL)
# ==============================================================================

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint (if created)"
  value       = var.create_redis ? aws_elasticache_cluster.sequin-main[0].cache_nodes[0].address : null
}

output "redis_port" {
  description = "ElastiCache Redis port (if created)"
  value       = var.create_redis ? aws_elasticache_cluster.sequin-main[0].cache_nodes[0].port : null
}

output "sequin_redis_url" {
  description = "Redis URL for Sequin configuration"
  value       = local.redis_url
  sensitive   = true
}

# ==============================================================================
# SQS OUTPUTS
# ==============================================================================

output "sequin_http_push_queue_url" {
  description = "URL of the HTTP Push SQS queue"
  value       = aws_sqs_queue.sequin_http_push_queue.url
}

output "sequin_http_push_queue_arn" {
  description = "ARN of the HTTP Push SQS queue"
  value       = aws_sqs_queue.sequin_http_push_queue.arn
}

output "sequin_http_push_dlq_url" {
  description = "URL of the HTTP Push DLQ"
  value       = aws_sqs_queue.sequin_http_push_dlq.url
}

output "sequin_http_push_dlq_arn" {
  description = "ARN of the HTTP Push DLQ"
  value       = aws_sqs_queue.sequin_http_push_dlq.arn
}

output "sequin_http_push_dead_dlq_url" {
  description = "URL of the HTTP Push Dead DLQ"
  value       = aws_sqs_queue.sequin_http_push_dead_dlq.url
}

output "sequin_http_push_dead_dlq_arn" {
  description = "ARN of the HTTP Push Dead DLQ"
  value       = aws_sqs_queue.sequin_http_push_dead_dlq.arn
}

output "sequin_http_push_sqs_user_access_key" {
  description = "Access key ID for the SQS user"
  value       = aws_iam_access_key.sequin_http_push_sqs_user_key.id
}

output "sequin_http_push_sqs_user_secret_key" {
  description = "Secret access key for the SQS user"
  value       = aws_iam_access_key.sequin_http_push_sqs_user_key.secret
  sensitive   = true
}

# ==============================================================================
# APPLICATION OUTPUTS
# ==============================================================================

output "admin_password" {
  description = "Auto-generated admin password for Sequin"
  value       = random_password.admin_password.result
  sensitive   = true
}

output "secrets_manager_secret_arn" {
  description = "ARN of the Secrets Manager secret containing Sequin configuration"
  value       = aws_secretsmanager_secret.sequin-config.arn
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group for ECS logs"
  value       = aws_cloudwatch_log_group.sequin.name
}

# ==============================================================================
# EC2 OUTPUTS (CONDITIONAL)
# ==============================================================================

output "bastion_public_ip" {
  description = "Public IP of the bastion host (if created)"
  value       = var.create_bastion ? aws_instance.sequin-bastion[0].public_ip : null
}

output "bastion_instance_id" {
  description = "Instance ID of the bastion host (if created)"
  value       = var.create_bastion ? aws_instance.sequin-bastion[0].id : null
}

output "autoscaling_group_name" {
  description = "Name of the ECS autoscaling group"
  value       = aws_autoscaling_group.sequin-main.name
}

output "launch_template_id" {
  description = "ID of the ECS launch template"
  value       = aws_launch_template.sequin-main.id
}