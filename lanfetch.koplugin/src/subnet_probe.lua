--[[--
SubnetProbe: Non-blocking UDP routing probe & CIDR netmask calculator for KOReader.
--]]--

local socket = require("socket")
local logger = require("logger")

local SubnetProbe = {}

local PROBE_TARGETS = {
    { ip = "1.1.1.1", port = 80 },        -- Primary: Fast default route lookup
    { ip = "8.8.8.8", port = 53 },        -- Secondary WAN
    { ip = "192.168.1.1", port = 80 },    -- Private LAN Class C fallback
    { ip = "192.168.0.1", port = 80 },    -- Private LAN Class C fallback
    { ip = "10.0.0.1", port = 80 },       -- Private LAN Class A fallback
}

function SubnetProbe.detectActiveIP()
    for _, target in ipairs(PROBE_TARGETS) do
        local ok, ip = pcall(function()
            local s = socket.udp()
            if not s then return nil end
            s:settimeout(0)
            local res = s:setpeername(target.ip, target.port)
            if not res then
                s:close()
                return nil
            end
            local local_ip = s:getsockname()
            s:close()
            return local_ip
        end)

        if ok and ip and ip ~= "0.0.0.0" and ip ~= "127.0.0.1" then
            return ip
        end
    end
    return nil
end

function SubnetProbe.getNetmask(ip)
    local o1, o2, o3, o4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not o1 then return { 255, 255, 255, 0 } end
    
    local n1 = tonumber(o1)
    if n1 == 10 then
        return { 255, 0, 0, 0 } -- /8
    elseif n1 == 172 and tonumber(o2) >= 16 and tonumber(o2) <= 31 then
        return { 255, 255, 0, 0 } -- /16
    elseif n1 == 192 and tonumber(o2) == 168 then
        return { 255, 255, 255, 0 } -- /24
    end

    return { 255, 255, 255, 0 } -- Default /24
end

function SubnetProbe.computePrefill(ip, netmask)
    if not ip then
        return { "", "", "", "" }, 1
    end

    local o1, o2, o3, o4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not o1 then
        return { "", "", "", "" }, 1
    end

    local ip_octs = { tonumber(o1), tonumber(o2), tonumber(o3), tonumber(o4) }
    local mask = netmask or SubnetProbe.getNetmask(ip)
    local result = { "", "", "", "" }
    local first_empty = 4

    for i = 1, 4 do
        if mask[i] == 255 then
            result[i] = tostring(ip_octs[i])
        elseif mask[i] == 0 then
            result[i] = ""
            if first_empty == 4 and i < 4 then
                first_empty = i
            end
        else
            local step = 256 - mask[i]
            local net_part = math.floor(ip_octs[i] / step) * step
            result[i] = tostring(net_part)
        end
    end

    return result, first_empty
end

return SubnetProbe
