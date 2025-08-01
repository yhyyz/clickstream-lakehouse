local cjson = require "cjson"
local client = require "resty.kafka.client"

-- 从环境变量获取kafka broker地址，如果没有设置则使用默认值
local kafka_broker_host = os.getenv("KAFKA_BROKER_HOST")
local kafka_broker_port = tonumber(os.getenv("KAFKA_BROKER_PORT")) or 9092


local broker_list = {}

-- 处理逗号分隔的多个broker地址
for host in string.gmatch(kafka_broker_host, "([^,]+)") do
    -- 移除可能的空格
    host = string.gsub(host, "^%s*(.-)%s*$", "%1")
    table.insert(broker_list, { host = host, port = kafka_broker_port })
end

local cli = client:new(broker_list)

local brokers, partitions = cli:fetch_metadata("__consumer_offsets")
if not brokers then
    -- 返回 503 表示不健康
    ngx.status = 500
    -- ngx.say("fetch_metadata failed, err:", partitions)
    ngx.say(cjson.encode({
        status = "unhealthy",
        error = partitions
    }))
else
    -- 返回 200 表示健康
    ngx.status = 200
    --ngx.say("brokers: ", cjson.encode(brokers), "; partitions: ", cjson.encode(partitions))

    ngx.say(cjson.encode({
        status = "healthy"
    }))
end