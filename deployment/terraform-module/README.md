# Sequin ECS EC2 SQS Terraform Module

A comprehensive Terraform module for deploying Sequin with specialized SQS HTTP push functionality on AWS ECS with EC2 backing instances.

## Features

- **Flexible Networking**: Create new VPC/subnets or integrate with existing infrastructure
- **Database Options**: Create new RDS PostgreSQL instance or use existing database
- **RDS Proxy**: Automatic RDS Proxy provisioning with RDS for improved connection pooling and resilience
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
  image_tag = "v0.9.0"

  # Optional - defaults to us-west-2
  aws_region = "us-west-2"
  availability_zones = ["us-west-2a", "us-west-2b"]

   # Optional - only needed if you want a bastion host
   create_bastion = false  # Skip bastion if you have existing access
   # ec2_key_name = "my-keypair"  # Required only if create_bastion = true

   # Optional - custom environment variables
   additional_environment_variables = {
     SEQUIN_METRICS_USER     = "metrics-user"
     SEQUIN_METRICS_PASSWORD = "secure-password"
   }
 }
```

### Advanced Usage (Existing Infrastructure)

```hcl
module "sequin" {
  source = "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0"

  # Required
  image_tag = "v0.9.0"

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

### RDS Proxy (Always Enabled with RDS)

When creating an RDS instance, this module automatically provisions an RDS Proxy for improved connection pooling, automatic failover, and reduced database load. RDS Proxy handles connection multiplexing, allowing thousands of application connections while maintaining fewer database connections.

```hcl
module "sequin" {
  source = "git::https://github.com/goldsky/sequin.git//deployment/terraform-module?ref=v1.0.0"

  # Required
  image_tag = "v0.9.0"

  # RDS Proxy connection pool settings (optional)
  rds_proxy_max_connections_percent      = 90  # Max 90% of available connections
  rds_proxy_max_idle_connections_percent = 25  # Max 25% idle connections

  # Can reduce PG_POOL_SIZE when using proxy (proxy handles multiplexing)
  pg_pool_size = 50

  # Other configuration...
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
| ec2_key_name | AWS Key Pair name for EC2 SSH access (required only if create_bastion = true) | `string` | `null` | no |
| image_tag | Git commit SHA or Sequin version tag | `string` | n/a | yes |
| create_vpc | Whether to create a new VPC | `bool` | `true` | no |
| vpc_id | Existing VPC ID (required if create_vpc = false) | `string` | `null` | no |
| create_rds | Whether to create a new RDS instance | `bool` | `true` | no |
| external_pg_url | External PostgreSQL connection URL | `string` | `null` | no |
| rds_proxy_max_connections_percent | Maximum connections percent for RDS Proxy (1-100). RDS Proxy is automatically created when RDS is enabled. | `number` | `100` | no |
| rds_proxy_max_idle_connections_percent | Maximum idle connections percent for RDS Proxy (0-100). RDS Proxy is automatically created when RDS is enabled. | `number` | `50` | no |
| create_redis | Whether to create a new ElastiCache Redis | `bool` | `true` | no |
| external_redis_url | External Redis connection URL | `string` | `null` | no |
| enable_deletion_protection | Enable deletion protection for RDS and KMS resources | `bool` | `true` | no |
| skip_final_snapshot | Skip final RDS snapshot when destroying | `bool` | `false` | no |
| final_snapshot_identifier | Name of final RDS snapshot (auto-generated if not provided) | `string` | `null` | no |
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

## RDS Proxy Considerations

RDS Proxy provides several benefits but adds complexity and cost:

### Benefits
- **Connection Multiplexing**: Handles thousands of application connections with fewer database connections
- **Improved Resilience**: Automatic failover and connection management during database maintenance
- **Reduced Database Load**: Fewer idle connections on the database instance
- **Better Monitoring**: Enhanced connection metrics and monitoring

### Trade-offs
- **Additional Cost**: ~$0.015/hour per proxy plus data transfer costs
- **Minor Latency**: ~1-5ms additional latency per connection
- **Complexity**: Additional infrastructure component to manage

### When to Use RDS Proxy
- Multiple Sequin instances connecting to the same database
- Experiencing connection pool exhaustion
- High-frequency database operations
- Need for automatic failover during maintenance

### Configuration Tips
- Reduce `pg_pool_size` when using proxy (50-100 instead of 200) since proxy handles multiplexing
- Monitor proxy metrics in CloudWatch for connection usage
- Consider proxy for production deployments with multiple application instances

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