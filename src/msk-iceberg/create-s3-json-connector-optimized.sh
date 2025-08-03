#!/bin/bash

# MSK S3 JSON Sink Connector Creation Script (Optimized)
# This script creates an MSK S3 JSON Sink Connector with proper resource management

# Remove set -e to handle errors gracefully
# set -e

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_TOPIC_NAME="app_logs"
DEFAULT_WORKER_COUNT=6
DEFAULT_MCU_COUNT=1
DEFAULT_PARTITION_TIME_COL="ingestion_time"
FORCE_RECREATE=false

# Global variables for tracking execution
EXECUTION_STATUS="FAILED"
ERROR_MESSAGE=""
CONNECTOR_ARN=""
PLUGIN_ARN=""
WORKER_CONFIG_ARN=""

# Function to handle errors and generate info file
handle_error() {
    local error_msg="$1"
    ERROR_MESSAGE="$error_msg"
    echo "ERROR: $error_msg" >&2
    generate_info_file
    exit 1
}

# Function to generate info file regardless of success/failure
generate_info_file() {
    local info_file="msk-s3-json-connector-info.json"
    echo "Creating information file: $info_file"
    
    # Get current timestamp
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Try to get connector ARN if it exists
    if [ -z "$CONNECTOR_ARN" ] && [ -n "$CONNECTOR_NAME" ]; then
        CONNECTOR_ARN=$(aws kafkaconnect list-connectors --region "$REGION" --query "connectors[?connectorName=='$CONNECTOR_NAME'].connectorArn" --output text 2>/dev/null || echo "")
    fi
    
    cat > "$info_file" << EOF
{
    "execution_info": {
        "status": "$EXECUTION_STATUS",
        "timestamp": "$timestamp",
        "error_message": "$ERROR_MESSAGE",
        "script_version": "optimized"
    },
    "connector_info": {
        "connector_name": "${CONNECTOR_NAME:-msk-s3-sink-json}",
        "connector_arn": "${CONNECTOR_ARN:-}",
        "connector_type": "S3 JSON Sink",
        "region": "${REGION:-us-east-1}"
    },
    "msk_info": {
        "cluster_name": "${MSK_CLUSTER_NAME:-}",
        "cluster_arn": "${MSK_CLUSTER_ARN:-}",
        "bootstrap_servers": "${MSK_BOOTSTRAP_SERVERS:-}",
        "topic_name": "${TOPIC_NAME:-app_logs}"
    },
    "plugin_info": {
        "plugin_name": "${PLUGIN_NAME:-msk-s3-sink-plugin}",
        "plugin_arn": "${PLUGIN_ARN:-}",
        "plugin_s3_location": "s3://${S3_BUCKET:-}/${PLUGIN_S3_KEY:-plugins/confluentinc-kafka-connect-s3-10.6.7.zip}",
        "plugin_version": "10.6.7"
    },
    "capacity_info": {
        "worker_count": ${WORKER_COUNT:-6},
        "mcu_count": ${MCU_COUNT:-1},
        "max_tasks": 3
    },
    "storage_info": {
        "s3_bucket": "${S3_BUCKET:-}",
        "data_location": "s3://${S3_BUCKET:-}/app-logs-json/",
        "partition_format": "year=yyyy/month=MM/day=dd/hour=HH",
        "partition_time_column": "${PARTITION_TIME_COL:-ingestion_time}"
    },
    "iam_info": {
        "service_role_name": "${ROLE_NAME:-}",
        "service_role_arn": "${ROLE_ARN:-}"
    },
    "worker_config_info": {
        "worker_config_name": "${WORKER_CONFIG_NAME:-}",
        "worker_config_arn": "${WORKER_CONFIG_ARN:-}"
    },
    "monitoring_info": {
        "cloudwatch_log_group": "msk-connector-log",
        "flush_size": "1000",
        "rotate_interval_ms": "60000"
    }
}
EOF

    echo "Information file created: $info_file"
}

# Function to show help
show_help() {
    cat << EOF
MSK S3 JSON Sink Connector Creation Script

USAGE:
    $0 [OPTIONS] <s3-bucket> <msk-cluster-name>

REQUIRED PARAMETERS:
    s3-bucket           S3 bucket name for storing data and plugins
    msk-cluster-name    Name of the MSK cluster

OPTIONS:
    -r, --region REGION         AWS region (default: $DEFAULT_REGION)
    -t, --topic TOPIC          Kafka topic name (default: $DEFAULT_TOPIC_NAME)
    -w, --workers COUNT        Number of workers (default: $DEFAULT_WORKER_COUNT)
    -m, --mcu COUNT           MCU count (default: $DEFAULT_MCU_COUNT)
    -p, --partition-time-col COL  Partition time column (ingestion_time|kafka_time, default: $DEFAULT_PARTITION_TIME_COL)
    -f, --force               Force recreate existing resources
    -h, --help                Show this help message

EXAMPLES:
    $0 my-bucket my-msk-cluster
    $0 --region ap-southeast-1 --topic logs my-bucket my-cluster
    $0 --force --workers 4 --partition-time-col kafka_time my-bucket my-cluster

OUTPUT:
    Creates an info file: msk-s3-json-connector-info.json with connector details
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -t|--topic)
            TOPIC_NAME="$2"
            shift 2
            ;;
        -w|--workers)
            WORKER_COUNT="$2"
            shift 2
            ;;
        -m|--mcu)
            MCU_COUNT="$2"
            shift 2
            ;;
        -p|--partition-time-col)
            PARTITION_TIME_COL="$2"
            # Validate the parameter value
            if [[ "$PARTITION_TIME_COL" != "ingestion_time" && "$PARTITION_TIME_COL" != "kafka_time" ]]; then
                echo "Error: partition-time-col must be either 'ingestion_time' or 'kafka_time'"
                exit 1
            fi
            shift 2
            ;;
        -f|--force)
            FORCE_RECREATE=true
            shift
            ;;
        -*)
            echo "Unknown option $1"
            show_help
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Set defaults if not provided
REGION=${REGION:-$DEFAULT_REGION}
TOPIC_NAME=${TOPIC_NAME:-$DEFAULT_TOPIC_NAME}
WORKER_COUNT=${WORKER_COUNT:-$DEFAULT_WORKER_COUNT}
MCU_COUNT=${MCU_COUNT:-$DEFAULT_MCU_COUNT}
PARTITION_TIME_COL=${PARTITION_TIME_COL:-$DEFAULT_PARTITION_TIME_COL}

# Check required parameters
if [ $# -lt 2 ]; then
    echo "Error: Missing required parameters"
    show_help
    handle_error "Missing required parameters: s3-bucket and msk-cluster-name"
fi

S3_BUCKET=$1
MSK_CLUSTER_NAME=$2

# Validate S3 bucket exists
if ! aws s3 ls "s3://$S3_BUCKET" --region "$REGION" >/dev/null 2>&1; then
    handle_error "S3 bucket '$S3_BUCKET' does not exist or is not accessible in region $REGION"
fi

echo "=== MSK S3 JSON Sink Connector Creation ==="
echo "Region: $REGION"
echo "S3 Bucket: $S3_BUCKET"
echo "MSK Cluster Name: $MSK_CLUSTER_NAME"
echo "Topic: $TOPIC_NAME"
echo "Workers: $WORKER_COUNT"
echo "MCU Count: $MCU_COUNT"
echo "Partition Time Column: $PARTITION_TIME_COL"
echo "Force Recreate: $FORCE_RECREATE"
echo "============================================"

# Get MSK cluster information
echo "Getting MSK cluster information..."
MSK_CLUSTER_ARN=$(aws kafka list-clusters --region $REGION --query "ClusterInfoList[?ClusterName=='$MSK_CLUSTER_NAME'].ClusterArn" --output text 2>/dev/null)

if [ -z "$MSK_CLUSTER_ARN" ] || [ "$MSK_CLUSTER_ARN" = "None" ]; then
    handle_error "MSK cluster '$MSK_CLUSTER_NAME' not found in region $REGION"
fi

MSK_CLUSTER_INFO=$(aws kafka describe-cluster --cluster-arn $MSK_CLUSTER_ARN --region $REGION 2>/dev/null)
if [ $? -ne 0 ]; then
    handle_error "Failed to get MSK cluster information for '$MSK_CLUSTER_NAME'"
fi

# Get bootstrap brokers
echo "Getting MSK bootstrap brokers..."
MSK_BOOTSTRAP_SERVERS=$(aws kafka get-bootstrap-brokers --cluster-arn $MSK_CLUSTER_ARN --region $REGION | jq -r '.BootstrapBrokerString')

# Extract VPC and subnet information
VPC_SECURITY_GROUPS=$(echo $MSK_CLUSTER_INFO | jq -r '.ClusterInfo.BrokerNodeGroupInfo.SecurityGroups[]' | tr '\n' ',' | sed 's/,$//')
VPC_SUBNETS=$(echo $MSK_CLUSTER_INFO | jq -r '.ClusterInfo.BrokerNodeGroupInfo.ClientSubnets[]' | tr '\n' ',' | sed 's/,$//')

echo "MSK Bootstrap Servers: $MSK_BOOTSTRAP_SERVERS"
echo "VPC Security Groups: $VPC_SECURITY_GROUPS"
echo "VPC Subnets: $VPC_SUBNETS"

# Convert comma-separated subnets to array format
IFS=',' read -ra SUBNET_ARRAY <<< "$VPC_SUBNETS"
SUBNET_JSON=$(printf '"%s",' "${SUBNET_ARRAY[@]}")
SUBNET_JSON="[${SUBNET_JSON%,}]"

# Convert comma-separated security groups to array format
IFS=',' read -ra SG_ARRAY <<< "$VPC_SECURITY_GROUPS"
SG_JSON=$(printf '"%s",' "${SG_ARRAY[@]}")
SG_JSON="[${SG_JSON%,}]"

# Function to safely delete IAM role with policies
delete_iam_role_safely() {
    local role_name=$1
    local region=$2
    
    echo "Detaching policies from IAM role: $role_name"
    
    # List and detach all attached policies
    local attached_policies=$(aws iam list-attached-role-policies --role-name "$role_name" --region "$region" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
    
    if [ -n "$attached_policies" ]; then
        for policy_arn in $attached_policies; do
            echo "Detaching policy: $policy_arn"
            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" --region "$region" 2>/dev/null || true
        done
    fi
    
    # List and delete all inline policies
    local inline_policies=$(aws iam list-role-policies --role-name "$role_name" --region "$region" --query 'PolicyNames[]' --output text 2>/dev/null)
    
    if [ -n "$inline_policies" ]; then
        for policy_name in $inline_policies; do
            echo "Deleting inline policy: $policy_name"
            aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" --region "$region" 2>/dev/null || true
        done
    fi
    
    # Now delete the role
    echo "Deleting IAM role: $role_name"
    aws iam delete-role --role-name "$role_name" --region "$region"
}

# When force recreate is enabled, we need to delete resources in the correct order
# 1. Connector (depends on plugin and worker config)
# 2. Worker Configuration 
# 3. Custom Plugin
# 4. IAM Role

if [ "$FORCE_RECREATE" = true ]; then
    echo "Force recreate enabled. Checking resources for deletion in dependency order..."
    
    # Step 1: Delete connector if it exists
    CONNECTOR_NAME="msk-s3-sink-json"
    EXISTING_CONNECTOR_ARN=$(aws kafkaconnect list-connectors --region $REGION --query "connectors[?connectorName=='$CONNECTOR_NAME'].connectorArn" --output text 2>/dev/null)
    
    if [ -n "$EXISTING_CONNECTOR_ARN" ] && [ "$EXISTING_CONNECTOR_ARN" != "None" ]; then
        echo "Deleting existing connector: $CONNECTOR_NAME"
        if aws kafkaconnect delete-connector --connector-arn "$EXISTING_CONNECTOR_ARN" --region $REGION; then
            echo "Waiting for connector deletion to complete..."
            sleep 30
        else
            handle_error "Failed to delete existing connector: $CONNECTOR_NAME"
        fi
    fi
    
    # Step 2: Delete worker configuration if it exists
    WORKER_CONFIG_NAME="msk-connector-s3-sink-config"
    EXISTING_WORKER_CONFIG_ARN=$(aws kafkaconnect list-worker-configurations --region $REGION --query "workerConfigurations[?name=='$WORKER_CONFIG_NAME'].workerConfigurationArn" --output text 2>/dev/null)
    
    if [ -n "$EXISTING_WORKER_CONFIG_ARN" ] && [ "$EXISTING_WORKER_CONFIG_ARN" != "None" ]; then
        echo "Deleting existing worker configuration: $WORKER_CONFIG_NAME"
        if aws kafkaconnect delete-worker-configuration --worker-configuration-arn "$EXISTING_WORKER_CONFIG_ARN" --region $REGION; then
            echo "Waiting for worker configuration deletion to complete..."
            sleep 10
        else
            handle_error "Failed to delete existing worker configuration: $WORKER_CONFIG_NAME"
        fi
    fi
    
    # Step 3: Delete custom plugin if it exists
    PLUGIN_NAME="msk-s3-sink-plugin"
    EXISTING_PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins --region $REGION --query "customPlugins[?name=='$PLUGIN_NAME'].customPluginArn" --output text 2>/dev/null)
    
    if [ -n "$EXISTING_PLUGIN_ARN" ] && [ "$EXISTING_PLUGIN_ARN" != "None" ]; then
        echo "Deleting existing custom plugin: $PLUGIN_NAME"
        if aws kafkaconnect delete-custom-plugin --custom-plugin-arn "$EXISTING_PLUGIN_ARN" --region $REGION; then
            echo "Waiting for custom plugin deletion to complete..."
            sleep 10
        else
            handle_error "Failed to delete existing custom plugin: $PLUGIN_NAME"
        fi
    fi
    
    # Step 4: Delete IAM role if it exists
    ROLE_NAME="MSKConnectServiceRole-$REGION"
    if aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
        echo "Deleting existing IAM role: $ROLE_NAME"
        delete_iam_role_safely "$ROLE_NAME" "$REGION"
        echo "Waiting for IAM role deletion to complete..."
        sleep 10
    fi
    
    echo "Force deletion completed. Proceeding with resource creation..."
fi

# Create CloudWatch Log Group if it doesn't exist
echo "Creating CloudWatch log group..."
aws logs create-log-group --log-group-name msk-connector-log --region $REGION 2>/dev/null || echo "Log group already exists"

# Create IAM role for MSK Connect
ROLE_NAME="MSKConnectServiceRole-$REGION"
echo "Managing IAM role for MSK Connect..."

if ! aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "Creating IAM role: $ROLE_NAME"
    
    # Create trust policy
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "kafkaconnect.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # Create role
    if aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json --region $REGION; then
        # Attach policies
        aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonMSKFullAccess --region $REGION
        aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess --region $REGION
        aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --region $REGION
        
        echo "Waiting for role to be available..."
        sleep 10
    else
        handle_error "Failed to create IAM role: $ROLE_NAME"
    fi

    # Clean up temp file
    rm trust-policy.json
else
    echo "IAM role '$ROLE_NAME' already exists"
fi

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $REGION)
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

# Download and create custom plugin for S3
PLUGIN_NAME="msk-s3-sink-plugin"
PLUGIN_S3_KEY="plugins/confluentinc-kafka-connect-s3-10.6.7.zip"
PLUGIN_ARN="arn:aws:kafkaconnect:$REGION:$ACCOUNT_ID:custom-plugin/$PLUGIN_NAME"

echo "Managing S3 custom plugin..."

# Check if plugin exists
PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins --region $REGION --query "customPlugins[?name=='$PLUGIN_NAME'].customPluginArn" --output text 2>/dev/null)

if [ -z "$PLUGIN_ARN" ] || [ "$PLUGIN_ARN" = "None" ]; then
    echo "Creating custom plugin: $PLUGIN_NAME"
    
    # Download plugin if not exists in S3
    if ! aws s3 ls s3://$S3_BUCKET/$PLUGIN_S3_KEY --region $REGION >/dev/null 2>&1; then
        echo "Downloading S3 plugin..."
        wget -O confluentinc-kafka-connect-s3-10.6.7.zip https://hub-downloads.confluent.io/api/plugins/confluentinc/kafka-connect-s3/versions/10.6.7/confluentinc-kafka-connect-s3-10.6.7.zip
        aws s3 cp confluentinc-kafka-connect-s3-10.6.7.zip s3://$S3_BUCKET/$PLUGIN_S3_KEY --region $REGION
        rm confluentinc-kafka-connect-s3-10.6.7.zip
    fi

    # Create custom plugin
    if aws kafkaconnect create-custom-plugin \
        --name $PLUGIN_NAME \
        --content-type ZIP \
        --location "{\"s3Location\":{\"bucketArn\":\"arn:aws:s3:::$S3_BUCKET\",\"fileKey\":\"$PLUGIN_S3_KEY\"}}" \
        --region $REGION > plugin_create_response.json; then
        
        # Get the actual plugin ARN from the response
        PLUGIN_ARN=$(jq -r '.customPluginArn' plugin_create_response.json)
        echo "Plugin ARN: $PLUGIN_ARN"
        
        echo "Waiting for plugin to be created..."
        
        # Poll for plugin status
        for i in {1..30}; do
            PLUGIN_STATUS=$(aws kafkaconnect describe-custom-plugin --custom-plugin-arn "$PLUGIN_ARN" --region $REGION --query 'customPluginState' --output text 2>/dev/null)
            if [ "$PLUGIN_STATUS" = "ACTIVE" ]; then
                echo "Custom plugin created successfully"
                break
            elif [ "$PLUGIN_STATUS" = "CREATE_FAILED" ]; then
                rm -f plugin_create_response.json
                handle_error "Custom plugin creation failed"
            fi
            echo "Plugin status: $PLUGIN_STATUS, waiting..."
            sleep 10
        done
        
        rm -f plugin_create_response.json
        
        if [ "$PLUGIN_STATUS" != "ACTIVE" ]; then
            handle_error "Custom plugin creation timed out"
        fi
    else
        handle_error "Failed to create custom plugin: $PLUGIN_NAME"
    fi
else
    echo "Custom plugin '$PLUGIN_NAME' already exists"
fi

# Create worker configuration
WORKER_CONFIG_NAME="msk-connector-s3-sink-config"
WORKER_CONFIG_ARN="arn:aws:kafkaconnect:$REGION:$ACCOUNT_ID:worker-configuration/$WORKER_CONFIG_NAME"

echo "Managing worker configuration..."

# Check if worker configuration exists
WORKER_CONFIG_ARN=$(aws kafkaconnect list-worker-configurations --region $REGION --query "workerConfigurations[?name=='$WORKER_CONFIG_NAME'].workerConfigurationArn" --output text 2>/dev/null)

if [ -z "$WORKER_CONFIG_ARN" ] || [ "$WORKER_CONFIG_ARN" = "None" ]; then
    echo "Creating worker configuration: $WORKER_CONFIG_NAME"
    
    # Create worker config content
    cat > worker-config.properties << EOF
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.storage.StringConverter
consumer.auto.offset.reset=earliest
EOF

    # Encode to base64
    WORKER_CONFIG_CONTENT=$(base64 -w 0 worker-config.properties)

    # Create worker configuration
    if aws kafkaconnect create-worker-configuration \
        --name $WORKER_CONFIG_NAME \
        --properties-file-content $WORKER_CONFIG_CONTENT \
        --region $REGION; then
        echo "Worker configuration created successfully"
        # Get the ARN
        WORKER_CONFIG_ARN=$(aws kafkaconnect list-worker-configurations --region $REGION --query "workerConfigurations[?name=='$WORKER_CONFIG_NAME'].workerConfigurationArn" --output text)
    else
        handle_error "Failed to create worker configuration: $WORKER_CONFIG_NAME"
    fi

    rm worker-config.properties
else
    echo "Worker configuration '$WORKER_CONFIG_NAME' already exists"
fi

# Ensure we have the plugin ARN
PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins --region $REGION --query "customPlugins[?name=='$PLUGIN_NAME'].customPluginArn" --output text)
PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins --region $REGION --query "customPlugins[?name=='$PLUGIN_NAME'].customPluginArn" --output text)

# Create connector
CONNECTOR_NAME="msk-s3-sink-json"
CONNECTOR_ARN="arn:aws:kafkaconnect:$REGION:$ACCOUNT_ID:connector/$CONNECTOR_NAME"

echo "Managing S3 JSON connector..."

# Check if connector exists
CONNECTOR_ARN=$(aws kafkaconnect list-connectors --region $REGION --query "connectors[?connectorName=='$CONNECTOR_NAME'].connectorArn" --output text 2>/dev/null)

if [ -z "$CONNECTOR_ARN" ] || [ "$CONNECTOR_ARN" = "None" ]; then
    echo "Creating S3 JSON connector: $CONNECTOR_NAME"
    
    # Create connector configuration based on partition-time-col parameter
    if [ "$PARTITION_TIME_COL" = "kafka_time" ]; then
        # For kafka_time: use Record timestamp extractor without timestamp.field
        cat > connector-config.json << EOF
{
    "connectorName": "$CONNECTOR_NAME",
    "kafkaCluster": {
        "apacheKafkaCluster": {
            "bootstrapServers": "$MSK_BOOTSTRAP_SERVERS",
            "vpc": {
                "securityGroups": $SG_JSON,
                "subnets": $SUBNET_JSON
            }
        }
    },
    "kafkaClusterClientAuthentication": {
        "authenticationType": "NONE"
    },
    "kafkaClusterEncryptionInTransit": {
        "encryptionType": "PLAINTEXT"
    },
    "kafkaConnectVersion": "3.7.x",
    "serviceExecutionRoleArn": "$ROLE_ARN",
    "plugins": [
        {
            "customPlugin": {
                "customPluginArn": "$PLUGIN_ARN",
                "revision": 1
            }
        }
    ],
    "workerConfiguration": {
        "workerConfigurationArn": "$WORKER_CONFIG_ARN",
        "revision": 1
    },
    "capacity": {
        "provisionedCapacity": {
            "mcuCount": $MCU_COUNT,
            "workerCount": $WORKER_COUNT
        }
    },
    "connectorConfiguration": {
        "connector.class": "io.confluent.connect.s3.S3SinkConnector",
        "s3.region": "$REGION",
        "topics.dir": "app-logs-json-data-v1",
        "flush.size": "60000",
        "tasks.max": "3",
        "timezone": "America/New_York",
        "rotate.interval.ms": "120000",
        "locale": "zh_CN",
        "format.class": "io.confluent.connect.s3.format.json.JsonFormat",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "errors.log.enable": "true",
        "s3.bucket.name": "$S3_BUCKET",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "partition.duration.ms": "86400000",
        "schema.compatibility": "NONE",
        "file.delim": "-",
        "topics": "$TOPIC_NAME",
        "s3.compression.type": "gzip",
        "partitioner.class": "io.confluent.connect.storage.partitioner.TimeBasedPartitioner",
        "value.converter.schemas.enable": "false",
        "storage.class": "io.confluent.connect.s3.storage.S3Storage",
        "path.format": "YYYYMMdd",
        "timestamp.extractor": "Record"
    },
    "logDelivery": {
        "workerLogDelivery": {
            "cloudWatchLogs": {
                "enabled": true,
                "logGroup": "msk-connector-log"
            }
        }
    }
}
EOF
    else
        # For ingestion_time: use RecordField timestamp extractor with timestamp.field
        cat > connector-config.json << EOF
{
    "connectorName": "$CONNECTOR_NAME",
    "kafkaCluster": {
        "apacheKafkaCluster": {
            "bootstrapServers": "$MSK_BOOTSTRAP_SERVERS",
            "vpc": {
                "securityGroups": $SG_JSON,
                "subnets": $SUBNET_JSON
            }
        }
    },
    "kafkaClusterClientAuthentication": {
        "authenticationType": "NONE"
    },
    "kafkaClusterEncryptionInTransit": {
        "encryptionType": "PLAINTEXT"
    },
    "kafkaConnectVersion": "3.7.x",
    "serviceExecutionRoleArn": "$ROLE_ARN",
    "plugins": [
        {
            "customPlugin": {
                "customPluginArn": "$PLUGIN_ARN",
                "revision": 1
            }
        }
    ],
    "workerConfiguration": {
        "workerConfigurationArn": "$WORKER_CONFIG_ARN",
        "revision": 1
    },
    "capacity": {
        "provisionedCapacity": {
            "mcuCount": $MCU_COUNT,
            "workerCount": $WORKER_COUNT
        }
    },
    "connectorConfiguration": {
        "connector.class": "io.confluent.connect.s3.S3SinkConnector",
        "s3.region": "$REGION",
        "topics.dir": "app-logs-json-data-v1",
        "flush.size": "60000",
        "tasks.max": "3",
        "timezone": "America/New_York",
        "rotate.interval.ms": "120000",
        "locale": "zh_CN",
        "format.class": "io.confluent.connect.s3.format.json.JsonFormat",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "errors.log.enable": "true",
        "s3.bucket.name": "$S3_BUCKET",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "partition.duration.ms": "86400000",
        "schema.compatibility": "NONE",
        "file.delim": "-",
        "topics": "$TOPIC_NAME",
        "s3.compression.type": "gzip",
        "partitioner.class": "io.confluent.connect.storage.partitioner.TimeBasedPartitioner",
        "value.converter.schemas.enable": "false",
        "storage.class": "io.confluent.connect.s3.storage.S3Storage",
        "path.format": "YYYYMMdd",
        "timestamp.extractor": "RecordField",
        "timestamp.field": "meta.ctime"
    },
    "logDelivery": {
        "workerLogDelivery": {
            "cloudWatchLogs": {
                "enabled": true,
                "logGroup": "msk-connector-log"
            }
        }
    }
}
EOF
    fi

    # Create the connector
    if aws kafkaconnect create-connector --cli-input-json file://connector-config.json --region $REGION; then
        echo "Connector creation initiated successfully"
        # Get the connector ARN
        sleep 5  # Wait a moment for the connector to be listed
        CONNECTOR_ARN=$(aws kafkaconnect list-connectors --region "$REGION" --query "connectors[?connectorName=='$CONNECTOR_NAME'].connectorArn" --output text 2>/dev/null || echo "")
        EXECUTION_STATUS="SUCCESS"
    else
        handle_error "Failed to create connector: $CONNECTOR_NAME"
    fi

    # Clean up
    rm connector-config.json
else
    echo "Connector '$CONNECTOR_NAME' already exists"
    EXECUTION_STATUS="SUCCESS"
fi

# Generate information file
generate_info_file

echo ""
echo "=== MSK S3 JSON Connector Creation Complete ==="
echo "Execution Status: $EXECUTION_STATUS"
echo "Connector Name: ${CONNECTOR_NAME:-msk-s3-sink-json}"
echo "Connector ARN: ${CONNECTOR_ARN:-Not available}"
echo "Plugin S3 Location: s3://$S3_BUCKET/${PLUGIN_S3_KEY:-plugins/confluentinc-kafka-connect-s3-10.6.7.zip}"
echo "Worker Count: ${WORKER_COUNT:-6}"
echo "MCU Count: ${MCU_COUNT:-1}"
echo "Partition Time Column: ${PARTITION_TIME_COL:-ingestion_time}"
echo "Data Location: s3://$S3_BUCKET/app-logs-json/"
echo "Format: JSON (gzipped)"
echo ""
echo "Check the AWS console for connector status."
echo "================================================"
