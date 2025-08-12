# Clickstream Lakehouse 点击流数据湖解决方案

这是一个基于AWS服务构建的完整点击流数据湖解决方案，支持实时数据采集、流式处理和数据湖存储。项目提供两种不同的部署方案以满足不同的性能和功能需求。

## 架构概览
### 架构图
![architecture_image](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508031833878.png)

### 方案一：NLB + Nginx + Fluent Bit (高性能方案)
```
用户请求 -> NLB -> ECS (Nginx + Fluent Bit) -> MSK -> MSK Connector -> Iceberg/S3
```

### 方案二：ALB + Nginx + Vector (功能丰富方案)
```
用户请求 -> ALB -> ECS (Nginx + Vector) -> MSK -> MSK Connector -> Iceberg/S3
```

### 方案对比

| 特性 | NLB + Nginx + Fluent Bit | ALB + Nginx + Vector |
|------|---------------------------|----------------------|
| **负载均衡器类型** | 网络负载均衡器 (Layer 4) | 应用负载均衡器 (Layer 7) |
| **性能** | 更高性能，更低延迟 | 差距不大 |
| **成本** | 相对较低 | 一般 |
| **MSK(kafka)宕机后的容灾** | NGINX日志限制单条数据不能超过4KB，超过会截断，宕机后写EBS,Fluent Bit发送到S3 | 宕机后Vector会一直写EBS buffer，MSK恢复后，Vector继续将EBS积压数据发送到kafka|

* 关于MSK宕机容灾的说明

```markdown
1. 如果kafa宕机对于nginx+lua方案，ECS重新部署一下设定ECS环境变量SEND_S3_ONLY=enable, 这样数据就直接写到磁盘由fluent-bit发送到kafka.  之所以不在error_handle中控制，因为异步发送kafka如果遇到kafka宕机，还是要不断请求metadata，看kafka是否ready, 这会影响写入性能，因为请求metadata要经过socket_timeout超时时间，这个超时间即便设置的再短每条数据都会发一次请求看metadata是否ok, kafka是否恢复，降低写入性能。所以通过这个参数控制，如果kafka宕机，直接写入数据，ECS更新这个参数部署即可，从kafka宕机到重新部署ECS这段时间会有部分数据丢失。特别说明，要想做到数据完全不丢失，就不要走任何的网络直连kafka的方案，因为基本都会存在上述问题，只能数据先落磁盘，然后通过服务采集磁盘数据到kafka, 保证磁盘空间足够大，防止kafka宕机磁盘被打满。这个链路会有更大延迟和维护成本，可以做个综合考量。还有另一种方式是，两个kafka集群双活，如果一个故障可以重新滚动部署下ECS写入到新集群，也可以通过route53配置反向地址解析，可以做到不用重新部署ecs,但因为在route53做切换过程，也会有不可用的时间，所以也不可能保证一条数据不丢失，但可以做基本不丢。
2. 如果保证数据尽可能在Kafka宕机情况下不丢失，有如下四种方式， 当时用的B方式，如果单条数据大于4KB请使用A方式。 这个4KB只是写日志的限制，对于正常lua写kafka没有这个大小限制。
3. 方案有如下四种，D就是本项目的，alb+nginx+vector方案。请自行考虑数据容灾的要求选择
A. kafka 双活，一个宕机后，切换到另一个kafka集群，切换过程可能会有部分数据丢失，成本会高点。
B. kafka宕机后，通过下面代码，写数据到本地盘，然后由sidecar fluent-bit上传到s3, 宕机后滚动部署ECS期间，数据可能会有丢失。且因为nginx的log有4KB大小限制，所以超过4KB的log就会被截断，需要配置一个大的磁盘防止宕机，磁盘写满。
C. 不使用当前方式写kafka, 数据先写磁盘，所有数据通过fluent-bit上传到s3，只要磁盘不故障，基本不会丢数据。需要配置一个大的磁盘防止kafka宕机，磁盘写满
D. 使用nginx+vector http ,vector支持数据先缓存在磁盘，如果kafka宕机，数据写磁盘，恢复了之后再发送, 依然。需要配置一个大的磁盘防止kafka宕机，磁盘写满
```


### 数据链路说明

1. **负载均衡器**: 接收用户的点击流请求
   - **NLB**: 网络负载均衡器，提供高性能的Layer 4负载均衡
   - **ALB**: 应用负载均衡器，提供丰富的Layer 7功能
2. **ECS (Elastic Container Service)**: 运行数据处理容器
   - **Nginx**: Web服务器，接收和预处理HTTP请求
   - **Fluent Bit**: 轻量级日志处理器，高性能数据转发
   - **Vector**: 现代化数据管道工具，提供更丰富的数据处理功能
3. **MSK (Managed Streaming for Apache Kafka)**: 作为消息队列缓冲数据
4. **MSK Connector**: 将Kafka数据写入到数据湖
5. **Iceberg/S3**: 最终的数据湖存储

## 项目结构

```
clickstream-lakehouse/
├── deploy-all.sh                           # 通用部署脚本入口
├── deploy-nlb-nginx-lua-msk-all.sh        # NLB方案统一部署脚本
├── deploy-alb-nginx-vector-msk-all.sh     # ALB方案统一部署脚本
├── test-nlb-data-flow.sh                  # NLB方案数据流测试脚本
├── test-alb-data-flow.sh                  # ALB方案数据流测试脚本
├── example-deploy.sh                      # 部署示例脚本
├── README.md                              # 本文档
├── prompt.md                              # 项目需求说明
└── src/
    ├── ingestion/                         # 数据采集组件
    │   ├── nlb-nginx-lua/                # NLB + Nginx + Fluent Bit 方案
    │   │   ├── docker/                   # Docker镜像构建
    │   │   ├── ecs/                      # ECS服务部署
    │   │   └── nlb/                      # 网络负载均衡器部署
    │   └── alb-nginx-vector/             # ALB + Nginx + Vector 方案
    │       ├── docker/                   # Docker镜像构建
    │       ├── ecs/                      # ECS服务部署
    │       ├── alb/                      # 应用负载均衡器部署
    │       └── tmp/                      # 临时文件和部署信息
    └── msk-iceberg/                      # MSK和Iceberg连接器
        ├── create-msk-topics.sh          # 创建MSK主题
        ├── create-s3-iceberg-connector-optimized.sh  # Iceberg连接器
        └── create-s3-json-connector-optimized.sh     # S3连接器
```

## 前置条件

### AWS服务要求

1. **AWS CLI** 已配置并具有以下权限：
   - ECS: 创建集群、服务、任务定义
   - ECR: 创建仓库、推送镜像
   - IAM: 创建角色和策略
   - VPC: 访问子网、安全组
   - S3: 创建和管理存储桶
   - MSK: 管理Kafka集群和连接器
   - CloudWatch: 创建日志组
   - Glue: 管理数据目录
   - ELB: 创建和管理负载均衡器

2. **Docker** 已安装并运行

3. **已创建的AWS资源**：
   - VPC和公有和私有子网（本项目vpc最佳实践，VPC需要有 公有子网(三AZ)+私有子网(三AZ)+NAT+S3 Gateway Endpoint, 除了ALB和NLB部署在公有子网，其它服务都会自动在私有子网创建，MSK集群你需要自己创建，创建的时候请选择私有子网， 开放9092 PLAINTEXT访问）
   - MSK集群（已运行状态，请选择私有子网）
   - S3存储桶（用于数据存储）

### 本地环境

- Linux/macOS 环境
- Bash shell
- 网络连接到AWS

## 快速开始

### 1. 选择部署方案

项目提供统一的部署入口，支持两种方案：

```bash
# 使用 NLB + Nginx + Fluent Bit 方案（高性能）
./deploy-all.sh nlb -b my-clickstream-bucket -m my-msk-cluster

# 使用 ALB + Nginx + Vector 方案（功能丰富）
./deploy-all.sh alb -b my-clickstream-bucket -m my-msk-cluster

# 默认使用 NLB 方案
./deploy-all.sh -b my-clickstream-bucket -m my-msk-cluster
```

### 2. 查看方案帮助信息

```bash
# 查看通用帮助
./deploy-all.sh --help

# 查看 NLB 方案详细参数
./deploy-all.sh nlb --help

# 查看 ALB 方案详细参数
./deploy-all.sh alb --help
```

### 3. 完整部署示例

#### NLB 方案部署
```bash
./deploy-all.sh nlb \
  --s3-bucket my-clickstream-bucket \
  --msk-cluster my-msk-cluster \
  --region us-east-1 \
  --desired-count 4
```

#### ALB 方案部署
```bash
./deploy-all.sh alb \
  --s3-bucket my-clickstream-bucket \
  --msk-cluster my-msk-cluster \
  --region us-east-1 \
  --desired-count 4
```

### 4. 分阶段部署

两种方案都支持分阶段部署：

```bash
# 跳过Docker镜像构建（如果镜像已存在）
./deploy-all.sh nlb \
  --s3-bucket my-bucket \
  --msk-cluster my-cluster \
  --skip-docker

# 只部署MSK相关组件
./deploy-all.sh alb \
  --s3-bucket my-bucket \
  --msk-cluster my-cluster \
  --skip-docker --skip-ecs --skip-alb

# 手动指定VPC（如果自动检测失败）
./deploy-all.sh nlb \
  --s3-bucket my-bucket \
  --vpc vpc-12345678 \
  --msk-cluster my-cluster
```

### 5. 查看部署计划

使用dry-run模式查看将要执行的操作：

```bash
./deploy-all.sh nlb \
  --s3-bucket my-bucket \
  --msk-cluster my-cluster \
  --dry-run
```

### 6. 全安组检查
* 请确保MSK,ECS,NLB/ALB 安全组配置正确(MSK要允许ECS的流量进来,ECS要允许ALB/NLB流量进来)，如果使用ALB可以使用`src/ingestion/alb-nginx-vector/configure-security-groups.sh` 将安全组打通

## 详细配置参数

### 必需参数

| 参数 | 说明 | 示例 |
|------|------|------|
| `--s3-bucket` | S3存储桶名称 | `my-clickstream-bucket` |
| `--msk-cluster` | MSK集群名称 | `my-msk-cluster` |

### 可选参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--region` | `us-east-1` | AWS区域 |
| `--vpc` | 自动获取 | VPC ID（如果不指定，将从MSK集群自动获取） |
| `--glue-database` | `iceberg_db` | Glue数据库名称 |
| `--desired-count` | `4` | ECS任务数量 |
| `--worker-count` | `6` | MSK连接器Worker数量 |

### 部署阶段控制

| 参数 | NLB方案 | ALB方案 | 说明 |
|------|---------|---------|------|
| `--skip-docker` | ✓ | ✓ | 跳过Docker镜像构建 |
| `--skip-ecs` | ✓ | ✓ | 跳过ECS部署 |
| `--skip-nlb` | ✓ | - | 跳过NLB部署 |
| `--skip-alb` | - | ✓ | 跳过ALB部署 |
| `--skip-msk-topics` | ✓ | ✓ | 跳过MSK主题创建 |
| `--skip-iceberg-connector` | ✓ | ✓ | 跳过Iceberg连接器创建 |
| `--skip-s3-connector` | ✓ | ✓ | 跳过S3连接器创建 |

## 手动部署步骤

如果需要手动执行各个步骤，可以按以下顺序进行：

### NLB 方案手动部署

#### 1. 构建Docker镜像
```bash
cd src/ingestion/nlb-nginx-lua/docker
./build-all-images.sh --region us-east-1
```

#### 2. 部署ECS服务
```bash
cd src/ingestion/nlb-nginx-lua/ecs
./deploy-ecs-optimized.sh \
  --region us-east-1 \
  --s3-bucket my-clickstream-bucket \
  --vpc vpc-12345678 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

#### 3. 部署网络负载均衡器
```bash
cd src/ingestion/nlb-nginx-lua/nlb
./deploy-nlb-optimized.sh \
  --region us-east-1 \
  --vpc vpc-12345678
```

### ALB 方案手动部署

#### 1. 构建Docker镜像
```bash
cd src/ingestion/alb-nginx-vector/docker
./build-all-images.sh --region us-east-1
```

#### 2. 部署ECS服务
```bash
cd src/ingestion/alb-nginx-vector/ecs
./deploy-ecs-optimized.sh \
  --region us-east-1 \
  --vpc vpc-12345678 \
  --kafka-broker-host my-kafka-broker.amazonaws.com
```

#### 3. 部署应用负载均衡器
```bash
cd src/ingestion/alb-nginx-vector/alb
./deploy-alb-optimized.sh \
  --region us-east-1 \
  --vpc vpc-12345678
```

### 共同步骤

#### 4. 创建MSK主题
```bash
cd src/msk-iceberg
./create-msk-topics.sh --cluster-name my-msk-cluster
```

#### 5. 创建Iceberg连接器
* 下面两个参数是必选的， 更多参数支持可以直接执行脚本 --help 查看， 比如默认分区时间字段，是ecs服务器收到消息的时间，如果想要使用Kafka中的每条记录元数据时间(当生产者写数据到Kafak, kafka自己有元数据记录这条数据的时间)，可以指定 -p 参数选择。

```bash
cd src/msk-iceberg
./create-s3-iceberg-connector-optimized.sh my-bucket my-msk-cluster
```

#### 6. 创建S3连接器
```bash
cd src/msk-iceberg
./create-s3-json-connector-optimized.sh my-bucket my-msk-cluster
```

## 部署后验证

### 1. 检查ECS服务状态

#### NLB 方案
```bash
aws ecs describe-services \
  --cluster clickstream-cluster \
  --services clickstream-optimized-service \
  --region us-east-1
```

#### ALB 方案
```bash
aws ecs describe-services \
  --cluster clickstream-alb-cluster \
  --services clickstream-alb-optimized-service \
  --region us-east-1
```

### 2. 检查负载均衡器状态

#### NLB 方案
```bash
aws elbv2 describe-load-balancers \
  --names clickstream-optimized-service-nlb \
  --region us-east-1
```

#### ALB 方案
```bash
aws elbv2 describe-load-balancers \
  --names clickstream-alb-optimized-service-alb \
  --region us-east-1
```

### 3. 检查MSK连接器状态
```bash
aws kafkaconnect list-connectors --region us-east-1
```

### 4. 查看容器日志

#### NLB 方案
```bash
aws logs tail /ecs/clickstream-cluster --follow --region us-east-1
```

#### ALB 方案
```bash
aws logs tail /ecs/clickstream-alb-cluster --follow --region us-east-1
```

## 生成的信息文件

部署完成后，会在相应目录生成以下信息文件：

### NLB 方案
- `src/ingestion/nlb-nginx-lua/nlb/nlb-info.txt` - NLB信息
- `src/msk-iceberg/msk-topics-info.json` - MSK主题信息
- `src/msk-iceberg/msk-iceberg-connector-info.json` - Iceberg连接器信息
- `src/msk-iceberg/msk-s3-json-connector-info.json` - S3连接器信息

### ALB 方案
- `src/ingestion/alb-nginx-vector/tmp/docker-images-info.json` - Docker镜像信息
- `src/ingestion/alb-nginx-vector/tmp/ecs-service-info.json` - ECS服务信息
- `src/ingestion/alb-nginx-vector/tmp/alb-info.json` - ALB信息
- `src/msk-iceberg/msk-topics-info.json` - MSK主题信息
- `src/msk-iceberg/msk-iceberg-connector-info.json` - Iceberg连接器信息
- `src/msk-iceberg/msk-s3-json-connector-info.json` - S3连接器信息

## 数据流测试

### NLB 方案测试

使用专门的测试脚本验证 NLB 方案的数据链路：

```bash
# 基本测试（使用默认参数）
./test-nlb-data-flow.sh

# 指定项目名称和消息数量
./test-nlb-data-flow.sh --project my_topic --count 50

# 指定区域和NLB名称
./test-nlb-data-flow.sh --region us-west-2 --nlb-name my-nlb

# 高频测试
./test-nlb-data-flow.sh --count 100 --interval 0.1

# 显示详细响应信息（用于调试）
./test-nlb-data-flow.sh --verbose
```

### ALB 方案测试

使用专门的测试脚本验证 ALB 方案的数据链路：

```bash
# 基本测试（使用默认参数）
./test-alb-data-flow.sh

# 指定项目名称和消息数量
./test-alb-data-flow.sh --project my_topic --count 50

# 指定区域和ALB名称
./test-alb-data-flow.sh --region us-east-1 --alb-name my-alb

# 高频测试
./test-alb-data-flow.sh --count 100 --interval 0.1

# 显示详细响应信息（用于调试）
./test-alb-data-flow.sh --verbose
```

#### 测试脚本参数对比

| 参数 | NLB测试脚本 | ALB测试脚本 | 默认值 | 说明 |
|------|-------------|-------------|--------|------|
| `--region` | ✓ | ✓ | `us-east-1` | AWS区域 |
| `--nlb-name` | ✓ | - | `clickstream-optimize-nlb` | NLB名称 |
| `--alb-name` | - | ✓ | `clickstream-alb-opti-alb` | ALB名称 |
| `--project` | ✓ | ✓ | `app_logs` | 项目名称/MSK主题名称 |
| `--count` | ✓ | ✓ | `10` | 发送测试消息数量 |
| `--interval` | ✓ | ✓ | `1` | 消息发送间隔（秒） |
| `--verbose` | ✓ | ✓ | `false` | 显示详细的响应信息 |

#### 测试数据特征

- **数据格式**: JSON格式，包含完整的点击流事件信息
- **数据编码**: 发送前进行Base64编码
- **请求头**: 包含 `project` header，值为指定的项目名称
- **目标主题**: 数据会发送到指定的MSK主题（默认：app_logs）

### 手动发送测试数据

#### NLB 方案
```bash
# 获取NLB DNS名称
NLB_DNS=$(aws elbv2 describe-load-balancers \
  --names clickstream-optimized-service-nlb \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region us-east-1)

# 多条发送和单条发送看客户端的设计需要，如果客户端想要多条batch一起发送，减少数据发送频次和网络请求次数，就选择多条发送模式，否则选择单条发送。 两者请选择一种
# project 在NLB方案中，其值就是kafka的topic
# 发送请求-多条list发送
echo -e '[{"event":"t1"},{"event":"t2"}]'| gzip |base64|xargs -I {} \
  curl -X POST "http://$NLB_DNS:8802/data/v1" \
  -H "project: app_logs" \
  -H "compression: gzip" \
  -d {}

# 发送请求-单条发送
echo -e '{"event":"t1"}'| gzip |base64|xargs -I {} \
  curl -X POST "http://$NLB_DNS:8802/data/v1" \
  -H "project: app_logs" \
  -H "compression: gzip" \
  -d {}
```

#### ALB 方案
```bash
# 获取ALB DNS名称
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names clickstream-alb-optimized-service-alb \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region us-east-1)

# 多条发送和单条发送看客户端的设计需要，如果客户端想要多条batch一起发送，减少数据发送频次和网络请求次数，就选择多条发送模式，否则选择单条发送。 两者请选择一种
# alb方案中project中的值并不代表topic的名称，发送的topic在ecs task中的环境变量定义
echo -e '[{"event":"t1"},{"event":"t2"}]'| gzip |base64|xargs -I {} \
  curl -X POST "http://$NLB_DNS:8802/data/v1" \
  -H "project: app_logs" \
  -H "compression: gzip" \
  -d {}

# 发送请求-单条发送
echo -e '{"event":"t1"}'| gzip |base64|xargs -I {} \
  curl -X POST "http://$NLB_DNS:8802/data/v1" \
  -H "project: app_logs" \
  -H "compression: gzip" \
  -d {}
```

### 数据样例参考

* 发送到kafka中的数据样式，客户端批量发送模式，数据会在data_list字段中有多条
```json
{
  "data_list": [
    {
      "event": "page_view",
      "ip_address": "192.168.1.10",
      "page_url": "https://example.com/page9",
      "properties": {
        "category": "test",
        "page_title": "Test Page 9",
        "test_batch": "nlb_test_1754978306"
      },
      "referrer": "https://example.com/home",
      "session_id": "",
      "timestamp": "",
      "user_agent": "Mozilla/5.0 (compatible; ClickstreamTest/1.0)",
      "user_id": ""
    },
    {
      "event": "page_view",
      "ip_address": "192.168.1.10",
      "page_url": "https://example.com/page9",
      "properties": {
        "category": "test",
        "page_title": "Test Page 9",
        "test_batch": "nlb_test_1754978306"
      },
      "referrer": "https://example.com/home",
      "session_id": "",
      "timestamp": "",
      "user_agent": "Mozilla/5.0 (compatible; ClickstreamTest/1.0)",
      "user_id": ""
    }
  ],
  "meta": {
    "ctime": 1754978306000,
    "date": "2025-08-12T05:58:26+00:00",
    "ip": "18.206.223.167",
    "method": "POST",
    "parse_status": "success",
    "platform": null,
    "project": "app_logs",
    "raw": "",
    "rid": "bf55e5d640c1a344e02c964292e9cbbe",
    "ua": "curl/8.11.1",
    "uri": "/data/v1"
  }
}
```

* 发送到kafka中的数据样式，客户端单条发送模式，数据会在data字段
```json
{
  "data": {
    "event": "page_view",
    "ip_address": "192.168.1.3",
    "page_url": "https://example.com/page2",
    "properties": {
      "category": "test",
      "page_title": "Test Page 2",
      "test_batch": "nlb_test_1754978128"
    },
    "referrer": "https://example.com/home",
    "session_id": "",
    "timestamp": "",
    "user_agent": "Mozilla/5.0 (compatible; ClickstreamTest/1.0)",
    "user_id": ""
  },
  "meta": {
    "ctime": 1754978128000,
    "date": "2025-08-12T05:55:28+00:00",
    "ip": "18.206.223.167",
    "method": "POST",
    "parse_status": "success",
    "platform": null,
    "project": "app_logs",
    "raw": "",
    "rid": "ef27bcccd8dd3c0a03c8f3de49cd4f68",
    "ua": "curl/8.11.1",
    "uri": "/data/v1"
  }
}
```

* 自动创建的iceberg表的样例

```sql
CREATE TABLE iceberg_db.app_logs (
  -- meta 字段组
  meta_raw string,
  meta_ip string,
  meta_date string,
  meta_uri string,
  meta_parse_status string,
  meta_project string,
  meta_ua string,
  meta_method string,
  meta_rid string,
  meta_ctime bigint,
  ....

  -- data 字段组展开
  data_session_id string,
  data_properties_is_logged_in boolean,
  data_app_version string,
  data_referrer string,
  data_ip string,
  data_properties_product_id bigint,
  data_os string,
  data_user_id string,
  data_timestamp bigint,
  data_event_id string,
  data_extra_data string,
  data_url string,
  data_properties_currency string,
  ....
  
  -- 多条上报list
  data_list array<struct<page_url: string, referrer: string, user_id: string, session_id: string, ip_address: string, event: string, properties: struct<page_title: string, category: string, test_batch: string>, user_agent: string, timestamp: bigint>>,

  messageTS timestamp
)
PARTITIONED BY (day(`messageTS`))
LOCATION 's3://app-common-util/app-logs-data-v1/iceberg_db.db/app_logs'
TBLPROPERTIES (
  'table_type'='iceberg',
  'write_compression'='zstd'
);

```

### 验证数据流

1. **检查Kafka主题**：
```bash
# 使用MSK客户端检查主题中的消息
# 注意：数据会发送到指定的项目主题（默认：app_logs）
```

2. **检查S3存储**：
```bash
aws s3 ls s3://your-bucket/topics/app_logs/ --recursive
```

3. **检查Iceberg表**：
```bash
# 通过Athena或Spark查询Iceberg表
```

## 故障排除

### 常见问题

1. **Docker镜像构建失败**
   - 检查Docker是否运行
   - 确认AWS CLI权限
   - 检查ECR仓库权限

2. **ECS任务启动失败**
   - 检查IAM角色权限
   - 验证VPC和子网配置
   - 查看CloudWatch日志

3. **MSK连接器创建失败**
   - 确认MSK集群状态
   - 检查S3存储桶权限
   - 验证Glue数据库存在

4. **网络连接问题**
   - 检查安全组规则
   - 验证子网路由表
   - 确认负载均衡器健康检查

5. **ALB特有问题**
   - 确认公有子网配置
   - 检查Internet Gateway连接
   - 验证路由表配置

### 日志查看

```bash
# ECS容器日志 (NLB方案)
aws logs tail /ecs/clickstream-cluster --follow

# ECS容器日志 (ALB方案)
aws logs tail /ecs/clickstream-alb-cluster --follow

# MSK连接器日志
aws logs tail /aws/mskconnect/connector-name --follow

# CloudFormation事件（如果使用）
aws cloudformation describe-stack-events --stack-name your-stack
```

## 清理资源

要删除部署的资源，需要按相反顺序进行：

### NLB 方案清理
```bash
# 删除ECS服务
aws ecs update-service \
  --cluster clickstream-cluster \
  --service clickstream-optimized-service \
  --desired-count 0

aws ecs delete-service \
  --cluster clickstream-cluster \
  --service clickstream-optimized-service

# 删除NLB
aws elbv2 delete-load-balancer \
  --load-balancer-arn <nlb-arn>
```

### ALB 方案清理
```bash
# 删除ECS服务
aws ecs update-service \
  --cluster clickstream-alb-cluster \
  --service clickstream-alb-optimized-service \
  --desired-count 0

aws ecs delete-service \
  --cluster clickstream-alb-cluster \
  --service clickstream-alb-optimized-service

# 删除ALB
aws elbv2 delete-load-balancer \
  --load-balancer-arn <alb-arn>
```

### 共同清理步骤
```bash
# 删除MSK连接器
aws kafkaconnect delete-connector --connector-arn <connector-arn>

# 清理ECR镜像
aws ecr delete-repository --repository-name <image-name> --force
```

## 成本优化建议

### 方案选择建议

1. **选择NLB方案的情况**：
   - 需要极高的性能和低延迟
   - 流量模式相对简单
   - 成本敏感的场景
   - 主要处理TCP/UDP流量

2. **选择ALB方案的情况**：
   - 需要丰富的HTTP路由功能
   - 需要详细的应用层监控
   - 需要SSL终止功能
   - 流量模式复杂，需要基于内容的路由

### 通用优化建议

1. **ECS任务数量**：根据实际负载调整`desired-count`
2. **MSK实例类型**：选择合适的实例类型和数量
3. **S3存储类别**：使用生命周期策略管理数据
4. **CloudWatch日志保留**：设置合理的日志保留期

## 安全最佳实践

1. **网络隔离**：使用私有子网部署ECS任务
2. **IAM权限**：遵循最小权限原则
3. **数据加密**：启用S3和MSK的加密
4. **访问控制**：使用安全组限制网络访问
5. **ALB安全**：配置WAF和SSL证书（如需要）

## 监控和告警

建议设置以下监控指标：

### 通用监控
- ECS任务健康状态
- MSK集群指标
- MSK连接器状态
- S3存储使用量

### NLB方案监控
- NLB目标健康状态
- NLB连接数和流量

### ALB方案监控
- ALB目标健康状态
- ALB请求数和响应时间
- HTTP错误率

## 扩展和定制

### 自定义配置

#### NLB方案
- 修改Nginx配置：编辑`src/ingestion/nlb-nginx-lua/docker/nginx-for-lua/`下的配置文件
- 调整Fluent Bit配置：修改`src/ingestion/nlb-nginx-lua/docker/fluent-bit/`下的配置

#### ALB方案
- 修改Nginx配置：编辑`src/ingestion/alb-nginx-vector/docker/nginx/`下的配置文件
- 调整Vector配置：修改`src/ingestion/alb-nginx-vector/docker/vector/`下的配置

### 性能调优

- 调整Kafka分区数量
- 优化ECS任务资源配置
- 调整MSK连接器并发度
- 根据方案特点调整负载均衡器配置

## 支持和贡献

如有问题或建议，请：

1. 检查本文档的故障排除部分
2. 查看生成的信息文件
3. 检查AWS服务控制台中的状态
4. 根据选择的方案查看对应的组件文档

## 版本历史

- v1.0: 初始版本，单条数据明文发送
- v1.1: 支持客户端单条发送，批量batch发送，gzip+base64


---

**注意**: 本解决方案会产生AWS费用，请根据实际需求选择合适的方案并调整资源配置，及时清理不需要的资源。不同方案的成本结构有所不同，请在选择前评估成本影响。
