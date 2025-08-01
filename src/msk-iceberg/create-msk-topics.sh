#!/bin/bash

# MSK Topic Creation Script using Docker
# This script creates MSK topics using Kafka tools in a Docker container

set -e

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_APP_TOPIC="app_logs"
DEFAULT_CONTROL_TOPIC="control-iceberg"
DEFAULT_APP_PARTITIONS=18
DEFAULT_CONTROL_PARTITIONS=25
DEFAULT_REPLICATION_FACTOR=3
FORCE_RECREATE=false

# Function to show help
show_help() {
    cat << EOF
MSK Topic Creation Script (Docker-based)

USAGE:
    $0 [OPTIONS] --cluster-name <msk-cluster-name>
    $0 [OPTIONS] --bootstrap-servers <msk-bootstrap-servers>

REQUIRED PARAMETERS (choose one):
    --cluster-name NAME             MSK cluster name (will auto-discover bootstrap servers)
    --bootstrap-servers SERVERS    MSK cluster bootstrap servers (comma-separated)
                                   Example: broker1:9092,broker2:9092,broker3:9092

OPTIONS:
    -r, --region REGION              AWS region (default: $DEFAULT_REGION)
    -a, --app-topic TOPIC           Application topic name (default: $DEFAULT_APP_TOPIC)
    -c, --control-topic TOPIC       Control topic name (default: $DEFAULT_CONTROL_TOPIC)
    -p, --app-partitions COUNT      Application topic partitions (default: $DEFAULT_APP_PARTITIONS)
    -P, --control-partitions COUNT  Control topic partitions (default: $DEFAULT_CONTROL_PARTITIONS)
    -R, --replication-factor COUNT  Replication factor (default: $DEFAULT_REPLICATION_FACTOR)
    -f, --force                     Force recreate existing topics
    -h, --help                      Show this help message

EXAMPLES:
    $0 --cluster-name my-msk-cluster
    $0 --cluster-name my-cluster --app-topic logs --control-topic iceberg-control
    $0 --bootstrap-servers broker1:9092,broker2:9092,broker3:9092
    $0 --force --app-partitions 12 --cluster-name my-cluster

DESCRIPTION:
    This script creates two topics required for MSK connectors:
    1. Application topic: For clickstream data (default: app_logs)
    2. Control topic: For Iceberg connector offset storage (default: control-iceberg)

    The script uses the official Kafka Docker image to run topic creation commands,
    eliminating the need to install Kafka tools locally.

    When using --cluster-name, the script will automatically discover the bootstrap
    servers using AWS CLI. If --bootstrap-servers is provided, it takes precedence.

OUTPUT:
    Creates an info file: msk-topics-info.json with topic details
EOF
}

# Parse command line arguments
CLUSTER_NAME=""
BOOTSTRAP_SERVERS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --bootstrap-servers)
            BOOTSTRAP_SERVERS="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -a|--app-topic)
            APP_TOPIC="$2"
            shift 2
            ;;
        -c|--control-topic)
            CONTROL_TOPIC="$2"
            shift 2
            ;;
        -p|--app-partitions)
            APP_PARTITIONS="$2"
            shift 2
            ;;
        -P|--control-partitions)
            CONTROL_PARTITIONS="$2"
            shift 2
            ;;
        -R|--replication-factor)
            REPLICATION_FACTOR="$2"
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
            echo "Unknown parameter $1"
            show_help
            exit 1
            ;;
    esac
done

# Set defaults if not provided
REGION=${REGION:-$DEFAULT_REGION}
APP_TOPIC=${APP_TOPIC:-$DEFAULT_APP_TOPIC}
CONTROL_TOPIC=${CONTROL_TOPIC:-$DEFAULT_CONTROL_TOPIC}
APP_PARTITIONS=${APP_PARTITIONS:-$DEFAULT_APP_PARTITIONS}
CONTROL_PARTITIONS=${CONTROL_PARTITIONS:-$DEFAULT_CONTROL_PARTITIONS}
REPLICATION_FACTOR=${REPLICATION_FACTOR:-$DEFAULT_REPLICATION_FACTOR}

# Function to get bootstrap servers from cluster name
get_bootstrap_servers() {
    local cluster_name="$1"
    local region="$2"
    
    echo "Getting bootstrap servers for cluster: $cluster_name in region: $region" >&2
    
    # First, get the cluster ARN
    local cluster_arn=$(aws kafka list-clusters \
        --region "$region" \
        --query "ClusterInfoList[?ClusterName=='$cluster_name'].ClusterArn" \
        --output text 2>/dev/null)
    
    if [ -z "$cluster_arn" ] || [ "$cluster_arn" = "None" ]; then
        echo "Error: MSK cluster '$cluster_name' not found in region '$region'" >&2
        echo "Available clusters:" >&2
        aws kafka list-clusters --region "$region" --query "ClusterInfoList[].ClusterName" --output table 2>/dev/null || echo "Failed to list clusters" >&2
        exit 1
    fi
    
    echo "Found cluster ARN: $cluster_arn" >&2
    
    # Get bootstrap servers
    local bootstrap_servers=$(aws kafka get-bootstrap-brokers \
        --region "$region" \
        --cluster-arn "$cluster_arn" \
        --query "BootstrapBrokerString" \
        --output text 2>/dev/null)
    
    if [ -z "$bootstrap_servers" ] || [ "$bootstrap_servers" = "None" ]; then
        echo "Error: Failed to get bootstrap servers for cluster '$cluster_name'" >&2
        exit 1
    fi
    
    echo "Bootstrap servers: $bootstrap_servers" >&2
    echo "$bootstrap_servers"
}

# Check required parameters and get bootstrap servers
if [ -n "$BOOTSTRAP_SERVERS" ]; then
    echo "Using provided bootstrap servers: $BOOTSTRAP_SERVERS"
elif [ -n "$CLUSTER_NAME" ]; then
    echo "Getting bootstrap servers from cluster name: $CLUSTER_NAME"
    BOOTSTRAP_SERVERS=$(get_bootstrap_servers "$CLUSTER_NAME" "$REGION")
else
    echo "Error: Either --cluster-name or --bootstrap-servers must be provided"
    show_help
    exit 1
fi

echo "=== MSK Topic Creation ==="
echo "Region: $REGION"
if [ -n "$CLUSTER_NAME" ]; then
    echo "Cluster Name: $CLUSTER_NAME"
fi
echo "Bootstrap Servers: $BOOTSTRAP_SERVERS"
echo "Application Topic: $APP_TOPIC (partitions: $APP_PARTITIONS)"
echo "Control Topic: $CONTROL_TOPIC (partitions: $CONTROL_PARTITIONS)"
echo "Replication Factor: $REPLICATION_FACTOR"
echo "Force Recreate: $FORCE_RECREATE"
echo "=========================="

# Function to check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker is not installed or not in PATH"
        echo "Please install Docker to use this script"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        echo "Error: Docker daemon is not running"
        echo "Please start Docker daemon"
        exit 1
    fi
}

# Function to run Kafka command in Docker
run_kafka_command() {
    local command="$1"
    echo "Running: $command"
    docker run --rm confluentinc/cp-kafka:latest $command
}

# Function to check if topic exists
topic_exists() {
    local topic_name="$1"
    local result=$(docker run --rm confluentinc/cp-kafka:latest \
        kafka-topics --bootstrap-server "$BOOTSTRAP_SERVERS" \
        --list 2>/dev/null | grep "^${topic_name}$" || true)
    [ -n "$result" ]
}

# Function to delete topic
delete_topic() {
    local topic_name="$1"
    echo "Deleting topic: $topic_name"
    docker run --rm confluentinc/cp-kafka:latest \
        kafka-topics --bootstrap-server "$BOOTSTRAP_SERVERS" \
        --delete --topic "$topic_name"
}

# Function to create topic
create_topic() {
    local topic_name="$1"
    local partitions="$2"
    local replication_factor="$3"
    
    echo "Creating topic: $topic_name"
    docker run --rm confluentinc/cp-kafka:latest \
        kafka-topics --bootstrap-server "$BOOTSTRAP_SERVERS" \
        --create --topic "$topic_name" \
        --partitions "$partitions" \
        --replication-factor "$replication_factor"
}

# Function to get topic details
get_topic_details() {
    local topic_name="$1"
    docker run --rm confluentinc/cp-kafka:latest \
        kafka-topics --bootstrap-server "$BOOTSTRAP_SERVERS" \
        --describe --topic "$topic_name" 2>/dev/null || echo "Topic not found"
}

# Check Docker availability
check_docker

echo "Pulling Kafka Docker image..."
docker pull confluentinc/cp-kafka:latest

# Handle application topic
echo ""
echo "=== Managing Application Topic: $APP_TOPIC ==="
if topic_exists "$APP_TOPIC"; then
    echo "Topic '$APP_TOPIC' already exists"
    if [ "$FORCE_RECREATE" = true ]; then
        echo "Force recreate enabled. Deleting existing topic..."
        delete_topic "$APP_TOPIC"
        sleep 5
        create_topic "$APP_TOPIC" "$APP_PARTITIONS" "$REPLICATION_FACTOR"
    else
        echo "Skipping creation (use --force to recreate)"
    fi
else
    echo "Topic '$APP_TOPIC' does not exist"
    create_topic "$APP_TOPIC" "$APP_PARTITIONS" "$REPLICATION_FACTOR"
fi

# Handle control topic
echo ""
echo "=== Managing Control Topic: $CONTROL_TOPIC ==="
if topic_exists "$CONTROL_TOPIC"; then
    echo "Topic '$CONTROL_TOPIC' already exists"
    if [ "$FORCE_RECREATE" = true ]; then
        echo "Force recreate enabled. Deleting existing topic..."
        delete_topic "$CONTROL_TOPIC"
        sleep 5
        create_topic "$CONTROL_TOPIC" "$CONTROL_PARTITIONS" "$REPLICATION_FACTOR"
    else
        echo "Skipping creation (use --force to recreate)"
    fi
else
    echo "Topic '$CONTROL_TOPIC' does not exist"
    create_topic "$CONTROL_TOPIC" "$CONTROL_PARTITIONS" "$REPLICATION_FACTOR"
fi

# Verify topics were created
echo ""
echo "=== Verifying Topics ==="
echo "Application Topic Details:"
get_topic_details "$APP_TOPIC"
echo ""
echo "Control Topic Details:"
get_topic_details "$CONTROL_TOPIC"

# List all topics to confirm
echo ""
echo "All topics in cluster:"
docker run --rm confluentinc/cp-kafka:latest \
    kafka-topics --bootstrap-server "$BOOTSTRAP_SERVERS" --list

# Create information file
INFO_FILE="msk-topics-info.json"
echo ""
echo "Creating information file: $INFO_FILE"

# Get detailed topic information for JSON
APP_TOPIC_DETAILS=$(get_topic_details "$APP_TOPIC" | grep -E "Topic:|PartitionCount:|ReplicationFactor:" | head -3)
CONTROL_TOPIC_DETAILS=$(get_topic_details "$CONTROL_TOPIC" | grep -E "Topic:|PartitionCount:|ReplicationFactor:" | head -3)

cat > $INFO_FILE << EOF
{
    "topic_creation_info": {
        "creation_time": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
        "region": "$REGION",
        "cluster_name": "${CLUSTER_NAME:-"N/A"}",
        "bootstrap_servers": "$BOOTSTRAP_SERVERS",
        "force_recreate": $FORCE_RECREATE
    },
    "application_topic": {
        "name": "$APP_TOPIC",
        "partitions": $APP_PARTITIONS,
        "replication_factor": $REPLICATION_FACTOR,
        "purpose": "Clickstream data storage",
        "created": $(topic_exists "$APP_TOPIC" && echo "true" || echo "false")
    },
    "control_topic": {
        "name": "$CONTROL_TOPIC",
        "partitions": $CONTROL_PARTITIONS,
        "replication_factor": $REPLICATION_FACTOR,
        "purpose": "Iceberg connector offset storage",
        "created": $(topic_exists "$CONTROL_TOPIC" && echo "true" || echo "false")
    },
    "docker_info": {
        "image_used": "confluentinc/cp-kafka:latest",
        "commands_executed": [
            "kafka-topics --create --topic $APP_TOPIC --partitions $APP_PARTITIONS --replication-factor $REPLICATION_FACTOR",
            "kafka-topics --create --topic $CONTROL_TOPIC --partitions $CONTROL_PARTITIONS --replication-factor $REPLICATION_FACTOR"
        ]
    },
    "usage_notes": {
        "app_topic_usage": "This topic receives clickstream data from applications",
        "control_topic_usage": "This topic is used by Iceberg connector for offset management",
        "verification_command": "docker run --rm confluentinc/cp-kafka:latest kafka-topics --bootstrap-server $BOOTSTRAP_SERVERS --list"
    }
}
EOF

echo ""
echo "=== MSK Topic Creation Complete ==="
echo "Application Topic: $APP_TOPIC ($APP_PARTITIONS partitions)"
echo "Control Topic: $CONTROL_TOPIC ($CONTROL_PARTITIONS partitions)"
echo "Replication Factor: $REPLICATION_FACTOR"
if [ -n "$CLUSTER_NAME" ]; then
    echo "Cluster Name: $CLUSTER_NAME"
fi
echo "Bootstrap Servers: $BOOTSTRAP_SERVERS"
echo ""
echo "Information file created: $INFO_FILE"
echo ""
echo "To verify topics later, run:"
echo "docker run --rm confluentinc/cp-kafka:latest kafka-topics --bootstrap-server $BOOTSTRAP_SERVERS --list"
echo "========================================"
