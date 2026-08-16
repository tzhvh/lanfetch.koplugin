-- src/octet_tabber.lua
-- Octet Tabber State Machine for KOReader LAN PDF Downloader

local OctetTabber = {}
OctetTabber.__index = OctetTabber

local SEGMENT_KEYS = { "o1", "o2", "o3", "o4", "port", "path" }

function OctetTabber.new(initial_octets, initial_port, initial_path)
    local self = setmetatable({}, OctetTabber)
    local octs = initial_octets or { 192, 168, 1, 100 }
    
    self.protocol = "http://"
    self.segments = {
        o1 = tostring(octs[1] or 192),
        o2 = tostring(octs[2] or 168),
        o3 = tostring(octs[3] or 1),
        o4 = tostring(octs[4] or 100),
        port = tostring(initial_port or 9999),
        path = initial_path or ""
    }
    
    self.active_index = 4 -- Default focus on host octet (o4)
    self.is_selected = true -- Default: whole segment is selected for quick overwrite
    self.cursor_pos = nil -- Character cursor position when is_selected == false (1-based)
    
    return self
end

function OctetTabber:getActiveKey()
    return SEGMENT_KEYS[self.active_index]
end

--- Focuses the next segment in cycle and selects it whole
function OctetTabber:tab()
    self.active_index = (self.active_index % #SEGMENT_KEYS) + 1
    self.is_selected = true
    self.cursor_pos = nil
end

--- Focuses the previous segment in cycle and selects it whole
function OctetTabber:shiftTab()
    self.active_index = self.active_index - 1
    if self.active_index < 1 then
        self.active_index = #SEGMENT_KEYS
    end
    self.is_selected = true
    self.cursor_pos = nil
end

--- Directly select a specific segment by index (1..6) or key
function OctetTabber:selectSegment(target)
    if type(target) == "string" then
        for idx, key in ipairs(SEGMENT_KEYS) do
            if key == target then
                self.active_index = idx
                break
            end
        end
    elseif type(target) == "number" and target >= 1 and target <= #SEGMENT_KEYS then
        self.active_index = target
    end
    self.is_selected = true
    self.cursor_pos = nil
end

--- Enters a numeric digit ('0'-'9')
function OctetTabber:inputDigit(digit_char)
    local key = self:getActiveKey()
    local val = self.segments[key]

    if self.is_selected then
        -- Overwrite entire segment
        self.segments[key] = digit_char
        self.is_selected = false
        self.cursor_pos = 2
        return
    end

    -- Insertion/Append mode
    local pos = self.cursor_pos or (#val + 1)
    local left = val:sub(1, pos - 1)
    local right = val:sub(pos)
    local candidate = left .. digit_char .. right

    if key == "o1" or key == "o2" or key == "o3" or key == "o4" then
        -- Octet constraints: max 3 digits, max value 255
        if #candidate <= 3 and tonumber(candidate) and tonumber(candidate) <= 255 then
            self.segments[key] = candidate
            self.cursor_pos = pos + 1
            
            -- Auto-advance convenience: if 3 digits entered, automatically advance to next segment
            if #candidate == 3 and self.active_index < 5 then
                self:tab()
            end
        end
    elseif key == "port" then
        -- Port constraints: max 5 digits, max value 65535
        if #candidate <= 5 and tonumber(candidate) and tonumber(candidate) <= 65535 then
            self.segments[key] = candidate
            self.cursor_pos = pos + 1
        end
    elseif key == "path" then
        self.segments[key] = candidate
        self.cursor_pos = pos + 1
    end
end

--- Enters delimiter characters or path characters
function OctetTabber:inputChar(char)
    local key = self:getActiveKey()
    
    if char == "." then
        -- Hitting dot on octet 1..3 advances to next octet
        if self.active_index >= 1 and self.active_index <= 3 then
            self:tab()
            return
        end
    elseif char == ":" then
        -- Hitting colon on octet 4 advances to port
        if self.active_index == 4 then
            self:selectSegment("port")
            return
        end
    elseif char == "/" then
        -- Hitting slash on port advances to path
        if self.active_index == 5 then
            self:selectSegment("path")
            return
        end
    end

    if key == "path" then
        if self.is_selected then
            self.segments.path = char
            self.is_selected = false
            self.cursor_pos = 2
        else
            local pos = self.cursor_pos or (#self.segments.path + 1)
            local left = self.segments.path:sub(1, pos - 1)
            local right = self.segments.path:sub(pos)
            self.segments.path = left .. char .. right
            self.cursor_pos = pos + 1
        end
    end
end

--- Arrow Left: cancels selection (places cursor at start) or moves cursor left
function OctetTabber:arrowLeft()
    local key = self:getActiveKey()
    local val = self.segments[key]

    if self.is_selected then
        -- Cancel selection and position cursor at start of segment
        self.is_selected = false
        self.cursor_pos = 1
        return
    end

    local pos = self.cursor_pos or 1
    if pos > 1 then
        self.cursor_pos = pos - 1
    else
        -- Wrap cursor to end of previous segment
        if self.active_index > 1 then
            self.active_index = self.active_index - 1
            self.is_selected = false
            self.cursor_pos = #self.segments[self:getActiveKey()] + 1
        end
    end
end

--- Arrow Right: cancels selection (places cursor at end) or moves cursor right
function OctetTabber:arrowRight()
    local key = self:getActiveKey()
    local val = self.segments[key]

    if self.is_selected then
        -- Cancel selection and position cursor at end of segment
        self.is_selected = false
        self.cursor_pos = #val + 1
        return
    end

    local pos = self.cursor_pos or (#val + 1)
    if pos <= #val then
        self.cursor_pos = pos + 1
    else
        -- Move cursor to start of next segment
        if self.active_index < #SEGMENT_KEYS then
            self.active_index = self.active_index + 1
            self.is_selected = false
            self.cursor_pos = 1
        end
    end
end

--- Backspace: clears selected substring if selected, or deletes character before cursor
function OctetTabber:backspace()
    local key = self:getActiveKey()
    local val = self.segments[key]

    if self.is_selected then
        -- Clear the entire segment
        self.segments[key] = ""
        self.is_selected = false
        self.cursor_pos = 1
        return
    end

    local pos = self.cursor_pos or (#val + 1)
    if pos > 1 then
        local left = val:sub(1, pos - 2)
        local right = val:sub(pos)
        self.segments[key] = left .. right
        self.cursor_pos = pos - 1
    else
        -- Hop to previous segment and delete its trailing char
        if self.active_index > 1 then
            self.active_index = self.active_index - 1
            local prev_key = self:getActiveKey()
            local prev_val = self.segments[prev_key]
            if #prev_val > 0 then
                self.segments[prev_key] = prev_val:sub(1, #prev_val - 1)
            end
            self.is_selected = false
            self.cursor_pos = #self.segments[prev_key] + 1
        end
    end
end

--- Clears all segments back to blank / defaults
function OctetTabber:clear()
    self.segments = {
        o1 = "",
        o2 = "",
        o3 = "",
        o4 = "",
        port = "9999",
        path = ""
    }
    self.active_index = 1
    self.is_selected = true
    self.cursor_pos = nil
end

--- Sets the detected subnet in the first 3 octets
function OctetTabber:setSubnet(o1, o2, o3)
    self.segments.o1 = tostring(o1 or 192)
    self.segments.o2 = tostring(o2 or 168)
    self.segments.o3 = tostring(o3 or 1)
    self.active_index = 4 -- Focus host octet
    self.is_selected = true
    self.cursor_pos = nil
end

--- Constructs the full resolved URL
function OctetTabber:getURL()
    local host = string.format("%s.%s.%s.%s",
        self.segments.o1 ~= "" and self.segments.o1 or "0",
        self.segments.o2 ~= "" and self.segments.o2 or "0",
        self.segments.o3 ~= "" and self.segments.o3 or "0",
        self.segments.o4 ~= "" and self.segments.o4 or "0"
    )
    local port_part = (self.segments.port and self.segments.port ~= "") and (":" .. self.segments.port) or ""
    local path_part = self.segments.path or ""
    if path_part ~= "" and not path_part:match("^/") then
        path_part = "/" .. path_part
    end
    return self.protocol .. host .. port_part .. path_part
end

--- Returns visual render tokens for e-ink UI
function OctetTabber:getRenderTokens()
    local tokens = {}
    for idx, key in ipairs(SEGMENT_KEYS) do
        local is_active = (idx == self.active_index)
        table.insert(tokens, {
            key = key,
            text = self.segments[key],
            is_active = is_active,
            is_selected = is_active and self.is_selected,
            cursor_pos = (is_active and not self.is_selected) and self.cursor_pos or nil
        })
    end
    return tokens
end

return OctetTabber
