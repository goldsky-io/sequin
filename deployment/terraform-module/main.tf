# ==============================================================================
# DATA SOURCES
# ==============================================================================

# ECS-optimized Amazon Linux 2023 AMI (latest/recommended)
data "aws_ssm_parameter" "sequin-ami-ecs" {
  name = var.architecture == "x86_64" ? "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id" : "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

# Standard Amazon Linux 2023 AMI (latest)
data "aws_ssm_parameter" "sequin-ami-standard" {
  name = var.architecture == "x86_64" ? "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" : "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_caller_identity" "current" {}

# Data sources for existing VPC/subnets when create_vpc = false
data "aws_vpc" "existing" {
  count = var.create_vpc ? 0 : 1
  id    = var.vpc_id
}

data "aws_subnets" "existing_public" {
  count = var.create_vpc ? 0 : 1
  filter {
    name   = "subnet-id"
    values = var.public_subnet_ids
  }
}

data "aws_subnets" "existing_private" {
  count = var.create_vpc ? 0 : 1
  filter {
    name   = "subnet-id"
    values = var.private_subnet_ids
  }
}

# ==============================================================================
# LOCAL VALUES
# ==============================================================================

locals {
  # Auto-generate ARNs using account ID
  autoscaling_service_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"

  # Standard AWS role names
  ecs_instance_profile_name = "${var.name_prefix}-ecsInstanceRole"

  # VPC and subnet references - use created or existing
  vpc_id = var.create_vpc ? aws_vpc.sequin-main[0].id : var.vpc_id

  public_subnet_ids = var.create_vpc ? [
    aws_subnet.sequin-public-primary[0].id,
    aws_subnet.sequin-public-secondary[0].id
  ] : var.public_subnet_ids

  private_subnet_ids = var.create_vpc ? [
    aws_subnet.sequin-private-primary[0].id,
    aws_subnet.sequin-private-secondary[0].id
  ] : var.private_subnet_ids

  # Primary subnets for single-AZ resources
  primary_public_subnet_id  = local.public_subnet_ids[0]
  primary_private_subnet_id = local.private_subnet_ids[0]

  # Database and Redis URLs - use external or created
  pg_url = var.create_rds ? (
    "postgres://postgres:${random_password.db_password[0].result}@${aws_db_proxy.sequin_proxy[0].endpoint}/${var.db_name}"
  ) : var.external_pg_url

  redis_url = var.create_redis ? (
    "redis://${aws_elasticache_cluster.sequin-main[0].cache_nodes[0].address}:6379"
  ) : var.external_redis_url

  # ECS task secrets
  ecs_task_secrets = [
    {
      name      = "SECRET_KEY_BASE"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:SECRET_KEY_BASE::"
    },
    {
      name      = "ADMIN_PASSWORD"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:ADMIN_PASSWORD::"
    },
    {
      name      = "VAULT_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:VAULT_KEY::"
    },
    {
      name      = "PG_URL"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:PG_URL::"
    },
    {
      name      = "REDIS_URL"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:REDIS_URL::"
    },
    {
      name      = "GITHUB_CLIENT_ID"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:GITHUB_CLIENT_ID::"
    },
    {
      name      = "GITHUB_CLIENT_SECRET"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:GITHUB_CLIENT_SECRET::"
    },
    {
      name      = "SENDGRID_API_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:SENDGRID_API_KEY::"
    },
    {
      name      = "RETOOL_WORKFLOW_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:RETOOL_WORKFLOW_KEY::"
    },
    {
      name      = "LOOPS_API_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:LOOPS_API_KEY::"
    },
    {
      name      = "DATADOG_API_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:DATADOG_API_KEY::"
    },
    {
      name      = "DATADOG_APP_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:DATADOG_APP_KEY::"
    },
    {
      name      = "SENTRY_DSN"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:SENTRY_DSN::"
    },
    {
      name      = "PAGERDUTY_INTEGRATION_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:PAGERDUTY_INTEGRATION_KEY::"
    },
    {
      name      = "HTTP_PUSH_VIA_SQS_ACCESS_KEY_ID"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:HTTP_PUSH_VIA_SQS_ACCESS_KEY_ID::"
    },
    {
      name      = "HTTP_PUSH_VIA_SQS_SECRET_ACCESS_KEY"
      valueFrom = "${aws_secretsmanager_secret.sequin-config.arn}:HTTP_PUSH_VIA_SQS_SECRET_ACCESS_KEY::"
    }
  ]

  # Validation: Ensure ec2_key_name is provided when bastion is enabled
  validate_key_name = var.create_bastion && var.ec2_key_name == null ? tobool("ec2_key_name is required when create_bastion = true") : true

  # Common tags
  common_tags = merge(var.common_tags, {
    Module = "sequin-ecs-sqs"
  })

  # ECS env defaults and merged map for stable, de-duped env list
  ecs_env_defaults = {
    CURRENT_GIT_SHA              = var.image_tag
    PG_SSL                       = "true"
    LAUNCH_TYPE                  = "EC2"
    ADMIN_USER                   = "admin"
    RELEASE_DISTRIBUTION         = "name"
    RELEASE_NODE                 = var.name_prefix
    SERVER_PORT                  = "7376"
    SERVER_HOST                  = aws_lb.sequin-main.dns_name
    API_HOST                     = aws_lb.sequin-main.dns_name
    FEATURE_ACCOUNT_SELF_SIGNUP  = "false"
    PG_POOL_SIZE                 = tostring(var.pg_pool_size)
    GITHUB_CLIENT_REDIRECT_URI   = ""
    HTTP_PUSH_VIA_SQS_NEW_SINKS  = "true"
    HTTP_PUSH_VIA_SQS_QUEUE_URL  = aws_sqs_queue.sequin_http_push_queue.url
    HTTP_PUSH_VIA_SQS_DLQ_URL    = aws_sqs_queue.sequin_http_push_dlq.url
    HTTP_PUSH_VIA_SQS_REGION     = var.aws_region
  }

  ecs_env_map = merge(local.ecs_env_defaults, var.additional_environment_variables)
}

# ==============================================================================
# VPC AND NETWORKING (CONDITIONAL)
# ==============================================================================

resource "aws_vpc" "sequin-main" {
  count = var.create_vpc ? 1 : 0

  cidr_block                       = var.vpc_cidr_block
  enable_dns_hostnames             = true
  enable_dns_support               = true
  assign_generated_ipv6_cidr_block = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-vpc"
  })
}

resource "aws_subnet" "sequin-public-primary" {
  count = var.create_vpc ? 1 : 0

  vpc_id                          = aws_vpc.sequin-main[0].id
  cidr_block                      = cidrsubnet(aws_vpc.sequin-main[0].cidr_block, 8, 1)
  availability_zone               = var.availability_zones[0]
  map_public_ip_on_launch         = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.sequin-main[0].ipv6_cidr_block, 8, 1)
  assign_ipv6_address_on_creation = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-${var.availability_zones[0]}"
  })
}

resource "aws_subnet" "sequin-public-secondary" {
  count = var.create_vpc ? 1 : 0

  vpc_id                          = aws_vpc.sequin-main[0].id
  cidr_block                      = cidrsubnet(aws_vpc.sequin-main[0].cidr_block, 8, 2)
  availability_zone               = var.availability_zones[1]
  map_public_ip_on_launch         = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.sequin-main[0].ipv6_cidr_block, 8, 2)
  assign_ipv6_address_on_creation = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-${var.availability_zones[1]}"
  })
}

resource "aws_subnet" "sequin-private-primary" {
  count = var.create_vpc ? 1 : 0

  vpc_id                          = aws_vpc.sequin-main[0].id
  cidr_block                      = cidrsubnet(aws_vpc.sequin-main[0].cidr_block, 8, 3)
  availability_zone               = var.availability_zones[0]
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.sequin-main[0].ipv6_cidr_block, 8, 3)
  assign_ipv6_address_on_creation = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-private-${var.availability_zones[0]}"
  })
}

resource "aws_subnet" "sequin-private-secondary" {
  count = var.create_vpc ? 1 : 0

  vpc_id                          = aws_vpc.sequin-main[0].id
  cidr_block                      = cidrsubnet(aws_vpc.sequin-main[0].cidr_block, 8, 4)
  availability_zone               = var.availability_zones[1]
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.sequin-main[0].ipv6_cidr_block, 8, 4)
  assign_ipv6_address_on_creation = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-private-${var.availability_zones[1]}"
  })
}

resource "aws_internet_gateway" "sequin-main" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.sequin-main[0].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-igw"
  })
}

# Elastic IP for NAT Gateway
resource "aws_eip" "sequin-nat" {
  count = var.create_vpc ? 1 : 0

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-nat-eip"
  })

  depends_on = [aws_internet_gateway.sequin-main[0]]
}

# NAT Gateway for private subnet internet access
resource "aws_nat_gateway" "sequin-main" {
  count = var.create_vpc ? 1 : 0

  allocation_id = aws_eip.sequin-nat[0].id
  subnet_id     = aws_subnet.sequin-public-primary[0].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-nat"
  })

  depends_on = [aws_internet_gateway.sequin-main[0]]
}

resource "aws_route_table" "sequin-public" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.sequin-main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sequin-main[0].id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.sequin-main[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "sequin-public-primary" {
  count = var.create_vpc ? 1 : 0

  subnet_id      = aws_subnet.sequin-public-primary[0].id
  route_table_id = aws_route_table.sequin-public[0].id
}

resource "aws_route_table_association" "sequin-public-secondary" {
  count = var.create_vpc ? 1 : 0

  subnet_id      = aws_subnet.sequin-public-secondary[0].id
  route_table_id = aws_route_table.sequin-public[0].id
}

resource "aws_route_table" "sequin-private" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.sequin-main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.sequin-main[0].id
  }

  route {
    ipv6_cidr_block        = "::/0"
    egress_only_gateway_id = aws_egress_only_internet_gateway.sequin-main[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-private-rt"
  })
}

resource "aws_route_table_association" "sequin-private-primary" {
  count = var.create_vpc ? 1 : 0

  subnet_id      = aws_subnet.sequin-private-primary[0].id
  route_table_id = aws_route_table.sequin-private[0].id
}

resource "aws_route_table_association" "sequin-private-secondary" {
  count = var.create_vpc ? 1 : 0

  subnet_id      = aws_subnet.sequin-private-secondary[0].id
  route_table_id = aws_route_table.sequin-private[0].id
}

resource "aws_egress_only_internet_gateway" "sequin-main" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.sequin-main[0].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-eigw"
  })
}

# ==============================================================================
# SECURITY GROUPS
# ==============================================================================

resource "aws_security_group" "sequin-ecs-sg" {
  description = "ECS Allowed Ports"
  name        = "${var.name_prefix}-ecs-sg"
  vpc_id      = local.vpc_id

  egress {
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    from_port        = "0"
    protocol         = "-1"
    self             = "false"
    to_port          = "0"
  }

  ingress {
    from_port   = "22"
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    self        = "false"
    to_port     = "22"
  }

  ingress {
    description     = "Allow inbound traffic from ALB"
    from_port       = 7376
    to_port         = 7376
    protocol        = "tcp"
    security_groups = [aws_security_group.sequin-alb-sg.id]
  }

  ingress {
    description     = "Allow inbound traffic from ALB for metrics"
    from_port       = 8376
    to_port         = 8376
    protocol        = "tcp"
    security_groups = [aws_security_group.sequin-alb-sg.id]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-ecs-sg"
  })
}

resource "aws_security_group" "sequin-alb-sg" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Security group for Sequin ALB"
  vpc_id      = local.vpc_id

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port        = 8376
    to_port          = 8376
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-alb-sg"
  })
}

resource "aws_security_group" "sequin-bastion-sg" {
  count = var.create_bastion ? 1 : 0

  name        = "${var.name_prefix}-bastion-sg"
  description = "Security group for Sequin bastion host"
  vpc_id      = local.vpc_id

  ingress {
    cidr_blocks = var.ec2_allowed_ingress_cidr_blocks
    description = "default allowed ingress to ec2 & bastion"
    from_port   = "22"
    protocol    = "tcp"
    self        = "false"
    to_port     = "22"
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-bastion-sg"
  })
}

resource "aws_security_group" "sequin-rds-sg" {
  count = var.create_rds ? 1 : 0

  name        = "${var.name_prefix}-rds-sg"
  description = "Security group for Sequin RDS"
  vpc_id      = local.vpc_id

  ingress {
    from_port = 0
    to_port   = 5432
    protocol  = "tcp"
    security_groups = compact([
      aws_security_group.sequin-ecs-sg.id,
      var.create_bastion ? aws_security_group.sequin-bastion-sg[0].id : null,
      aws_security_group.sequin_rds_proxy_sg[0].id
    ])
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds-sg"
  })
}

resource "aws_security_group" "sequin-redis-sg" {
  count = var.create_redis ? 1 : 0

  description = "Security group for redis"
  name        = "${var.name_prefix}-redis-sg"
  vpc_id      = local.vpc_id

  egress {
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    from_port        = "0"
    protocol         = "-1"
    self             = "false"
    to_port          = "0"
  }

  ingress {
    from_port = "0"
    protocol  = "-1"
    security_groups = compact([
      aws_security_group.sequin-ecs-sg.id,
      var.create_bastion ? aws_security_group.sequin-bastion-sg[0].id : null
    ])
    self    = true
    to_port = "0"
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis-sg"
  })
}

# ==============================================================================
# IAM ROLES AND POLICIES
# ==============================================================================

# ECS Task Execution Role (for pulling images, logs, etc.)
resource "aws_iam_role" "sequin-ecs-task-execution-role" {
  name = "${var.name_prefix}-ecs-task-execution-role"

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

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "sequin-ecs-task-execution-role-policy" {
  role       = aws_iam_role.sequin-ecs-task-execution-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "sequin-ecs-task-execution-secrets-policy" {
  name = "${var.name_prefix}-ecs-task-execution-secrets-policy"
  role = aws_iam_role.sequin-ecs-task-execution-role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          "arn:aws:secretsmanager:*:*:secret:${var.name_prefix}/*"
        ]
      }
    ]
  })
}

# ECS Task Role (for application permissions)
resource "aws_iam_role" "sequin-ecs-task-role" {
  name = "${var.name_prefix}-ecs-task-role"

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

  tags = local.common_tags
}

# ECS Instance Role (for EC2 instances in cluster)
resource "aws_iam_role" "sequin-ecs-instance-role" {
  name = local.ecs_instance_profile_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "sequin-ecs-instance-role-policy" {
  role       = aws_iam_role.sequin-ecs-instance-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "sequin-ecs-instance-profile" {
  name = local.ecs_instance_profile_name
  role = aws_iam_role.sequin-ecs-instance-role.name

  tags = local.common_tags
}

# RDS Monitoring Role
resource "aws_iam_role" "sequin-rds-monitoring-role" {
  count = var.create_rds ? 1 : 0

  name = "${var.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "sequin-rds-monitoring-role-policy" {
  count = var.create_rds ? 1 : 0

  role       = aws_iam_role.sequin-rds-monitoring-role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ==============================================================================
# SQS RESOURCES
# ==============================================================================

# Create a dead-dead letter queue for messages that fail too many times in the DLQ
resource "aws_sqs_queue" "sequin_http_push_dead_dlq" {
  name                      = "${var.name_prefix}-http-push-dead-dlq"
  message_retention_seconds = 604800 # 7 days retention

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-http-push-dead-dlq"
    Purpose = "HTTP Push Final Dead Letter Queue"
  })
}

# Create a dead letter queue for failed messages
resource "aws_sqs_queue" "sequin_http_push_dlq" {
  name                      = "${var.name_prefix}-http-push-dlq"
  message_retention_seconds = 1209600 # 14 days (maximum retention)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sequin_http_push_dead_dlq.arn
    maxReceiveCount     = 50
  })

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-http-push-dlq"
    Purpose = "HTTP Push Consumer DLQ"
  })
}

# Create the main HTTP Push queue
resource "aws_sqs_queue" "sequin_http_push_queue" {
  name                       = "${var.name_prefix}-http-push-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 1209600 # 14 days (maximum retention)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sequin_http_push_dlq.arn
    maxReceiveCount     = 1
  })

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-http-push-queue"
    Purpose = "HTTP Push Consumer"
  })
}

# Create IAM user for application to read from and write to the queue
resource "aws_iam_user" "sequin_http_push_sqs_user" {
  name = "${var.name_prefix}-http-push-sqs-user"

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-http-push-sqs-user"
    Purpose = "HTTP Push Queue Access"
  })
}

# Create access keys for the SQS user
resource "aws_iam_access_key" "sequin_http_push_sqs_user_key" {
  user = aws_iam_user.sequin_http_push_sqs_user.name
}

# Create policy for both reading from and writing to the SQS queue
resource "aws_iam_policy" "sequin_sqs_access_policy" {
  name        = "${var.name_prefix}-http-push-sqs-access-policy"
  description = "Policy for read/write access to the HTTP Push SQS queue"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          # Send operations
          "sqs:SendMessage",
          "sqs:SendMessageBatch",

          # Receive operations
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:DeleteMessageBatch",
          "sqs:ChangeMessageVisibility",
          "sqs:ChangeMessageVisibilityBatch",

          # Queue management operations
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
          "sqs:ListQueues",
          "sqs:ListQueueTags",
        ]
        Resource = [
          aws_sqs_queue.sequin_http_push_queue.arn,
          aws_sqs_queue.sequin_http_push_dlq.arn,
          aws_sqs_queue.sequin_http_push_dead_dlq.arn
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-http-push-sqs-access-policy"
  })
}

# Attach the policy to the SQS user
resource "aws_iam_user_policy_attachment" "sequin_http_push_sqs_user_attachment" {
  user       = aws_iam_user.sequin_http_push_sqs_user.name
  policy_arn = aws_iam_policy.sequin_sqs_access_policy.arn
}

# ==============================================================================
# APPLICATION LOAD BALANCER
# ==============================================================================

resource "aws_lb" "sequin-main" {
  enable_http2       = "true"
  name               = "${var.name_prefix}-main-lb"
  idle_timeout       = "60"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sequin-alb-sg.id]
  subnets            = local.public_subnet_ids

  ip_address_type = "ipv4"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-lb"
  })
}

resource "aws_lb_listener" "sequin-main-80" {
  load_balancer_arn = aws_lb.sequin-main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = var.ssl_certificate_arn != "" ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.ssl_certificate_arn != "" ? [1] : []
      content {
        host        = "#{host}"
        path        = "/#{path}"
        port        = "443"
        protocol    = "HTTPS"
        query       = "#{query}"
        status_code = "HTTP_301"
      }
    }

    target_group_arn = var.ssl_certificate_arn == "" ? aws_lb_target_group.sequin-main.arn : null
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "sequin-main-443" {
  count = var.ssl_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.sequin-main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.ssl_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sequin-main.arn
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "sequin-metrics-8376" {
  load_balancer_arn = aws_lb.sequin-main.arn
  port              = "8376"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sequin-metrics.arn
  }

  tags = local.common_tags
}

resource "aws_lb_target_group" "sequin-main" {
  name                 = "${var.name_prefix}-main-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = local.vpc_id
  deregistration_delay = 60

  health_check {
    enabled             = "true"
    healthy_threshold   = "2"
    interval            = "30"
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = "5"
    unhealthy_threshold = "5"
  }

  target_type     = "ip"
  ip_address_type = "ipv4"

  stickiness {
    cookie_duration = "86400"
    enabled         = "false"
    type            = "lb_cookie"
  }

  load_balancing_algorithm_type     = "round_robin"
  load_balancing_cross_zone_enabled = "use_load_balancer_configuration"
  protocol_version                  = "HTTP1"
  slow_start                        = "0"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-tg"
  })
}

resource "aws_lb_target_group" "sequin-metrics" {
  name                 = "${var.name_prefix}-metrics-tg"
  port                 = 8376
  protocol             = "HTTP"
  vpc_id               = local.vpc_id
  deregistration_delay = 60

  health_check {
    enabled             = "true"
    healthy_threshold   = "2"
    interval            = "30"
    matcher             = "200"
    path                = "/health"
    port                = "7376"
    protocol            = "HTTP"
    timeout             = "5"
    unhealthy_threshold = "5"
  }

  target_type     = "ip"
  ip_address_type = "ipv4"

  stickiness {
    cookie_duration = "86400"
    enabled         = "false"
    type            = "lb_cookie"
  }

  load_balancing_algorithm_type     = "round_robin"
  load_balancing_cross_zone_enabled = "use_load_balancer_configuration"
  protocol_version                  = "HTTP1"
  slow_start                        = "0"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-metrics-tg"
  })
}

# ==============================================================================
# ECS CLUSTER
# ==============================================================================

resource "aws_ecs_cluster" "sequin" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }

  tags = local.common_tags
}

# ==============================================================================
# RDS POSTGRESQL DATABASE (CONDITIONAL)
# ==============================================================================

# Generate secure password for PostgreSQL database
resource "random_password" "db_password" {
  count = var.create_rds ? 1 : 0

  length  = 16
  special = true
  # Exclude characters that break PostgreSQL connection URLs
  override_special = "!#$%&*()-_=+[]{}<>?."
}

resource "aws_db_parameter_group" "sequin-database-pg-17" {
  count = var.create_rds ? 1 : 0

  description = "For ${var.name_prefix} database"
  family      = "postgres17"
  name        = "${var.name_prefix}-params-pg17"

  parameter {
    apply_method = "pending-reboot"
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pg_cron"
  }

  parameter {
    apply_method = "immediate"
    name         = "max_slot_wal_keep_size"
    value        = "4096"
  }
  parameter {
    apply_method = "pending-reboot"
    name         = "rds.logical_replication"
    value        = "1"
  }

  tags = local.common_tags
}

resource "aws_db_subnet_group" "sequin-default-group" {
  count = var.create_rds ? 1 : 0

  name       = "${var.name_prefix}-default-rds-subnet-group"
  subnet_ids = local.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix} single AZ RDS subnet group"
  })
}

resource "aws_kms_key" "sequin-rds-encryption-key" {
  count = var.create_rds ? 1 : 0

  description             = "KMS key for ${var.name_prefix} RDS encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_db_instance" "sequin-database" {
  count = var.create_rds ? 1 : 0

  allocated_storage                     = var.rds_allocated_storage
  auto_minor_version_upgrade            = "true"
  availability_zone                     = var.availability_zones[0]
  backup_retention_period               = "7"
  backup_window                         = "11:43-12:13"
  db_name                               = var.db_name
  ca_cert_identifier                    = "rds-ca-rsa2048-g1"
  copy_tags_to_snapshot                 = "true"
  customer_owned_ip_enabled             = "false"
  db_subnet_group_name                  = aws_db_subnet_group.sequin-default-group[0].name
  deletion_protection                   = var.enable_deletion_protection
  engine                                = "postgres"
  engine_version                        = "17.6"
  iam_database_authentication_enabled   = "false"
  identifier                            = "${var.name_prefix}-database"
  instance_class                        = var.rds_instance_type
  maintenance_window                    = "thu:11:11-thu:11:41"
  max_allocated_storage                 = var.rds_max_allocated_storage
  monitoring_interval                   = "60"
  monitoring_role_arn                   = aws_iam_role.sequin-rds-monitoring-role[0].arn
  multi_az                              = "false"
  network_type                          = "IPV4"
  parameter_group_name                  = aws_db_parameter_group.sequin-database-pg-17[0].name
  performance_insights_enabled          = "true"
  performance_insights_kms_key_id       = aws_kms_key.sequin-rds-encryption-key[0].arn
  performance_insights_retention_period = "7"
  port                                  = "5432"
  publicly_accessible                   = "false"
  storage_encrypted                     = "true"
  kms_key_id                            = aws_kms_key.sequin-rds-encryption-key[0].arn
  storage_type                          = "gp3"
  username                              = "postgres"
  vpc_security_group_ids                = concat([aws_security_group.sequin-rds-sg[0].id], var.additional_rds_security_group_ids)

  password = random_password.db_password[0].result

  # Snapshot configuration
  skip_final_snapshot = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : (
    var.final_snapshot_identifier != null ? var.final_snapshot_identifier : "${var.name_prefix}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  )

  lifecycle {
    ignore_changes = [password, final_snapshot_identifier]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-database"
  })
}

# ==============================================================================
# RDS PROXY (CONDITIONAL)
# ==============================================================================

# Separate RDS credentials secret for proxy authentication
resource "aws_secretsmanager_secret" "rds_credentials" {
  count = var.create_rds ? 1 : 0

  name        = "${var.name_prefix}/rds-credentials"
  description = "RDS credentials for proxy authentication"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds-credentials"
  })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  count = var.create_rds ? 1 : 0

  secret_id = aws_secretsmanager_secret.rds_credentials[0].id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.db_password[0].result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Security group for RDS Proxy
resource "aws_security_group" "sequin_rds_proxy_sg" {
  count = var.create_rds ? 1 : 0

  name        = "${var.name_prefix}-rds-proxy-sg"
  description = "Security group for Sequin RDS Proxy"
  vpc_id      = local.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.sequin-ecs-sg.id]
  }

  egress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.sequin-rds-sg[0].id]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds-proxy-sg"
  })
}

# Allow RDS Proxy to connect to RDS
## Note: Do not mix inline SG rules with separate aws_security_group_rule resources
## for the same security group, as it causes perpetual diffs. The RDS proxy ingress
## is managed inline above by adding sequin_rds_proxy_sg to security_groups.

# IAM role for RDS Proxy
resource "aws_iam_role" "rds_proxy_role" {
  count = var.create_rds ? 1 : 0

  name = "${var.name_prefix}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "rds.amazonaws.com"
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds-proxy-role"
  })
}

# IAM policy for RDS Proxy to access secrets
resource "aws_iam_role_policy" "rds_proxy_policy" {
  count = var.create_rds ? 1 : 0

  name = "${var.name_prefix}-rds-proxy-policy"
  role = aws_iam_role.rds_proxy_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = aws_secretsmanager_secret.rds_credentials[0].arn
    }]
  })
}

# RDS Proxy
resource "aws_db_proxy" "sequin_proxy" {
  count = var.create_rds ? 1 : 0

  name                   = "${var.name_prefix}-rds-proxy"
  engine_family         = "POSTGRESQL"
  require_tls           = true
  idle_client_timeout   = 1800
  role_arn              = aws_iam_role.rds_proxy_role[0].arn

  auth {
    auth_scheme = "SECRETS"
    # Make auth config explicit to avoid perpetual diffs
    # AWS defaults can appear in state; set them here for stability
    iam_auth                   = "DISABLED"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    secret_arn                = aws_secretsmanager_secret.rds_credentials[0].arn
  }

  vpc_subnet_ids         = local.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.sequin_rds_proxy_sg[0].id]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rds-proxy"
  })

  depends_on = [aws_db_instance.sequin-database]
}

# RDS Proxy target group
resource "aws_db_proxy_default_target_group" "sequin_proxy_target_group" {
  count = var.create_rds ? 1 : 0

  db_proxy_name = aws_db_proxy.sequin_proxy[0].name

  connection_pool_config {
    max_connections_percent      = var.rds_proxy_max_connections_percent
    max_idle_connections_percent = var.rds_proxy_max_idle_connections_percent
    session_pinning_filters      = ["EXCLUDE_VARIABLE_SETS"]
  }
}

# RDS Proxy target
resource "aws_db_proxy_target" "sequin_proxy_target" {
  count = var.create_rds ? 1 : 0

  db_proxy_name         = aws_db_proxy.sequin_proxy[0].name
  target_group_name     = aws_db_proxy_default_target_group.sequin_proxy_target_group[0].name
  db_instance_identifier = aws_db_instance.sequin-database[0].identifier

  depends_on = [aws_db_proxy_default_target_group.sequin_proxy_target_group]
}

# ==============================================================================
# ELASTICACHE REDIS (CONDITIONAL)
# ==============================================================================

resource "aws_elasticache_cluster" "sequin-main" {
  count = var.create_redis ? 1 : 0

  auto_minor_version_upgrade = "true"
  availability_zone          = var.availability_zones[0]
  az_mode                    = "single-az"
  cluster_id                 = "${var.name_prefix}-main"
  engine                     = "redis"
  engine_version             = "7.1"
  ip_discovery               = "ipv4"
  maintenance_window         = "wed:07:00-wed:08:00"
  network_type               = "ipv4"
  node_type                  = var.redis_instance_type
  num_cache_nodes            = "1"
  parameter_group_name       = "default.redis7"
  port                       = "6379"
  security_group_ids         = [aws_security_group.sequin-redis-sg[0].id]
  snapshot_retention_limit   = "15"
  snapshot_window            = "00:00-01:00"
  subnet_group_name          = aws_elasticache_subnet_group.sequin-subnet[0].name

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis-cluster"
  })
}

resource "aws_elasticache_subnet_group" "sequin-subnet" {
  count = var.create_redis ? 1 : 0

  description = "Managed by Terraform"
  name        = "${var.name_prefix}-subnet"
  subnet_ids  = local.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-elasticache-subnet-group"
  })
}

# ==============================================================================
# EC2 INSTANCES
# ==============================================================================

resource "aws_instance" "sequin-bastion" {
  count = var.create_bastion ? 1 : 0

  ami           = data.aws_ssm_parameter.sequin-ami-standard.value
  instance_type = "t3.micro"
  key_name      = var.ec2_key_name

  vpc_security_group_ids = [aws_security_group.sequin-bastion-sg[0].id]
  subnet_id              = local.primary_public_subnet_id

  associate_public_ip_address = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-bastion-host"
  })

  lifecycle {
    # No need to upgrade every time AMI changes.
    ignore_changes = [ami]
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }
}

resource "aws_autoscaling_group" "sequin-main" {
  capacity_rebalance        = "false"
  default_cooldown          = "300"
  default_instance_warmup   = "0"
  desired_capacity          = "1"
  force_delete              = "false"
  health_check_grace_period = "0"
  health_check_type         = "EC2"

  launch_template {
    id      = aws_launch_template.sequin-main.id
    version = "$Latest"
  }

  max_instance_lifetime = "0"
  max_size              = "2"
  metrics_granularity   = "1Minute"
  min_size              = "1"
  protect_from_scale_in = "false"

  tag {
    key                 = "Name"
    propagate_at_launch = "true"
    value               = "${var.name_prefix}-ecs-instance"
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = "true"
    }
  }

  vpc_zone_identifier       = [local.primary_private_subnet_id]
  wait_for_capacity_timeout = "10m"
}

resource "aws_launch_template" "sequin-main" {
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = "true"
      encrypted             = "false"
      iops                  = "0"
      volume_size           = "100"
      volume_type           = "gp2"
    }
  }

  disable_api_stop        = "false"
  disable_api_termination = "false"
  ebs_optimized           = "false"

  iam_instance_profile {
    name = local.ecs_instance_profile_name
  }

  image_id      = data.aws_ssm_parameter.sequin-ami-ecs.value
  instance_type = var.ecs_instance_type
  key_name      = var.ec2_key_name != null ? var.ec2_key_name : null

  monitoring {
    enabled = "true"
  }

  name = "${var.name_prefix}-ecs-launch-template"

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Create ECS config directory if it doesn't exist
    mkdir -p /etc/ecs

    # Configure ECS agent to join the sequin cluster
    echo "ECS_CLUSTER=${aws_ecs_cluster.sequin.name}" > /etc/ecs/ecs.config
    echo "ECS_BACKEND_HOST=" >> /etc/ecs/ecs.config
    echo "ECS_INSTANCE_ATTRIBUTES={\"${var.name_prefix}\":\"true\"}" >> /etc/ecs/ecs.config
    EOF
  )

  vpc_security_group_ids = [aws_security_group.sequin-ecs-sg.id]

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.name_prefix}-ecs-instance"
    })
  }

  tags = local.common_tags
}

# ==============================================================================
# APPLICATION SECRETS AND CONFIGURATION
# ==============================================================================

# Generate secure random secrets (base64 encoded as per Sequin docs)
resource "random_bytes" "secret_key_base" {
  length = 64
}

resource "random_bytes" "vault_key" {
  length = 32
}

resource "random_password" "admin_password" {
  length  = 16
  special = true
}

# Database and Redis URL determination - added to main locals block at top

# Create Sequin secrets store with placeholders
resource "aws_secretsmanager_secret" "sequin-config" {
  name        = "${var.name_prefix}/config"
  description = "${var.name_prefix} application configuration"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-config"
  })
}

resource "aws_secretsmanager_secret_version" "sequin-config" {
  secret_id = aws_secretsmanager_secret.sequin-config.id
  secret_string = jsonencode({
    # Database and Redis URLs - populated from infra outputs or external
    PG_URL    = local.pg_url
    REDIS_URL = local.redis_url

    # Auto-generated secure secrets
    SECRET_KEY_BASE = random_bytes.secret_key_base.base64
    ADMIN_PASSWORD  = random_password.admin_password.result
    VAULT_KEY       = random_bytes.vault_key.base64

    # Optional third-party integrations - leave empty if not needed
    GITHUB_CLIENT_ID     = ""
    GITHUB_CLIENT_SECRET = ""
    SENDGRID_API_KEY     = ""
    RETOOL_WORKFLOW_KEY  = ""
    LOOPS_API_KEY        = ""
    DATADOG_API_KEY      = ""
    DATADOG_APP_KEY      = ""
    # Not a valid DSN, but required to boot
    SENTRY_DSN                = "https://f8f11937067b2ef151cda3abe652667b@o398678.ingest.us.sentry.io/4508033603469312"
    PAGERDUTY_INTEGRATION_KEY = ""

    # SQS credentials for HTTP Push Consumer
    HTTP_PUSH_VIA_SQS_ACCESS_KEY_ID     = aws_iam_access_key.sequin_http_push_sqs_user_key.id
    HTTP_PUSH_VIA_SQS_SECRET_ACCESS_KEY = aws_iam_access_key.sequin_http_push_sqs_user_key.secret
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ==============================================================================
# ECS SERVICE AND TASK DEFINITION
# ==============================================================================

# CloudWatch Log Group for ECS logs
resource "aws_cloudwatch_log_group" "sequin" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = 7

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-ecs-logs"
  })
}

# ECS Task Definition
resource "aws_ecs_task_definition" "sequin-main" {
  family                   = "${var.name_prefix}-task-main"
  execution_role_arn       = aws_iam_role.sequin-ecs-task-execution-role.arn
  task_role_arn            = aws_iam_role.sequin-ecs-task-role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]

  container_definitions = jsonencode([
    {
      name      = var.name_prefix
      image     = "${var.image_repository}:${var.image_tag}"
      essential = true

      memory            = var.memory
      memoryReservation = var.memory_reservation
      cpu               = 0

      environment = [
        for k in sort(keys(local.ecs_env_map)) : {
          name  = k
          value = local.ecs_env_map[k]
        }
      ]

      secrets = local.ecs_task_secrets

      portMappings = [
        {
          name          = "${var.name_prefix}-7376-tcp"
          containerPort = 7376
          hostPort      = 7376
          protocol      = "tcp"
        },
        {
          name          = "${var.name_prefix}-8376-tcp"
          containerPort = 8376
          hostPort      = 8376
          protocol      = "tcp"
        },
        {
          name          = "${var.name_prefix}-4369-tcp"
          containerPort = 4369
          hostPort      = 4369
          protocol      = "tcp"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:7376/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 45
      }

      systemControls = [
        {
          namespace = "net.ipv4.tcp_keepalive_time"
          value     = "60"
        },
        {
          namespace = "net.ipv4.tcp_keepalive_intvl"
          value     = "60"
        }
      ]

      ulimits = [
        {
          name      = "nofile"
          softLimit = 10240
          hardLimit = 40960
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.name_prefix}"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      mountPoints = []
      volumesFrom = []
    }
  ])

  skip_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-task"
  })
}

# ECS Service
resource "aws_ecs_service" "sequin-main" {
  name            = "${var.name_prefix}-main"
  cluster         = aws_ecs_cluster.sequin.name
  task_definition = aws_ecs_task_definition.sequin-main.arn
  desired_count   = 1
  launch_type     = "EC2"

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.sequin-ecs-sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.sequin-main.arn
    container_name   = var.name_prefix
    container_port   = 7376
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.sequin-metrics.arn
    container_name   = var.name_prefix
    container_port   = 8376
  }

  enable_execute_command            = true
  health_check_grace_period_seconds = 45
  enable_ecs_managed_tags           = true
  propagate_tags                    = "SERVICE"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-main-service"
  })
}
