# Example: Sequin Deployment with Existing AWS Infrastructure

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# Data sources for existing infrastructure
data "aws_vpc" "existing" {
  filter {
    name   = "tag:Name"
    values = ["my-production-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }

  filter {
    name   = "tag:Type"
    values = ["public"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }

  filter {
    name   = "tag:Type"
    values = ["private"]
  }
}

# Optional: Use existing RDS instance
data "aws_db_instance" "existing_pg" {
  db_instance_identifier = "my-production-postgres"
}

# Optional: Use existing ElastiCache cluster
data "aws_elasticache_cluster" "existing_redis" {
  cluster_id = "my-production-redis"
}

module "sequin" {
  source = "../"  # In real usage: "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0"

  # Required variables
  ec2_key_name = "production-keypair"
  image_tag    = "v0.9.0"

  # Use existing VPC and subnets
  create_vpc         = false
  vpc_id             = data.aws_vpc.existing.id
  public_subnet_ids  = data.aws_subnets.public.ids
  private_subnet_ids = data.aws_subnets.private.ids

  # Use existing databases (comment out to create new ones)
  create_rds = false
  external_pg_url = "postgres://sequin_user:${var.db_password}@${data.aws_db_instance.existing_pg.endpoint}:${data.aws_db_instance.existing_pg.port}/sequin"

  create_redis = false
  external_redis_url = "redis://${data.aws_elasticache_cluster.existing_redis.cache_nodes[0].address}:${data.aws_elasticache_cluster.existing_redis.cache_nodes[0].port}"

  # Production sizing
  ecs_instance_type = "t3.large"
  memory = 4096
  memory_reservation = 2048

  # SSL certificate for production
  ssl_certificate_arn = var.ssl_certificate_arn

  # Custom naming for production
  name_prefix = "prod-sequin"

  # Production tags
  common_tags = {
    Environment = "production"
    Team        = "data-platform"
    Project     = "sequin"
    CostCenter  = "engineering"
  }

  # Security: Restrict SSH access to office networks
  ec2_allowed_ingress_cidr_blocks = [
    "10.0.0.0/8",    # Internal networks
    "192.168.1.0/24" # Office network
  ]

  # Monitoring
  alarm_action_arn = var.sns_topic_arn

  # Skip bastion in production if using Systems Manager
  create_bastion = false
}

# Variables for sensitive data
variable "db_password" {
  description = "Password for existing database"
  type        = string
  sensitive   = true
}

variable "ssl_certificate_arn" {
  description = "ARN of SSL certificate"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic for alerts"
  type        = string
}

# Outputs
output "sequin_url" {
  description = "URL to access Sequin application"
  value       = module.sequin.sequin_url
}

output "load_balancer_dns" {
  description = "Load balancer DNS name for Route53 alias"
  value       = module.sequin.alb_dns_name
}

output "admin_credentials" {
  description = "Admin login information"
  value = {
    username = "admin"
    password = module.sequin.admin_password
  }
  sensitive = true
}