#!/bin/bash

# MSK Iceberg Sink Connector Creation Script
# Usage: ./create-iceberg-connector.sh <region> <s3-bucket> <msk-cluster-name> [glue-database] [topic-name]

set -e

# Check if required parameters are provided
if [ $# -lt 3 ]; then
    echo "Usage: $0 <region> <s3-bucket> <msk-cluster-name> [glue-database] [topic-name]"
    echo "Example: $0 ap-southeast-1 pcd-01 my-msk-cluster iceberg_db app_logs"
    exit 1
fi

REGION=$1
S3_BUCKET=$2
MSK_CLUSTER_NAME=$3
GLUE_DATABASE=${4:-iceberg_db}
TOPIC_NAME=${5:-app_logs}

echo "Creating MSK Iceberg Sink Connector in region: $REGION"
echo "S3 Bucket: $S3_BUCKET"
echo "MSK Cluster Name: $MSK_CLUSTER_NAME"
echo "Glue Database: $GLUE_DATABASE"
echo "Topic: $TOPIC_NAME"

# Get MSK cluster information
echo "Getting MSK cluster information..."
MSK_CLUSTER_ARN=$(aws kafka list-clusters --region $REGION --query "ClusterInfoList[?ClusterName=='$MSK_CLUSTER_NAME'].ClusterArn" --output text)

if [ -z "$MSK_CLUSTER_ARN" ]; then
    echo "Error: MSK cluster '$MSK_CLUSTER_NAME' not found in region $REGION"
    exit 1
fi

MSK_CLUSTER_INFO=$(aws kafka describe-cluster --cluster-arn $MSK_CLUSTER_ARN --region $REGION)

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

# Create CloudWatch Log Group if it doesn't exist
echo "Creating CloudWatch log group..."
aws logs create-log-group --log-group-name msk-connector-log --region $REGION 2>/dev/null || echo "Log group already exists"

# Create Glue database if it doesn't exist
echo "Creating Glue database: $GLUE_DATABASE"
aws glue create-database --database-input "{\"Name\":\"$GLUE_DATABASE\"}" --region $REGION 2>/dev/null || echo "Database already exists"

# Create IAM role for MSK Connect
echo "Creating IAM role for MSK Connect..."
ROLE_NAME="MSKConnectServiceRole-$REGION"

# Check if role exists
if ! aws iam get-role --role-name $ROLE_NAME --region $REGION >/dev/null 2>&1; then
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
    aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json --region $REGION

    # Attach policies
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonMSKFullAccess --region $REGION
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess --region $REGION
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess --region $REGION

    # Clean up temp file
    rm trust-policy.json

    echo "Waiting for role to be available..."
    sleep 10
else
    echo "Role $ROLE_NAME already exists"
fi

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $REGION)
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

# Download and create custom plugin for Iceberg
echo "Creating Iceberg custom plugin..."
PLUGIN_NAME="msk-iceberg-sink-plugin"
PLUGIN_S3_KEY="plugins/iceberg-kafka-connect-runtime-0.6.19.zip"

# Check if plugin already exists
if ! aws kafkaconnect list-custom-plugins --region $REGION --query "customPlugins[?name=='$PLUGIN_NAME']" --output text | grep -q "$PLUGIN_NAME"; then
    # Download plugin if not exists in S3
    if ! aws s3 ls s3://$S3_BUCKET/$PLUGIN_S3_KEY --region $REGION >/dev/null 2>&1; then
        echo "Downloading Iceberg plugin..."
        wget -O iceberg-kafka-connect-runtime-0.6.19.zip https://github.com/databricks/iceberg-kafka-connect/releases/download/v0.6.19/iceberg-kafka-connect-runtime-0.6.19.zip
        aws s3 cp iceberg-kafka-connect-runtime-0.6.19.zip s3://$S3_BUCKET/$PLUGIN_S3_KEY --region $REGION
        rm iceberg-kafka-connect-runtime-0.6.19.zip
    fi

    # Create custom plugin
    echo "Creating custom plugin: $PLUGIN_NAME"
    aws kafkaconnect create-custom-plugin \
        --name $PLUGIN_NAME \
        --content-type ZIP \
        --location "{\"s3Location\":{\"bucketArn\":\"arn:aws:s3:::$S3_BUCKET\",\"fileKey\":\"$PLUGIN_S3_KEY\"}}" \
        --region $REGION

    echo "Waiting for plugin to be created..."
    PLUGIN_ARN="arn:aws:kafkaconnect:$REGION:$ACCOUNT_ID:custom-plugin/$PLUGIN_NAME"
    aws kafkaconnect wait custom-plugin-active --custom-plugin-arn "$PLUGIN_ARN" --region $REGION
else
    echo "Plugin $PLUGIN_NAME already exists"
fi

# Create worker configuration
echo "Creating worker configuration..."
WORKER_CONFIG_NAME="sink-iceberg-worker-conf"

# Check if worker config exists
if ! aws kafkaconnect list-worker-configurations --region $REGION --query "workerConfigurations[?name=='$WORKER_CONFIG_NAME']" --output text | grep -q "$WORKER_CONFIG_NAME"; then
    # Create worker config content
    cat > worker-config.properties << EOF
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
value.converter.schemas.enable=false
key.converter.schemas.enable=false
consumer.auto.offset.reset=earliest
EOF

    # Encode to base64
    WORKER_CONFIG_CONTENT=$(base64 -w 0 worker-config.properties)

    # Create worker configuration
    aws kafkaconnect create-worker-configuration \
        --name $WORKER_CONFIG_NAME \
        --properties-file-content $WORKER_CONFIG_CONTENT \
        --region $REGION

    rm worker-config.properties
else
    echo "Worker configuration $WORKER_CONFIG_NAME already exists"
fi

# Get the actual worker configuration ARN
WORKER_CONFIG_ARN=$(aws kafkaconnect list-worker-configurations --region $REGION --query "workerConfigurations[?name=='$WORKER_CONFIG_NAME'].workerConfigurationArn" --output text)

# Get the actual plugin ARN
PLUGIN_ARN=$(aws kafkaconnect list-custom-plugins --region $REGION --query "customPlugins[?name=='$PLUGIN_NAME'].customPluginArn" --output text)

# Create connector
echo "Creating Iceberg connector..."
CONNECTOR_NAME="msk-s3-sink-iceberg"

# Create connector configuration
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
            "mcuCount": 1,
            "workerCount": 6
        }
    },
    "connectorConfiguration": {
        "connector.class": "io.tabular.iceberg.connect.IcebergSinkConnector",
        "iceberg.tables.evolve-schema-enabled": "true",
        "transforms.timestampConverter.unix.precision": "milliseconds",
        "iceberg.catalog.catalog-impl": "org.apache.iceberg.aws.glue.GlueCatalog",
        "transforms.flatten.type": "org.apache.kafka.connect.transforms.Flatten\$Value",
        "iceberg.tables.default-partition-by": "day(meta_ctime)",
        "tasks.max": "3",
        "topics": "$TOPIC_NAME",
        "iceberg.catalog.io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
        "transforms": "flatten,timestampConverter",
        "iceberg.catalog.client.region": "$REGION",
        "iceberg.control.commit.interval-ms": "120000",
        "transforms.flatten.delimiter": "_",
        "iceberg.tables.auto-create-enabled": "true",
        "transforms.timestampConverter.type": "org.apache.kafka.connect.transforms.TimestampConverter\$Value",
        "transforms.timestampConverter.target.type": "Timestamp",
        "write.metadata.previous-versions-max": "1",
        "iceberg.tables": "$GLUE_DATABASE.$TOPIC_NAME",
        "transforms.timestampConverter.field": "meta_ctime",
        "iceberg.catalog.warehouse": "s3://$S3_BUCKET/app-logs-data-v1/",
        "iceberg.control.topic": "control-iceberg",
        "iceberg.catalog.s3.path-style-access": "true"
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

# Create the connector
aws kafkaconnect create-connector --cli-input-json file://connector-config.json --region $REGION

# Clean up
rm connector-config.json

echo "Iceberg connector creation initiated. Check the AWS console for status."
echo "Connector ARN: arn:aws:kafkaconnect:$REGION:$ACCOUNT_ID:connector/$CONNECTOR_NAME"
