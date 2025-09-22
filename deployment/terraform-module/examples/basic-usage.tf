# Example: Basic Sequin Deployment with New Infrastructure

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

module "sequin" {
  source = "../"  # In real usage: "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0"

  # Required variables
  ec2_key_name = "my-keypair"  # Replace with your key pair name
  image_tag    = "v0.9.0"      # Replace with desired Sequin version

  # Regional configuration
  aws_region = "us-west-2"
  availability_zones = ["us-west-2a", "us-west-2b"]

  # Optional: Custom naming
  name_prefix = "my-sequin"

  # Optional: Custom tags
  common_tags = {
    Environment = "development"
    Project     = "sequin-evaluation"
    Owner       = "data-team"
  }

  # Optional: Instance sizing (defaults shown)
  ecs_instance_type = "t3.medium"
  rds_instance_type = "db.m5.large"
  redis_instance_type = "cache.t4g.micro"

  # Optional: Application configuration
  memory = 2048
  memory_reservation = 1024
  image_repository = "sequin/sequin"

  # Optional: Disable bastion host if not needed
  create_bastion = true

  # Optional: SSL certificate for HTTPS
  # ssl_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
}

# Outputs
output "sequin_url" {
  description = "URL to access Sequin application"
  value       = module.sequin.sequin_url
}

output "admin_password" {
  description = "Admin password for Sequin (sensitive)"
  value       = module.sequin.admin_password
  sensitive   = true
}

output "bastion_ip" {
  description = "Public IP of bastion host for SSH access"
  value       = module.sequin.bastion_public_ip
}

output "sqs_queue_url" {
  description = "HTTP Push SQS queue URL"
  value       = module.sequin.sequin_http_push_queue_url
}