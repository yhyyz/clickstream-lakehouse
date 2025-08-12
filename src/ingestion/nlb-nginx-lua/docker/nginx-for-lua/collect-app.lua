local cjson = require "cjson"
local client = require "resty.kafka.client"
local producer = require "resty.kafka.producer"
local zlib = require("zlib")

-- 如果kafa宕机ECS重新部署一下走如下逻辑不在连kafka. 之所以不在error_handle中控制，因为异步发送kafka如果遇到kafka宕机，还是要不断请求metadata，看kafka是否ready, 这个性能就会下降，
-- 因为请求metadata要经过socket_timeout超时时间，这个超时间即便设置的再短每条数据都会发一次请求看metadata是否ok, kafka是否恢复，会影响请求的性能，所以当前想在kafka宕机时自动的将错误
-- 信息写入，并且保持高性能无法做到。 所以在这里写一个段逻辑，如果kafka宕机，传递一个参数，控制代码不走kafka逻辑，直接写入数据，ECS更新下参数部署即可。 当然从kafka宕机到重新部署ECS这段时间
-- 会有部分数据丢失。特别说明，要想做到数据完全不丢失，就不要走任何的网络直连kafka的方案，因为基本都会存在上述问题，只能数据先落磁盘，然后通过服务采集磁盘数据到kafka, 保证磁盘空间足够大，
-- 防止kafka宕机磁盘被打满。这个链路会有更大延迟和维护成本，可以做个综合考量。还有另一种方式是，两个kafka集群双活，如果一个故障可以重新滚动部署下ECS写入到新集群，也可以通过route53配置反向地址解析，
-- 可以做到不用重新部署ecs,但因为在route53做切换过程，也会有不可用的时间，所以也不可能保证一条数据不丢失，但可以做基本不丢。

-- 总结一下
-- 1. 当前方案，性能好，成本低，但如果kafka整体宕机，客户端发送数据会丢失
-- 2. 如果保证数据尽可能在Kafka宕机情况下不丢失，有如下四种方式
-- a. kafka 双活，一个宕机后，切换到另一个kafka集群，切换过程可能会有部分数据丢失
-- b. kafka宕机后，通过下面代码，写数据到本地盘，然后由sidecar fluent-bit上传到s3, 宕机后滚动部署ECS期间，数据可能会有丢失。且因为nginx的log有4KB大小限制，所以超过4KB的log就会被截断，需要配置一个大的磁盘防止宕机，磁盘写满
-- c. 不使用当前方式写kafka, 数据先写磁盘，所有数据通过fluent-bit上传到s3，只要磁盘不故障，基本不会丢数据。需要配置一个大的磁盘防止kafka宕机，磁盘写满
-- d. 使用nginx+vector http ,vector支持数据先缓存在磁盘，如果kafka宕机，数据写磁盘，恢复了之后再发送, 依然。需要配置一个大的磁盘防止kafka宕机，磁盘写满

local send_s3_only = os.getenv("SEND_S3_ONLY") or "disable"

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

local error_handle = function (topic, partition_id, queue, index, err, retryable)
          -- local error_data = "[" .. table.concat(queue, ", ") .. "]"
          -- ngx.log(ngx.ERR, "failed send data: " .. err .. ";error_data:" .. error_data )
          --     ngx.log(ngx.ERR, "failed send data: " .. err .. ";queue_size:" .. #queue)
          -- ngx error当前的硬限制是4096字节，也就是4kb, 如果长度大于4kb会被截断
          -- 只有当retryable为true时才执行for循环记录详细信息
          if retryable then
              for i, item in ipairs(queue) do
                  -- 只记录偶数位置的元素（值部分）因为queue结构是{ key1, msg1, key2, msg2 } ，只需要记录msg即可
                  if i % 2 == 0 then
                      ngx.log(ngx.ERR, "item_" .. (i/2) .. ": " .. tostring(item))
                  end
              end
          end
end

local producer_config = {
    request_timeout = 1000,
    socket_timeout = 2000,
    producer_type = "async",
    -- flush_time=queue.buffering.max.ms，异步模式下，缓存消息的时间，设置为1000ms，表示缓存1s后发送消息，增加了吞吐，但是增大了延迟
    flush_time = 1000,
    max_retry = 3,
    api_version = 2,
    -- batch_num=batch.num.messages 一个batch缓存的消息数量,达到该值才会发送数据
    batch_num = 500,
    -- max_buffering=queue.buffering.max.messages 异步模式下，producer buffer队列里最大缓存消息数量，超过该值producer到发送会报buffer overflow错误，会返回客户端500状态码
    max_buffering = 100000,
    error_handle = error_handle
}

-- 读取请求体信息
ngx.req.read_body()
-- 请求体信息存放到 body_data变量中
local body_data = ngx.req.get_body_data()
-- 如果请求体为空，返回错误
if body_data == nil  then
  ngx.say('{"code":500,"data":"req body nil"}')
  return
end
-- 定义当前时间
local current_time = ngx.now()*1000
-- 从请求的URL project参数中获取其值
-- local project = ngx.var.arg_project
-- 从请求头获取project信息
local headers = ngx.req.get_headers()
local project = headers["project"] or ngx.var.arg_project
if not project then
  ngx.say('{"code":500,"data":"header need project key"}')
  return
end

-- 定义一个字典，存放有当前服务为日志增加的信息，如ctime表示接受到请求的时间，ip地址等
local data={}
data["project"] = project
data["ctime"] = current_time
if ngx.var.http_x_forwarded_for == nil then
  data["ip"] = ngx.var.remote_addr;
else
  data["ip"] = ngx.var.http_x_forwarded_for
end

data["uri"] = ngx.var.request_uri
data["ua"] = ngx.var.http_user_agent
data["date"] = ngx.var.time_iso8601
data["rid"] = ngx.var.request_id
data["method"] = ngx.var.request_method

-- 将增加的信息编码为json
local meta = cjson.encode(data)
-- 先对请求数据进行base64解码
local decoded_body_data = ngx.decode_base64(body_data)
if decoded_body_data == nil then
  ngx.say('{"code":500,"data":"base64 decode failed"}')
  return
end

-- 从请求头获取是否是gzip压缩,请求头有'compression: gzip'标示是gzip压缩，会对数据进行解压
local compression = headers["compression"] or ngx.var.arg_compression
local stream = zlib.inflate()
if compression == "gzip" then
  decoded_body_data = stream(decoded_body_data)
end

local success, decoded_body_json_data = pcall(cjson.decode, decoded_body_data)
if not success then
  -- 处理解析失败的情况
  ngx.say('{"code":500,"data":"json decode failed"}')
  return
end
-- 创建包含meta和data的JSON对象
local combined_json = {}
combined_json["meta"] = data
if type(decoded_body_json_data) == "table" and decoded_body_json_data[1] ~= nil then
  -- 既是table类型，又有第1个元素 -> 是数组
  combined_json["data_list"] = decoded_body_json_data
else
  combined_json["data"] = decoded_body_json_data
end
  -- 将JSON对象编码为字符串
local combined_data = cjson.encode(combined_json)

if send_s3_only == "enable" then
    ngx.log(ngx.ERR, combined_data)
    ngx.say('{"code":200,"data":true}')
    return
end
-- 将拼接后的数据再进行base64编码
-- local res = ngx.encode_base64(combined_data)
-- 将编码的json信息做base64 和 body_data拼接, 这是meta和data直接拼接方式，base64 发送到kafka,当前不采用，只是给个参考例子
-- local res = ngx.encode_base64(meta) .. "-" .. body_data
-- kafka 生成者
local bp = producer:new(broker_list,producer_config)
-- 发送数据，topic=project，key=current_time
local offset, err = bp:send(project, tostring(current_time),combined_data)
-- 如果buffer满了，这个err的错误就是buffer overflow，offset false. 下面判断只有offset是false的就返回500错误
if not offset then
    ngx.say('{"code":500,"data":"send kafka failed"}')
    return
end
ngx.say('{"code":200,"data":true}')
