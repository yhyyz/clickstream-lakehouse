#!/bin/bash

set -e

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER_NAME="clickstream-cluster"
DEFAULT_TASK_FAMILY="clickstream-task-optimized"
DEFAULT_SERVICE_NAME="clickstream-optimized-service"
DEFAULT_DESIRED_COUNT=4
DEFAULT_EBS_SIZE=500

# Initialize variables
REGION=""
CLUSTER_NAME=""
TASK_FAMILY=""
SERVICE_NAME=""
S3_BUCKET=""
VPC_ID=""
SUBNETS=""
SECURITY_GROUPS=""
DESIRED_COUNT=""
EBS_SIZE=""
KAFKA_BROKER_HOST=""
KAFKA_BROKER_PORT="9092"

# Function to show help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy ECS service with clickstream processing containers.

OPTIONS:
    -r, --region REGION              AWS region (default: $DEFAULT_REGION)
    -c, --cluster CLUSTER            ECS cluster name (default: $DEFAULT_CLUSTER_NAME)
    -t, --task-family FAMILY         Task definition family name (default: $DEFAULT_TASK_FAMILY)
    -s, --service SERVICE            Service name (default: $DEFAULT_SERVICE_NAME)
    -b, --s3-bucket BUCKET           S3 bucket name for data storage (required)
    -v, --vpc VPC_ID                 VPC ID to deploy in (required)
    --subnets SUBNET1,SUBNET2        Comma-separated subnet IDs (optional, will auto-detect private subnets if not provided)
    --security-groups SG1,SG2        Comma-separated security group IDs (optional, will create default if not provided)
    --desired-count COUNT            Desired number of tasks (default: $DEFAULT_DESIRED_COUNT)
    --ebs-size SIZE                  EBS volume size in GiB (default: $DEFAULT_EBS_SIZE)
    --kafka-broker-host HOST         Kafka broker host (required)
    --kafka-broker-port PORT         Kafka broker port (default: $KAFKA_BROKER_PORT)
    -h, --help                       Show this help message

EXAMPLES:
    # Basic deployment
    $0 --s3-bucket my-clickstream-bucket --vpc vpc-12345678 --kafka-broker-host my-kafka-host.amazonaws.com

    # Advanced deployment with custom settings
    $0 --region us-west-2 --cluster my-cluster --s3-bucket my-bucket --vpc vpc-12345678 \\
       --subnets subnet-123,subnet-456 --desired-count 2 --kafka-broker-host my-kafka-host.amazonaws.com

NOTES:
    - If subnets are not specified, the script will automatically find private subnets in the specified VPC
    - If security groups are not specified, a default security group will be created
    - The script will create necessary IAM roles if they don't exist
    - ECS cluster will be created if it doesn't exist

EOF
}

# Function to parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -t|--task-family)
                TASK_FAMILY="$2"
                shift 2
                ;;
            -s|--service)
                SERVICE_NAME="$2"
                shift 2
                ;;
            -b|--s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            -v|--vpc)
                VPC_ID="$2"
                shift 2
                ;;
            --subnets)
                SUBNETS="$2"
                shift 2
                ;;
            --security-groups)
                SECURITY_GROUPS="$2"
                shift 2
                ;;
            --desired-count)
                DESIRED_COUNT="$2"
                shift 2
                ;;
            --ebs-size)
                EBS_SIZE="$2"
                shift 2
                ;;
            --kafka-broker-host)
                KAFKA_BROKER_HOST="$2"
                shift 2
                ;;
            --kafka-broker-port)
                KAFKA_BROKER_PORT="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Function to validate required parameters
validate_params() {
    local errors=0
    
    if [[ -z "$S3_BUCKET" ]]; then
        echo "Error: S3 bucket name is required (--s3-bucket)"
        errors=1
    fi
    
    if [[ -z "$VPC_ID" ]]; then
        echo "Error: VPC ID is required (--vpc)"
        errors=1
    fi
    
    if [[ -z "$KAFKA_BROKER_HOST" ]]; then
        echo "Error: Kafka broker host is required (--kafka-broker-host)"
        errors=1
    fi
    
    if [[ $errors -eq 1 ]]; then
        echo ""
        show_help
        exit 1
    fi
}

# Function to set default values
set_defaults() {
    REGION=${REGION:-$DEFAULT_REGION}
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    TASK_FAMILY=${TASK_FAMILY:-$DEFAULT_TASK_FAMILY}
    SERVICE_NAME=${SERVICE_NAME:-$DEFAULT_SERVICE_NAME}
    DESIRED_COUNT=${DESIRED_COUNT:-$DEFAULT_DESIRED_COUNT}
    EBS_SIZE=${EBS_SIZE:-$DEFAULT_EBS_SIZE}
}

# Function to get AWS account ID
get_account_id() {
    aws sts get-caller-identity --query 'Account' --output text --region "$REGION"
}

# Function to get private subnets from VPC
get_private_subnets() {
    local vpc_id="$1"
    
    local private_subnets
    private_subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=*private*" \
        --query 'Subnets[].SubnetId' \
        --output text \
        --region "$REGION" | tr '\t' ',')
    
    if [[ -z "$private_subnets" ]]; then
        # Fallback: get subnets without public IP assignment
        private_subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$vpc_id" "Name=map-public-ip-on-launch,Values=false" \
            --query 'Subnets[].SubnetId' \
            --output text \
            --region "$REGION" | tr '\t' ',')
    fi
    
    if [[ -z "$private_subnets" ]]; then
        # Final fallback: get all subnets in VPC
        private_subnets=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'Subnets[].SubnetId' \
            --output text \
            --region "$REGION" | tr '\t' ',')
    fi
    
    echo "$private_subnets"
}

# Function to create default security group
create_default_security_group() {
    local vpc_id="$1"
    local sg_name="clickstream-ecs-sg"
    
    # Check if security group already exists
    local existing_sg
    existing_sg=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION" 2>/dev/null || echo "None")
    
    if [[ "$existing_sg" != "None" ]]; then
        echo "$existing_sg"
        return
    fi
    
    # Create new security group
    local sg_id
    sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "Security group for clickstream ECS service" \
        --vpc-id "$vpc_id" \
        --query 'GroupId' \
        --output text \
        --region "$REGION")
    
    # Add ingress rules
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 8802 \
        --source-group "$sg_id" \
        --region "$REGION" >/dev/null
    
    echo "$sg_id"
}

# Function to create IAM roles
create_iam_roles() {
    local account_id="$1"
    
    echo "Creating IAM roles..."
    
    # Create trust policy for ECS tasks
    cat > /tmp/ecs-task-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
    
    # Create ECS Task Execution Role
    local execution_role_name="ecsTaskExecutionRole-${CLUSTER_NAME}"
    if ! aws iam get-role --role-name "$execution_role_name" --region "$REGION" >/dev/null 2>&1; then
        echo "Creating ECS Task Execution Role..."
        
        aws iam create-role \
            --role-name "$execution_role_name" \
            --assume-role-policy-document file:///tmp/ecs-task-trust-policy.json \
            --region "$REGION" >/dev/null
        
        aws iam attach-role-policy \
            --role-name "$execution_role_name" \
            --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" \
            --region "$REGION"
    fi
    
    # Create ECS Task Role (with S3 and CloudWatch permissions)
    local task_role_name="ecsTaskRole-${CLUSTER_NAME}"
    if ! aws iam get-role --role-name "$task_role_name" --region "$REGION" >/dev/null 2>&1; then
        echo "Creating ECS Task Role..."
        
        aws iam create-role \
            --role-name "$task_role_name" \
            --assume-role-policy-document file:///tmp/ecs-task-trust-policy.json \
            --region "$REGION" >/dev/null
        
        # Create custom policy for task role
        cat > /tmp/ecs-task-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::${S3_BUCKET}",
                "arn:aws:s3:::${S3_BUCKET}/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogStreams"
            ],
            "Resource": "*"
        }
    ]
}
EOF
        
        aws iam put-role-policy \
            --role-name "$task_role_name" \
            --policy-name "ClickstreamTaskPolicy" \
            --policy-document file:///tmp/ecs-task-policy.json \
            --region "$REGION"
        
        rm /tmp/ecs-task-policy.json
    fi
    
    # Create ECS Infrastructure Role for EBS
    local infra_role_name="ecsInfrastructureRole-${CLUSTER_NAME}"
    if ! aws iam get-role --role-name "$infra_role_name" --region "$REGION" >/dev/null 2>&1; then
        echo "Creating ECS Infrastructure Role..."
        
        cat > /tmp/ecs-infra-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
        
        aws iam create-role \
            --role-name "$infra_role_name" \
            --assume-role-policy-document file:///tmp/ecs-infra-trust-policy.json \
            --description "ECS Infrastructure Role for EBS volume management" \
            --region "$REGION" >/dev/null
        
        # Create EBS policy
        cat > /tmp/ecs-ebs-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateVolume",
                "ec2:DeleteVolume",
                "ec2:AttachVolume",
                "ec2:DetachVolume",
                "ec2:ModifyVolume",
                "ec2:DescribeVolumes",
                "ec2:DescribeVolumeStatus",
                "ec2:DescribeVolumeAttribute",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:DescribeTags",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups"
            ],
            "Resource": "*"
        }
    ]
}
EOF
        
        aws iam put-role-policy \
            --role-name "$infra_role_name" \
            --policy-name "ECSInfrastructureRoleForEBS" \
            --policy-document file:///tmp/ecs-ebs-policy.json \
            --region "$REGION"
        
        rm /tmp/ecs-infra-trust-policy.json /tmp/ecs-ebs-policy.json
    fi
    
    # Clean up trust policy file
    rm -f /tmp/ecs-task-trust-policy.json
    
    # Wait for roles to be available
    echo "Waiting for IAM roles to be available..."
    sleep 10
}

# Function to create S3 bucket
create_s3_bucket() {
    local bucket_name="$1"
    
    echo "Creating S3 bucket: $bucket_name"
    
    if aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null; then
        echo "S3 bucket $bucket_name already exists"
        return
    fi
    
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$bucket_name" --region "$REGION"
    else
        aws s3api create-bucket \
            --bucket "$bucket_name" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
    
    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "$bucket_name" \
        --versioning-configuration Status=Enabled \
        --region "$REGION"
}

# Function to create CloudWatch log group
create_log_group() {
    local log_group_name="/ecs/${CLUSTER_NAME}"
    
    echo "Creating CloudWatch log group: $log_group_name"
    
    aws logs create-log-group \
        --log-group-name "$log_group_name" \
        --region "$REGION" \
        2>/dev/null || echo "Log group already exists"
}

# Function to create ECS cluster
create_ecs_cluster() {
    local cluster_name="$1"
    
    echo "Checking ECS cluster: $cluster_name"
    
    if aws ecs describe-clusters --clusters "$cluster_name" --region "$REGION" >/dev/null 2>&1; then
        echo "ECS cluster $cluster_name already exists"
        return
    fi
    
    echo "Creating ECS cluster: $cluster_name"
    aws ecs create-cluster --cluster-name "$cluster_name" --region "$REGION" >/dev/null
}

# Function to generate task definition
generate_task_definition() {
    local account_id="$1"
    local task_role_arn="arn:aws:iam::${account_id}:role/ecsTaskRole-${CLUSTER_NAME}"
    local execution_role_arn="arn:aws:iam::${account_id}:role/ecsTaskExecutionRole-${CLUSTER_NAME}"
    local log_group_name="/ecs/${CLUSTER_NAME}"
    
    cat > task-definition-generated.json << EOF
{
  "family": "$TASK_FAMILY",
  "taskRoleArn": "$task_role_arn",
  "executionRoleArn": "$execution_role_arn",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "8192",
  "memory": "16384",
  "containerDefinitions": [
    {
      "name": "clickstream-container",
      "image": "${account_id}.dkr.ecr.${REGION}.amazonaws.com/clickstream-openresty-lua-msk-optimized:latest",
      "cpu": 6144,
      "memory": 12288,
      "portMappings": [
        {
          "containerPort": 8802,
          "hostPort": 8802,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "wget --no-verbose --tries=1 --spider http://localhost:8802/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      },
      "environment": [
        {
          "name": "KAFKA_BROKER_HOST",
          "value": "$KAFKA_BROKER_HOST"
        },
        {
          "name": "KAFKA_BROKER_PORT",
          "value": "$KAFKA_BROKER_PORT"
        },
        {
          "name": "SEND_S3_ONLY",
          "value": "enable"
        },
        {
          "name": "S3_BUCKET",
          "value": "$S3_BUCKET"
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "clickstream-ebs-volume",
          "containerPath": "/opt/app/collect-app/logs",
          "readOnly": false
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$log_group_name",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    },
    {
      "name": "fluent-bit",
      "image": "${account_id}.dkr.ecr.${REGION}.amazonaws.com/custom-fluent-bit-optimized:latest",
      "cpu": 2048,
      "memory": 4096,
      "essential": false,
      "mountPoints": [
        {
          "sourceVolume": "clickstream-ebs-volume",
          "containerPath": "/opt/app/collect-app/logs",
          "readOnly": true
        }
      ],
      "environment": [
        {
          "name": "S3_BUCKET_NAME",
          "value": "$S3_BUCKET"
        },
        {
          "name": "AWS_REGION",
          "value": "$REGION"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$log_group_name",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "fluent-bit"
        }
      }
    }
  ],
  "volumes": [
    {
      "name": "clickstream-ebs-volume",
      "configuredAtLaunch": true
    }
  ]
}
EOF
}

# Function to generate service definition
generate_service_definition() {
    local account_id="$1"
    local subnet_list="$2"
    local sg_list="$3"
    local infra_role_arn="arn:aws:iam::${account_id}:role/ecsInfrastructureRole-${CLUSTER_NAME}"
    
    # Convert comma-separated strings to JSON arrays
    local subnet_array
    subnet_array=$(echo "$subnet_list" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')
    
    local sg_array
    sg_array=$(echo "$sg_list" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')
    
    cat > service-definition-generated.json << EOF
{
  "serviceName": "$SERVICE_NAME",
  "cluster": "$CLUSTER_NAME",
  "taskDefinition": "$TASK_FAMILY",
  "desiredCount": $DESIRED_COUNT,
  "launchType": "FARGATE",
  "networkConfiguration": {
    "awsvpcConfiguration": {
      "subnets": [$subnet_array],
      "securityGroups": [$sg_array],
      "assignPublicIp": "DISABLED"
    }
  },
  "volumeConfigurations": [
    {
      "name": "clickstream-ebs-volume",
      "managedEBSVolume": {
        "sizeInGiB": $EBS_SIZE,
        "volumeType": "gp3",
        "iops": 16000,
        "throughput": 1000,
        "filesystemType": "ext4",
        "roleArn": "$infra_role_arn"
      }
    }
  ]
}
EOF
}

# Main deployment function
main() {
    echo "=== ECS Clickstream Deployment Script ==="
    echo ""
    
    # Parse command line arguments
    parse_args "$@"
    
    # Validate required parameters
    validate_params
    
    # Set default values
    set_defaults
    
    echo "Deployment Configuration:"
    echo "  Region: $REGION"
    echo "  Cluster: $CLUSTER_NAME"
    echo "  Service: $SERVICE_NAME"
    echo "  Task Family: $TASK_FAMILY"
    echo "  S3 Bucket: $S3_BUCKET"
    echo "  VPC: $VPC_ID"
    echo "  Desired Count: $DESIRED_COUNT"
    echo "  EBS Size: ${EBS_SIZE}GB"
    echo "  Kafka Broker: ${KAFKA_BROKER_HOST}:${KAFKA_BROKER_PORT}"
    echo ""
    
    # Get AWS account ID
    local account_id
    account_id=$(get_account_id)
    echo "AWS Account ID: $account_id"
    echo ""
    
    # Auto-detect subnets if not provided
    if [[ -z "$SUBNETS" ]]; then
        echo "Auto-detecting private subnets in VPC $VPC_ID..."
        SUBNETS=$(get_private_subnets "$VPC_ID")
        if [[ -z "$SUBNETS" ]]; then
            echo "Error: No subnets found in VPC $VPC_ID"
            exit 1
        fi
    fi
    echo "Using subnets: $SUBNETS"
    
    # Create default security group if not provided
    if [[ -z "$SECURITY_GROUPS" ]]; then
        echo "Creating default security group..."
        SECURITY_GROUPS=$(create_default_security_group "$VPC_ID")
    fi
    echo "Using security groups: $SECURITY_GROUPS"
    echo ""
    
    # Create IAM roles
    create_iam_roles "$account_id"
    
    # Create S3 bucket
    create_s3_bucket "$S3_BUCKET"
    
    # Create CloudWatch log group
    create_log_group
    
    # Create ECS cluster
    create_ecs_cluster "$CLUSTER_NAME"
    
    # Generate configuration files
    echo "Generating task and service definitions..."
    generate_task_definition "$account_id"
    generate_service_definition "$account_id" "$SUBNETS" "$SECURITY_GROUPS"
    
    # Register task definition
    echo "Registering ECS task definition..."
    local task_def_arn
    task_def_arn=$(aws ecs register-task-definition \
        --cli-input-json file://task-definition-generated.json \
        --region "$REGION" \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    echo "Task definition registered: $task_def_arn"
    
    # Deploy service
    echo "Deploying ECS service..."
    
    # Check if service exists and its status
    local service_status
    service_status=$(aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].status' \
        --output text 2>/dev/null || echo "NONE")
    
    if [[ "$service_status" == "ACTIVE" ]]; then
        echo "Updating existing active service..."
        aws ecs update-service \
            --cluster "$CLUSTER_NAME" \
            --service "$SERVICE_NAME" \
            --task-definition "$TASK_FAMILY" \
            --desired-count "$DESIRED_COUNT" \
            --region "$REGION" >/dev/null
    elif [[ "$service_status" == "INACTIVE" ]] || [[ "$service_status" == "DRAINING" ]]; then
        echo "Service exists but is $service_status. Deleting and recreating..."
        
        # Force delete the service
        aws ecs delete-service \
            --cluster "$CLUSTER_NAME" \
            --service "$SERVICE_NAME" \
            --force \
            --region "$REGION" >/dev/null
        
        # Wait longer for deletion to complete
        echo "Waiting for service deletion to complete..."
        local wait_count=0
        while [[ $wait_count -lt 30 ]]; do
            local check_status
            check_status=$(aws ecs describe-services \
                --cluster "$CLUSTER_NAME" \
                --services "$SERVICE_NAME" \
                --region "$REGION" \
                --query 'services[0].status' \
                --output text 2>/dev/null || echo "NONE")
            
            if [[ "$check_status" == "NONE" ]]; then
                echo "Service successfully deleted."
                break
            fi
            
            echo "Service still exists (status: $check_status), waiting..."
            sleep 10
            wait_count=$((wait_count + 1))
        done
        
        if [[ $wait_count -eq 30 ]]; then
            echo "Warning: Service deletion took longer than expected, proceeding anyway..."
        fi
        
        echo "Creating new service..."
        aws ecs create-service \
            --cli-input-json file://service-definition-generated.json \
            --region "$REGION" >/dev/null
    else
        echo "Creating new service..."
        aws ecs create-service \
            --cli-input-json file://service-definition-generated.json \
            --region "$REGION" >/dev/null
    fi
    
    echo "Waiting for service to stabilize..."
    aws ecs wait services-stable \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION"
    
    echo ""
    echo "=== Deployment Complete ==="
    
    # Show service status
    echo "Service Status:"
    aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'services[0].{ServiceName:serviceName,Status:status,RunningCount:runningCount,DesiredCount:desiredCount}' \
        --output table
    
    # Clean up generated files
    rm -f task-definition-generated.json service-definition-generated.json
    
    echo ""
    echo "Deployment completed successfully!"
}

# Run main function with all arguments
main "$@"
