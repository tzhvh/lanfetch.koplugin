-- tests/test_subnet_probe.lua
local SubnetProbe = require("src.subnet_probe")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

print("== Running SubnetProbe & Netmask Calculation Tests ==")

-- Test 1: Class C /24 (192.168.1.23/24) -> 192.168.1. (o4 empty, focus o4)
local p1, focus1 = SubnetProbe.computePrefill("192.168.1.23", { 255, 255, 255, 0 })
assert_eq(p1[1], "192", "o1 should be 192")
assert_eq(p1[2], "168", "o2 should be 168")
assert_eq(p1[3], "1", "o3 should be 1")
assert_eq(p1[4], "", "o4 should be empty")
assert_eq(focus1, 4, "Focus should be on o4")

-- Test 2: Class B /16 (172.16.5.10/16) -> 172.16. (o3 & o4 empty, focus o3)
local p2, focus2 = SubnetProbe.computePrefill("172.16.5.10", { 255, 255, 0, 0 })
assert_eq(p2[1], "172", "o1 should be 172")
assert_eq(p2[2], "16", "o2 should be 16")
assert_eq(p2[3], "", "o3 should be empty")
assert_eq(p2[4], "", "o4 should be empty")
assert_eq(focus2, 3, "Focus should be on o3")

-- Test 3: Class A /8 (10.15.20.25/8) -> 10. (o2, o3, o4 empty, focus o2)
local p3, focus3 = SubnetProbe.computePrefill("10.15.20.25", { 255, 0, 0, 0 })
assert_eq(p3[1], "10", "o1 should be 10")
assert_eq(p3[2], "", "o2 should be empty")
assert_eq(p3[3], "", "o3 should be empty")
assert_eq(p3[4], "", "o4 should be empty")
assert_eq(focus3, 2, "Focus should be on o2")

-- Test 4: Dynamic IP Detection probe execution
local detected_ip = SubnetProbe.detectActiveIP()
print("Detected active IP on host:", tostring(detected_ip))

print("All SubnetProbe netmask tests passed successfully!")
