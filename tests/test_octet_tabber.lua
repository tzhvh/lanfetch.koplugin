-- tests/test_octet_tabber.lua
local OctetTabber = require("src.octet_tabber")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

print("== Running OctetTabber State Machine Tests ==")

-- Test 1: Initial state
local tabber = OctetTabber.new({ 192, 168, 1, 50 }, 9999, "")
assert_eq(tabber:getActiveKey(), "o4", "Initial focus should be o4")
assert_eq(tabber.is_selected, true, "Initial segment should be selected for overwrite")
assert_eq(tabber:getURL(), "http://192.168.1.50:9999", "Initial URL mismatch")

-- Test 2: Overwrite on digit entry
tabber:inputDigit("8")
assert_eq(tabber.segments.o4, "8", "o4 should be overwritten by '8'")
assert_eq(tabber.is_selected, false, "Selection should clear after first overwrite digit")
tabber:inputDigit("5")
assert_eq(tabber.segments.o4, "85", "Subsequent digit should append")

-- Test 3: Tab cycling
tabber:tab()
assert_eq(tabber:getActiveKey(), "port", "Tab should advance to port")
assert_eq(tabber.is_selected, true, "Port should be selected")
tabber:inputDigit("8")
tabber:inputDigit("0")
assert_eq(tabber.segments.port, "80", "Port should overwrite to '80'")

-- Test 4: Arrow Left cancellation of selection
tabber:tab() -- Advances to path
assert_eq(tabber:getActiveKey(), "path", "Should be on path")
tabber:inputChar("a")
tabber:inputChar("b")
tabber:inputChar("c")
assert_eq(tabber.segments.path, "abc", "Path should have 'abc'")
tabber:selectSegment("path")
assert_eq(tabber.is_selected, true, "Path selected whole")
tabber:arrowLeft()
assert_eq(tabber.is_selected, false, "Arrow Left should cancel selection")
assert_eq(tabber.cursor_pos, 1, "Cursor should be at pos 1")
assert_eq(tabber.segments.path, "abc", "Path text should be preserved on cancel")

-- Test 5: Backspace clears entire segment when selected
tabber:selectSegment("o2")
assert_eq(tabber.segments.o2, "168", "o2 has 168")
assert_eq(tabber.is_selected, true, "o2 selected")
tabber:backspace()
assert_eq(tabber.segments.o2, "", "Backspace on selected segment should clear it")
assert_eq(tabber:getActiveKey(), "o2", "Focus remains on o2")

-- Test 6: Octet value validation (<= 255)
tabber:inputDigit("9")
tabber:inputDigit("9")
tabber:inputDigit("9") -- Candidate 999 > 255, must be rejected
assert_eq(tabber.segments.o2, "99", "Octet should reject > 255")

-- Test 7: Direct Tap / select segment
tabber:selectSegment("o1")
assert_eq(tabber:getActiveKey(), "o1", "Direct select o1")
assert_eq(tabber.is_selected, true, "Direct tap should select whole")
tabber:inputDigit("1")
tabber:inputDigit("0")
assert_eq(tabber.segments.o1, "10", "o1 overwritten with 10")

-- Test 8: Subnet detection prefill
tabber:setSubnet(10, 0, 5)
assert_eq(tabber.segments.o1, "10", "Subnet o1")
assert_eq(tabber.segments.o2, "0", "Subnet o2")
assert_eq(tabber.segments.o3, "5", "Subnet o3")
assert_eq(tabber:getActiveKey(), "o4", "Subnet prefill focuses o4")
assert_eq(tabber.is_selected, true, "o4 selected")

print("All 8 state machine tests passed successfully!")
