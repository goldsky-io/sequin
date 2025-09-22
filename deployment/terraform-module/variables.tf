# ==============================================================================
# CORE CONFIGURATION
# ==============================================================================

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "availability_zones" {
  description = "List of availability zones to use for resources"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones must be specified."
  }
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "sequin"
}

variable "common_tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# ==============================================================================
# NETWORKING CONFIGURATION
# ==============================================================================

variable "create_vpc" {
  description = "Whether to create a new VPC or use existing infrastructure"
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "Existing VPC ID (required if create_vpc = false)"
  type        = string
  default     = null
}

variable "vpc_cidr_block" {
  description = "CIDR block for the VPC - provides IP address range for your infrastructure"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr_block, 0))
    error_message = "VPC CIDR block must be a valid IPv4 CIDR."
  }
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs for ALB (required if create_vpc = false)"
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs for ECS/RDS (required if create_vpc = false)"
  type        = list(string)
  default     = []
}

variable "ec2_allowed_ingress_cidr_blocks" {
  description = "List of CIDR blocks allowed SSH access to bastion host. Restrict to your IP for security: ['YOUR_IP/32']"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ==============================================================================
# COMPUTE RESOURCES
# ==============================================================================

variable "ec2_key_name" {
  description = "AWS Key Pair name for EC2 SSH access. Required only if create_bastion = true. Create with: aws ec2 create-key-pair --key-name sequin-key"
  type        = string
  default     = null
}

variable "architecture" {
  description = "The CPU architecture for AMIs (x86_64 or arm64)"
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "Architecture must be either 'x86_64' or 'arm64'."
  }
}

variable "ecs_instance_type" {
  description = "EC2 instance type for ECS cluster nodes. Recommended: t3.medium for testing, t3.large+ for production"
  type        = string
  default     = "t3.medium"
}

variable "create_bastion" {
  description = "Whether to create a bastion host for SSH access"
  type        = bool
  default     = true
}

# ==============================================================================
# APPLICATION CONFIGURATION
# ==============================================================================

variable "image_tag" {
  type        = string
  description = "Git commit SHA or Sequin version tag (e.g. 'v0.9.0')"
  validation {
    condition     = can(regex("^[a-f0-9]{40}$|^v[0-9]+\\.[0-9]+\\.[0-9]+.*|^latest$", var.image_tag))
    error_message = "Must be a 40-character git commit SHA, version starting with 'v' (e.g. v0.9.0), or 'latest'."
  }
}

variable "image_repository" {
  type        = string
  description = "Container image repository URL"
  default     = "sequin/sequin"
}

variable "memory" {
  type        = number
  description = "Memory limit for the container (MB)"
  default     = 2048
}

variable "memory_reservation" {
  type        = number
  description = "Soft memory limit for the container (MB)"
  default     = 1024
}

# ==============================================================================
# DATABASE CONFIGURATION
# ==============================================================================

variable "create_rds" {
  description = "Whether to create a new RDS PostgreSQL instance"
  type        = bool
  default     = true
}

variable "external_pg_url" {
  description = "External PostgreSQL connection URL (required if create_rds = false)"
  type        = string
  default     = null
  sensitive   = true
}

variable "db_name" {
  description = "Name of the PostgreSQL database to create"
  type        = string
  default     = "sequin_prod"
}

variable "rds_instance_type" {
  description = "RDS instance class. Recommended: db.t4g.micro is fine for testing, db.m5.large is OK for lighter prod workloads. db.m5.xlarge+ recommended for heavy workloads"
  type        = string
  default     = "db.m5.large"
}

variable "rds_allocated_storage" {
  description = "Initial allocated storage for RDS in GB. Will auto-scale up to max_allocated_storage"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "Maximum storage for RDS auto-scaling in GB"
  type        = number
  default     = 100
}

# ==============================================================================
# REDIS CONFIGURATION
# ==============================================================================

variable "create_redis" {
  description = "Whether to create a new ElastiCache Redis instance"
  type        = bool
  default     = true
}

variable "external_redis_url" {
  description = "External Redis connection URL (required if create_redis = false)"
  type        = string
  default     = null
  sensitive   = true
}

variable "redis_instance_type" {
  description = "ElastiCache Redis node type. Recommended: cache.t4g.micro for testing, cache.t4g.small+ for production"
  type        = string
  default     = "cache.t4g.micro"
}

# ==============================================================================
# SSL CERTIFICATE (OPTIONAL)
# ==============================================================================

variable "ssl_certificate_arn" {
  description = "ARN of SSL certificate for HTTPS load balancer. Leave empty to skip HTTPS (HTTP only)"
  type        = string
  default     = ""
}

# ==============================================================================
# MONITORING & ALERTING (OPTIONAL)
# ==============================================================================

variable "alarm_action_arn" {
  description = "ARN of SNS topic for CloudWatch alarms. Leave empty to disable alerts"
  type        = string
  default     = ""
}