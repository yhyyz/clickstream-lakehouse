### 链路压测

#### 压测目标

- NLB+Nginx+Lua+MSK在给定的资源下能够满足5w/s的客户端埋点数据请求写入，单条记录大小1KB.
- MSK(Kafka) Connector在给定的资源下能够满足5w/s的数据从MSK消费写入到Iceberg+S3或者Json+S3

#### 测试方式

* 使用AB压测工具在EC2上做并行发送1KB的数据请求， 同时查询MSK写入数据速度。
```Bash
# 请求头的project自定义key, 值是app_logs当前就是要发送的msk topic， postdata.txt 是1KB原始原始json，gzip+base64
# 在16c,32g的机器上启动两个ab进程做的压测
ab -H "project: app_logs" -H "Content-Type: text/plain" -n 2000000000 -c 100 -p postdata.txt http://clickstream-nlb-xxxxx.amazonaws.com:8802/data/v1

ab -H "project: error_data_test" -H "Content-Type: text/plain" -n 2000000000 -c 100 -p postdata.txt http://clickstream-nlb-xxxxx..amazonaws.com:8802/data/v1
```

```shel
# 原始json
{"user_agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36","properties":{"experiment_id":"exp_3","product_id":910,"is_logged_in":true,"page_title":"Example Page","category":"electronics","price":996.55508435134,"currency":"USD"},"timestamp":1753257716029,"event_id":"evt_1753257716029195991_2507","event_name":"page_view","user_id":"user_84962","session_id":"session_586","platform":"web","app_version":"1.0.0","device_type":"desktop","country":"US","extra_data":"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwx","city":"New York","ip":"192.168.145.82","url":"https://example.com/page","os":"Windows","referrer":"https://google.com"}

# gzip+base64之后
cat -> postdata.txt<<EOF
H4sIAAAAAAAAA+1TTW/UMBC98ysin0Ba5dv56gkJTogKCVDFyfIms6nZJDb2JNlt1f/OOKGC/oJeuHnem3l+nvE8stmBFbKHCVnDPusHNQwy4mEcvL1TU6dXF9x+C5I4jG8CAor8JrgU+bvgvTED3MHxk8KIZ2WYFezAjNUGLCpwrHlkcKFAjaQsVEfiFItsz+rmdgfrJD4w5cSg+x46oSbWoJ2BksiSQIUDUOXHixzpuuALgSTQSoRe26vXHKBFqyfVuk1ZtZRf10XIOY+rPONJllPBbC1MrS/4/vUDezowJF8OSZU1ScmzlJdlUsRpfWCw/DW8oHjBJjWv60SkPC7Zc+YkR29x87soWInYWropbKcqr4uUYAfOKT3tzHPAq61xg8STtiMRKxwJkMaIBaxPISwJqf+EdrDQAwVejb+yA3dGbXxD9Dyh3Z/njV3QStFJlITIY9vBqb9XP8/DOGnzyzqcl/VyffjPvD7jh6fQT+4W1uCHtmdClPEzr9MwKaowyXlY+e8z24Hge0TjmiiCfSXCVo+R2ddC09axP0tLoYUT0Le3/xT1Wvd7DXt68xvsx+Vr+wMAAA==
EOF

# 查看数据
cat postdata.txt |base64 -d |gunzip
```

#### 环境配置&成本预估

|               | 资源类型       | 配置           | 版本               | 个数     | 成本估计($)   |
| ------------- | -------------- | -------------- | ------------------ | -------- | ---------- |
| NLB           | -              | TG->ECS        |                    | 1        | 1K/month   |
| ECS           | FARGATE        | 4Core 8G/Task  | openresty-1.25.3.2 | 3 task   | 1K/month   |
| MSK           | Express Broker | express.xlarge | 3.8.x              | 3 broker | 2.5K/month |
| MSK Connector | MCU            | 1Core 4G/MCU   | 3.7.x              | 6个      | 0.5k/month |

#### 压测结果
*  NLB+Nginx+Lua发送数据到MSK，当前的资源配置下，可以每秒写入5万条左右的数据，单条记录大小1.3KB左右, 写入流量59MB/s左右。
* MSK Connector消费MSK数据写入到S3, 当前资源配置下，可以做到稳定消费每秒5万条数据写入为Iceberg+zstd格式或者Json+gzip格式
* 写入Iceberg格式时对MSK Connector做了Json字段展平的transformer操作，方便查询，同时开启了Schema变更支持，分区采用Icberg隐藏分区day(ctime), ctime为ECS服务器接收到数据记录的时间。
* 当前ECS最大的cpu利用率70%，生产使用可以根据请求量，调整ECS TASK个数。

| 组件          | Nginx+Lua+MSK  | Iceberg+s3 写入 | Json+s3写入    | 最大CPU利用率 |
| ------------- | -------------- | --------------- | -------------- | ------------- |
| ECS           | 5w records / s | -               | -              | 70%           |
| MSK Connector | -              | 5w records / s  | 5w records / s | 40%           |

#### 相关截图
* nlb+nginx+lua+kafka写入
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121731034.png)
* msk connector 写入iceberg+zstd
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121733246.png)
* msk connector 写入json+gzip
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121732804.png)
* ab
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121735320.png)
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121736285.png)
* iceberg 数据
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121754278.png)
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121754644.png)
![](https://pcmyp.oss-cn-beijing.aliyuncs.com/markdown/202508121755486.png)