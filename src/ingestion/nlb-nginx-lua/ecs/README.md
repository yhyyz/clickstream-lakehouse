# ECS Clickstream Deployment

This directory contains an optimized ECS deployment script for the clickstream processing service.

## Features

- **Parameterized deployment**: Support for different regions, VPCs, and environments
- **Automatic resource creation**: Creates IAM roles, security groups, and S3 buckets as needed
- **VPC subnet auto-detection**: Automatically finds private subnets in the specified VPC
- **Health checks**: Nginx container includes health check on `/health` endpoint
- **Cross-account support**: Automatically detects account ID for ECR image URLs
- **Environment-specific configuration**: All hardcoded values replaced with variables

## Prerequisites

- AWS CLI configured with appropriate permissions
- Docker images pushed to ECR:
  - `clickstream-openresty-lua-msk-optimized:latest`
  - `custom-fluent-bit-optimized:latest`

## Quick Start

### Basic Deployment

```bash
./deploy-ecs-optimized.sh \
  --s3-bucket my-clickstream-logs \
  --vpc vpc-12345678 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

### Advanced Deployment

```bash
./deploy-ecs-optimized.sh \
  --region us-west-2 \
  --cluster my-clickstream-cluster \
  --s3-bucket my-clickstream-logs \
  --vpc vpc-12345678 \
  --subnets subnet-123,subnet-456 \
  --security-groups sg-789 \
  --desired-count 2 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `--region` | No | us-east-1 | AWS region |
| `--cluster` | No | clickstream-cluster | ECS cluster name |
| `--task-family` | No | clickstream-task-optimized | Task definition family |
| `--service` | No | clickstream-optimized-service | Service name |
| `--s3-bucket` | **Yes** | - | S3 bucket for data storage |
| `--vpc` | **Yes** | - | VPC ID to deploy in |
| `--subnets` | No | Auto-detected | Comma-separated subnet IDs |
| `--security-groups` | No | Auto-created | Comma-separated security group IDs |
| `--desired-count` | No | 4 | Number of tasks to run |
| `--ebs-size` | No | 500 | EBS volume size in GiB |
| `--kafka-broker-host` | **Yes** | - | Kafka broker hostname |
| `--kafka-broker-port` | No | 9092 | Kafka broker port |

## What the Script Does

1. **Validates parameters** and shows configuration
2. **Creates IAM roles** if they don't exist:
   - ECS Task Execution Role
   - ECS Task Role (with S3 and CloudWatch permissions)
   - ECS Infrastructure Role (for EBS volume management)
3. **Creates S3 bucket** with versioning enabled
4. **Creates CloudWatch log group** for container logs
5. **Creates ECS cluster** if it doesn't exist
6. **Auto-detects private subnets** in the specified VPC (if not provided)
7. **Creates default security group** (if not provided)
8. **Generates configuration files** with proper variable substitution
9. **Registers task definition** with health checks
10. **Creates or updates ECS service**
11. **Waits for service to stabilize**

## Health Checks

The nginx container includes a health check that:
- Checks `http://localhost:8802/health` endpoint
- Runs every 30 seconds
- Times out after 5 seconds
- Allows 3 retries
- Has a 60-second startup grace period

## Security

- **No public IP assignment**: Tasks run in private subnets only
- **Least privilege IAM roles**: Custom roles with minimal required permissions
- **VPC security groups**: Network access controlled via security groups

## Troubleshooting

### View deployment help
```bash
./deploy-ecs-optimized.sh --help
```

### Check service status
```bash
aws ecs describe-services \
  --cluster clickstream-cluster \
  --services clickstream-optimized-service \
  --region us-east-1
```

### View container logs
```bash
aws logs tail /ecs/clickstream-cluster --follow --region us-east-1
```

### Check task health
```bash
aws ecs describe-tasks \
  --cluster clickstream-cluster \
  --tasks $(aws ecs list-tasks --cluster clickstream-cluster --service-name clickstream-optimized-service --query 'taskArns[0]' --output text) \
  --region us-east-1
```

## Files

- `deploy-ecs-optimized.sh`: Main deployment script
- `task-definition-template.json`: Template for task definition
- `service-definition-template.json`: Template for service definition
- `task-definition.json`: Original task definition (for reference)
- `service-definition.json`: Original service definition (for reference)
- `deploy-ecs.sh`: Original deployment script (for reference)
- `README.md`: English documentation
- `README-zh.md`: Chinese documentation

## Migration from Original Script

The new script provides the same functionality as the original but with:
- Better parameter handling
- Automatic resource creation
- Cross-environment support
- Health checks
- Improved error handling

To migrate, simply use the new script with the appropriate parameters for your environment.

## Usage Examples

### Production Deployment
```bash
./deploy-ecs-optimized.sh \
  --region us-east-1 \
  --cluster production-clickstream \
  --s3-bucket production-clickstream-data \
  --vpc vpc-prod123456 \
  --desired-count 6 \
  --kafka-broker-host prod-kafka.internal.company.com
```

### Test Environment Deployment
```bash
./deploy-ecs-optimized.sh \
  --region us-west-2 \
  --cluster test-clickstream \
  --s3-bucket test-clickstream-data \
  --vpc vpc-test789012 \
  --desired-count 2 \
  --kafka-broker-host test-kafka.internal.company.com
```

### Custom Subnets and Security Groups
```bash
./deploy-ecs-optimized.sh \
  --s3-bucket my-clickstream-data \
  --vpc vpc-12345678 \
  --subnets subnet-private1,subnet-private2 \
  --security-groups sg-custom123 \
  --kafka-broker-host kafka.example.com
```

## Notes

- If subnets are not specified, the script will automatically find private subnets in the specified VPC
- If security groups are not specified, a default security group will be created
- The script will create necessary IAM roles if they don't exist
- ECS cluster will be created if it doesn't exist
- All resources use consistent naming conventions for easy management

## Supported AWS Services

This script integrates with the following AWS services:
- **Amazon ECS**: Container orchestration
- **Amazon ECR**: Container image registry
- **Amazon S3**: Data storage
- **Amazon VPC**: Network isolation
- **AWS IAM**: Access management
- **Amazon CloudWatch**: Logging and monitoring
- **Amazon EBS**: Persistent storage

## Documentation

- [English Documentation](README.md)
- [中文文档](README-zh.md)
