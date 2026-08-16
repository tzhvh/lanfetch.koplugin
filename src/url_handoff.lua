-- src/url_handoff.lua
-- Bidirectional URL string handoff between LAN Mode (OctetTabber) and Alphanumeric Mode (Native InputDialog)

local URLHandoff = {}

--- Parses a freeform alphanumeric URL string to determine if it fits LAN Mode (IPv4)
-- @param raw_url string (e.g. "http://192.168.1.50:8080/files/doc.pdf" or "https://nas.local/doc.pdf")
-- @return boolean is_ipv4
-- @return table|nil octets Array of 4 numbers {192, 168, 1, 50}
-- @return string|nil port
-- @return string|nil path
-- @return string protocol
function URLHandoff.parseURL(raw_url)
    if not raw_url or raw_url == "" then
        return false, nil, nil, nil, "http://"
    end

    raw_url = raw_url:match("^%s*(.-)%s*$") -- Trim whitespace

    local protocol = "http://"
    local rest = raw_url

    if raw_url:match("^https?://") then
        protocol = raw_url:match("^(https?://)")
        rest = raw_url:sub(#protocol + 1)
    end

    -- Match host, optional port, optional path
    -- Pattern: host[:port][/path]
    local host, port, path = rest:match("^([^:/]+):?(%d*)(/?.*)$")
    if not host then
        return false, nil, nil, nil, protocol
    end

    -- Check if host is a valid IPv4 dotted-decimal address
    local o1, o2, o3, o4 = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if o1 and o2 and o3 and o4 then
        local n1, n2, n3, n4 = tonumber(o1), tonumber(o2), tonumber(o3), tonumber(o4)
        if n1 and n2 and n3 and n4 and n1 <= 255 and n2 <= 255 and n3 <= 255 and n4 <= 255 then
            local clean_port = (port and port ~= "") and port or "9999"
            local clean_path = path or ""
            if clean_path:match("^/") then
                clean_path = clean_path:sub(2) -- strip leading slash for tabber
            end
            return true, { n1, n2, n3, n4 }, clean_port, clean_path, protocol
        end
    end

    return false, nil, nil, nil, protocol
end

--- Serializes OctetTabber state into a normalized full URL for Alphanumeric Mode
-- @param tabber OctetTabber instance
-- @return string full_url
function URLHandoff.toFullURL(tabber)
    return tabber:getURL()
end

return URLHandoff
