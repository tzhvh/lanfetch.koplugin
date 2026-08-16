--[[--
URLHandoff: Bi-directional conversion between LAN Mode (IPv4) and Alphanumeric Mode.
--]]--

local URLHandoff = {}

function URLHandoff.parseURL(raw_url)
    if not raw_url or raw_url == "" then
        return false, nil, nil, nil, "http://"
    end

    raw_url = raw_url:match("^%s*(.-)%s*$")

    local protocol = "http://"
    local rest = raw_url

    if raw_url:match("^https?://") then
        protocol = raw_url:match("^(https?://)")
        rest = raw_url:sub(#protocol + 1)
    end

    local host, port, path = rest:match("^([^:/]+):?(%d*)(/?.*)$")
    if not host then
        return false, nil, nil, nil, protocol
    end

    local o1, o2, o3, o4 = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if o1 and o2 and o3 and o4 then
        local n1, n2, n3, n4 = tonumber(o1), tonumber(o2), tonumber(o3), tonumber(o4)
        if n1 and n2 and n3 and n4 and n1 <= 255 and n2 <= 255 and n3 <= 255 and n4 <= 255 then
            local clean_port = (port and port ~= "") and port or "9999"
            local clean_path = path or ""
            if clean_path:match("^/") then
                clean_path = clean_path:sub(2)
            end
            return true, { n1, n2, n3, n4 }, clean_port, clean_path, protocol
        end
    end

    return false, nil, nil, nil, protocol
end

return URLHandoff
