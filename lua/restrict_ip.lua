-- Redis Configuration
local redis_server = "127.0.0.1"
local redis_port = 6379
local redis_timeout = 200
local redis_secret = nil
local appname = "RESTRICT-IP"
local database = 15

-- Notification
local enable_sms = true
local level_sms = 100
local level_block = 200

-- redis IP keys
local redis_whitelist_key = "IP_WHITELIST"
local redis_blacklist_key = "IP_BLACKLIST"
local redis_ip_score = "IP_SCORE"
local redis_sms = "IP_SMS"

-- block time
local block_time = 600000 -- 10 minutes, 600000 milliseconds 
local rule_block = "444"

-- Score
local incr_score = 10
-- Client
local client_remoteip = ngx.var.remote_addr
local client_url = ngx.var.host .. '/' .. ngx.var.uri
local client_message = client_remoteip .. ": " .. client_url
local client_status = ngx.status
local time_now = os.time()

-- Functions
local function isStillBlocking(time_start)
    local time_diff = math.abs(time_start - time_now)
    if time_diff >= block_time then
        return false
    end
    return true
end

local function ruleBlock(rule)
    ngx.log(ngx.ERR, appname..": block the IP "..client_remoteip)
    if rule == "403" then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    elseif rule == "444" then
        return ngx.exit(ngx.HTTP_CLOSE)
    elseif rule == "404" then
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    elseif rule == "iptables" then
        -- set rule for block Network layer
        return
    else
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
end

-- Init Redis Connection
local resty = require "resty.redis"
local redis = resty:new()
redis:set_timeout(redis_timeout)
local isConnected, err = redis:connect(redis_server, redis_port)
if not isConnected then
    ngx.log(ngx.ERR, appname..": could not connect to redis @"..redis_port..": "..err)
    return
else
    if redis_secret ~= nil then
        local isConnected, err = redis:auth(redis_secret)
        if not isConnected then
            ngx.log(ngx.ERR, appname..": failed to authenticate"..redis_port..": "..err)
            return
        end
    end
    redis:select(database)
end

local is_white, err = redis:sismember(redis_whitelist_key, client_remoteip)
if is_white == 1 then
    ngx.log(ngx.ERR, appname..": WHITE IP "..client_remoteip)
    return
else
    -- Check IP Blacklist
    local time_start, err = redis:zscore(redis_blacklist_key, client_remoteip)
    if time_start ~= ngx.null then
        if isStillBlocking(time_start) then
            ruleBlock(rule_block)
        else
            -- Remove Bad IP
            ngx.log(ngx.ERR, appname..": Removed the bad IP "..client_remoteip)
            redis:zrem(redis_blacklist_key, client_remoteip)
            redis:hdel(redis_ip_score, client_remoteip)
            return
        end
    end
    
    -- Check Normal IP
    -- Making An Alarm
    if client_status == 403 then
        redis:hincrby(redis_ip_score, client_remoteip, incr_score)
        local ip_score, err = redis:hget(redis_ip_score, client_remoteip)
        ip_score = tonumber(ip_score)
        if ip_score ~= ngx.null then
            ngx.log(ngx.ERR, appname..": IP "..client_remoteip.." - "..ip_score)
            if ip_score >= level_block then
                ngx.log(ngx.ERR, appname..": Add To Blacklist IP "..client_remoteip)
                redis:zadd(redis_blacklist_key, time_now, client_remoteip)
            elseif ip_score == level_sms then
                redis:lpush(IP_SMS, client_message)
            end
        end
    end
end


-- Default allow all request
return