# Sequin ECS EC2 SQS Terraform Module

A comprehensive Terraform module for deploying Sequin with specialized SQS HTTP push functionality on AWS ECS with EC2 backing instances.

## Features

- **Flexible Networking**: Create new VPC/subnets or integrate with existing infrastructure
- **Database Options**: Create new RDS PostgreSQL instance or use existing database
- **Redis Options**: Create new ElastiCache Redis cluster or use existing Redis
- **SQS Integration**: Full SQS setup for HTTP push consumers with DLQ support
- **Security**: Best practices with security groups, encryption, and IAM roles
- **Monitoring**: CloudWatch logs and optional alerting integration
- **High Availability**: Multi-AZ ALB support with auto-scaling ECS cluster

## Usage

### Basic Usage (New Infrastructure)

```hcl
module "sequin" {
  source = "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0"

  # Required
  ec2_key_name = "my-keypair"
  image_tag    = "v0.9.0"

  # Optional - defaults to us-west-2
  aws_region = "us-west-2"
  availability_zones = ["us-west-2a", "us-west-2b"]
}
```

### Advanced Usage (Existing Infrastructure)

```hcl
module "sequin" {
  source = "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0"

  # Required
  ec2_key_name = "my-keypair"
  image_tag    = "v0.9.0"

  # Use existing infrastructure
  create_vpc         = false
  vpc_id             = "vpc-12345678"
  public_subnet_ids  = ["subnet-12345678", "subnet-87654321"]
  private_subnet_ids = ["subnet-11111111", "subnet-22222222"]

  # Use existing databases
  create_rds        = false
  external_pg_url   = "postgres://user:pass@rds-endpoint:5432/dbname"
  create_redis      = false
  external_redis_url = "redis://elasticache-endpoint:6379"

  # Production configuration
  ecs_instance_type = "t3.large"
  rds_instance_type = "db.m5.xlarge"

  # SSL certificate
  ssl_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"

  # Custom naming and tagging
  name_prefix = "mycompany-sequin"
  common_tags = {
    Environment = "production"
    Team        = "data-platform"
  }
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.0 |
| aws | ~> 5.0 |
| random | ~> 3.1 |

## Providers

| Name | Version |
|------|---------|
| aws | ~> 5.0 |
| random | ~> 3.1 |

## Resources Created

### Core Infrastructure
- VPC with public/private subnets (conditional)
- Application Load Balancer with SSL support
- ECS cluster with EC2 backing instances
- Auto Scaling Group for ECS instances

### Databases
- RDS PostgreSQL 17.6 with encryption (conditional)
- ElastiCache Redis 7.1 cluster (conditional)

### SQS Resources
- HTTP Push main queue
- Dead letter queue (DLQ)
- Dead-dead letter queue (final failures)
- IAM user with SQS access permissions

### Security
- Security groups with least-privilege access
- IAM roles for ECS tasks and instances
- KMS encryption for RDS
- Secrets Manager for application secrets

### Monitoring
- CloudWatch log groups
- Optional CloudWatch alarms

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws_region | AWS region for deployment | `string` | `"us-west-2"` | no |
| availability_zones | List of availability zones | `list(string)` | `["us-west-2a", "us-west-2b"]` | no |
| ec2_key_name | AWS Key Pair name for EC2 SSH access | `string` | n/a | yes |
| image_tag | Git commit SHA or Sequin version tag | `string` | n/a | yes |
| create_vpc | Whether to create a new VPC | `bool` | `true` | no |
| vpc_id | Existing VPC ID (required if create_vpc = false) | `string` | `null` | no |
| create_rds | Whether to create a new RDS instance | `bool` | `true` | no |
| external_pg_url | External PostgreSQL connection URL | `string` | `null` | no |
| create_redis | Whether to create a new ElastiCache Redis | `bool` | `true` | no |
| external_redis_url | External Redis connection URL | `string` | `null` | no |
| ssl_certificate_arn | ARN of SSL certificate for HTTPS | `string` | `""` | no |
| name_prefix | Prefix for resource names | `string` | `"sequin"` | no |

See [variables.tf](./variables.tf) for complete list of input variables.

## Outputs

| Name | Description |
|------|-------------|
| sequin_url | URL to access your Sequin application |
| admin_password | Auto-generated admin password (sensitive) |
| alb_dns_name | DNS name of the load balancer |
| ecs_cluster_name | Name of the ECS cluster |
| sequin_http_push_queue_url | URL of the HTTP Push SQS queue |

See [outputs.tf](./outputs.tf) for complete list of outputs.

## CDKTF Usage

This module can be consumed in CDKTF applications:

```typescript
import { TerraformModule } from "cdktf";

const sequin = new TerraformModule(this, "sequin", {
  source: "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0",

  // Use existing infrastructure
  create_vpc: false,
  vpc_id: existingVpc.id,
  public_subnet_ids: publicSubnets.map(s => s.id),
  private_subnet_ids: privateSubnets.map(s => s.id),

  // Required variables
  ec2_key_name: "production-key",
  image_tag: "v0.9.0",

  // Regional configuration
  aws_region: "us-west-2",
  availability_zones: ["us-west-2a", "us-west-2b"],
});

// Access outputs
const sequinUrl = sequin.getString("sequin_url");
```

## Security Considerations

1. **SSH Access**: By default, SSH is allowed from anywhere (0.0.0.0/0). Restrict `ec2_allowed_ingress_cidr_blocks` to your IP ranges.

2. **Database Security**: RDS instances are created in private subnets with encryption enabled.

3. **Secrets Management**: Application secrets are stored in AWS Secrets Manager.

4. **Network Security**: Security groups follow least-privilege principles.

## Migration from Existing Deployment

If migrating from the existing two-tier deployment:

1. **Export existing data** from RDS and Redis
2. **Update DNS** to point to new ALB
3. **Migrate secrets** to new Secrets Manager location
4. **Test thoroughly** before decommissioning old infrastructure

## Support

This module is based on the official Sequin deployment configuration. For application-specific issues, refer to the main Sequin repository.

## License

This module follows the same license as the main Sequin project.