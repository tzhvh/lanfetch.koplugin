-- src/subnet_probe.lua
-- Portable LAN Subnet Detector and Netmask Calculator for KOReader

local socket = require("socket")

local SubnetProbe = {}

local PROBE_TARGETS = {
    { ip = "1.1.1.1", port = 80 },        -- Primary: Fast default route lookup
    { ip = "8.8.8.8", port = 53 },        -- Secondary WAN
    { ip = "192.168.1.1", port = 80 },    -- Private LAN fallback (Class C)
    { ip = "192.168.0.1", port = 80 },    -- Private LAN fallback (Class C)
    { ip = "10.0.0.1", port = 80 },       -- Private LAN fallback (Class A)
}

--- Resolves the active local IPv4 address via connected UDP dummy socket
-- @return string|nil ip Dotted-decimal string (e.g. "192.168.1.45")
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

--- Attempts to detect the netmask for the active IP, or defaults based on IP class
-- @param ip string
-- @return table mask_octets Array of 4 numbers {255, 255, 255, 0}
function SubnetProbe.getNetmask(ip)
    -- If /proc/net/route or interface inspection is unavailable, infer from IP class
    local o1, o2, o3, o4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not o1 then return { 255, 255, 255, 0 } end
    
    local n1 = tonumber(o1)
    if n1 >= 1 and n1 <= 126 then
        -- Class A (e.g. 10.x.x.x -> default /8 if not specified)
        if n1 == 10 then
            return { 255, 0, 0, 0 } -- /8
        end
    elseif n1 >= 128 and n1 <= 191 then
        -- Class B (e.g. 172.16.x.x -> default /16)
        if n1 == 172 and tonumber(o2) >= 16 and tonumber(o2) <= 31 then
            return { 255, 255, 0, 0 } -- /16
        end
    elseif n1 >= 192 and n1 <= 223 then
        -- Class C (e.g. 192.168.x.x -> /24)
        return { 255, 255, 255, 0 } -- /24
    end

    -- Default fallback is /24 (255.255.255.0)
    return { 255, 255, 255, 0 }
end

--- Computes prefill octets: network bits filled, host bits left blank ("")
-- @param ip string (e.g. "192.168.1.45")
-- @param netmask table|nil (e.g. {255, 255, 255, 0})
-- @return table prefill { o1, o2, o3, o4 } where host octets are ""
-- @return number first_empty_index The index of the first blank host octet to focus (1..4)
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
            -- Partial netmask octet: compute bitwise network portion
            -- In pure Lua: math.floor(ip / (256 - mask)) * (256 - mask)
            local step = 256 - mask[i]
            local net_part = math.floor(ip_octs[i] / step) * step
            result[i] = tostring(net_part)
        end
    end

    return result, first_empty
end

return SubnetProbe
