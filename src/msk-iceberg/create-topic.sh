# 先创建如下两个topic, 第一个topic app_logs 是点击流数据写入的topic, 第二个topic是msk connector 写iceberg时存储offset的topic
# 创clickstream topic  app-logs
bs="boot-uaw.msklogstream.oee1gg.c16.kafka.us-east-1.amazonaws.com:9092"
./bin/kafka-topics.sh --create --bootstrap-server ${bs}  --replication-factor 3 --partitions 18 --topic app_logs

# 写iceberg时，offset的存储，解释：https://github.com/databricks/iceberg-kafka-connect/tree/main?tab=readme-ov-file#control-topic
bs="boot-uaw.msklogstream.oee1gg.c16.kafka.us-east-1.amazonaws.com:9092"
./bin/kafka-topics.sh  \
  --bootstrap-server ${bs} \
  --create \
  --topic control-iceberg \
  --partitions 25