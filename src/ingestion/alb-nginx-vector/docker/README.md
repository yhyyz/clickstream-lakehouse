# Docker镜像构建

本目录包含ALB+Nginx+Vector方案的Docker镜像构建配置和脚本。

## 目录结构

```
docker/
├── build-all-images.sh            # 镜像构建脚本
├── nginx/                          # Nginx镜像配置
│   ├── Dockerfile
│   └── config/
│       ├── nginx.conf              # Nginx配置文件
│       └── docker-entrypoint.sh    # 容器启动脚本
├── vector/                         # Vector镜像配置
│   ├── Dockerfile
│   └── config/
│       ├── entrypoint.sh           # Vector启动脚本
│       ├── vector.toml             # Vector主配置
│       ├── vector-global.toml      # Vector全局配置
│       ├── vector-msk-ack.toml     # MSK确认模式配置
│       └── vector-msk-batch.toml   # MSK批处理模式配置
└── README.md                       # 本文档
```

## 镜像说明

### Nginx镜像
- **基础镜像**: `public.ecr.aws/docker/library/nginx:1.27`
- **监听端口**: 8802
- **健康检查**: `/health` 端点
- **功能**: 
  - 接收HTTP请求
  - 转发到Vector处理
  - 支持CORS配置
  - 提供健康检查和ping端点

### Vector镜像
- **基础镜像**: `timberio/vector:0.43.0-debian`
- **HTTP服务端口**: 8685 (接收Nginx转发)
- **健康检查端口**: 8686
- **数据目录**: `/var/lib/vector`
- **功能**:
  - 接收HTTP POST请求
  - 数据转换和处理
  - 发送到MSK Kafka集群
  - 支持批处理和确认模式

## 快速使用

### 构建所有镜像

```bash
./build-all-images.sh --region us-east-1
```

### 构建脚本参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-r, --region` | `us-east-1` | AWS区域 |
| `-n, --nginx-image` | `clickstream-nginx-vector-optimized` | Nginx镜像名称 |
| `-v, --vector-image` | `clickstream-vector-optimized` | Vector镜像名称 |
| `-h, --help` | - | 显示帮助信息 |

### 使用示例

```bash
# 使用默认参数构建
./build-all-images.sh

# 指定区域
./build-all-images.sh --region us-west-2

# 自定义镜像名称
./build-all-images.sh \
  --region us-east-1 \
  --nginx-image my-nginx \
  --vector-image my-vector
```

## 配置说明

### Nginx配置

**环境变量**:
- `SERVER_ENDPOINT_PATH`: 数据收集端点路径 (默认: `/collect`)
- `PING_ENDPOINT_PATH`: Ping端点路径 (默认: `/ping`)
- `SERVER_CORS_ORIGIN`: CORS允许的源 (默认: `*`)
- `NGINX_WORKER_CONNECTIONS`: Worker连接数 (默认: `1024`)

**端点说明**:
- `/collect`: 数据收集端点，接收POST请求
- `/ping`: Ping端点，返回时间戳
- `/health`: 健康检查端点，代理到Vector

### Vector配置

**环境变量**:
- `AWS_REGION`: AWS区域
- `AWS_MSK_BROKERS`: MSK代理地址
- `AWS_MSK_TOPIC`: MSK主题名称
- `STREAM_ACK_ENABLE`: 启用流确认 (`true`/`false`)
- `VECTOR_REQUIRE_HEALTHY`: 要求健康检查 (`true`/`false`)
- `WORKER_THREADS_NUM`: Worker线程数 (默认: `-1` 自动)

**配置文件**:
- `vector-global.toml`: 全局配置，包括数据目录和API设置
- `vector.toml`: 主配置，定义数据源和转换
- `vector-msk-ack.toml`: MSK确认模式输出配置
- `vector-msk-batch.toml`: MSK批处理模式输出配置

## 构建过程

脚本执行以下步骤：

1. **检查ECR仓库**: 自动创建不存在的ECR仓库
2. **ECR登录**: 获取登录凭证
3. **构建镜像**: 
   - 构建Nginx镜像 (支持多平台)
   - 构建Vector镜像 (支持多平台)
4. **标记镜像**: 为ECR推送准备
5. **推送镜像**: 上传到ECR仓库
6. **保存信息**: 生成镜像信息文件

## 生成的文件

构建完成后会生成：
- `../tmp/docker-images-info.json`: 包含镜像URI和构建信息

## 故障排除

### 常见问题

1. **Docker构建失败**
   - 检查Docker是否运行
   - 确认网络连接正常
   - 验证基础镜像可访问

2. **ECR推送失败**
   - 检查AWS CLI配置
   - 验证ECR权限
   - 确认区域设置正确

3. **权限错误**
   - 确保AWS用户有ECR相关权限
   - 检查IAM策略配置

### 权限要求

构建脚本需要以下AWS权限：
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecr:GetAuthorizationToken",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
                "ecr:CreateRepository",
                "ecr:DescribeRepositories"
            ],
            "Resource": "*"
        }
    ]
}
```

## 镜像使用

构建的镜像可以在ECS任务定义中使用：

```json
{
  "containerDefinitions": [
    {
      "name": "nginx-container",
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/clickstream-nginx-vector-optimized:latest",
      "portMappings": [{"containerPort": 8802}]
    },
    {
      "name": "vector-container", 
      "image": "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/clickstream-vector-optimized:latest",
      "mountPoints": [
        {
          "sourceVolume": "vector-data",
          "containerPath": "/var/lib/vector"
        }
      ]
    }
  ]
}
```

## 下一步

镜像构建完成后，可以：
1. 部署ECS服务 (参见 `../ecs/README.md`)
2. 配置ALB (参见 `../alb/README.md`)
3. 配置安全组规则 (参见 `../configure-security-groups.sh`)
