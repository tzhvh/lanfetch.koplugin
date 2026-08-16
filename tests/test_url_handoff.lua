-- tests/test_url_handoff.lua
local URLHandoff = require("src.url_handoff")
local OctetTabber = require("src.octet_tabber")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAILED: %s | Expected: %s, got: %s", msg or "", tostring(expected), tostring(actual)))
    end
end

print("== Running Dual-Mode URL Handoff Tests ==")

-- Test 1: Full IPv4 URL with port and path
local is_v4, octs, port, path, proto = URLHandoff.parseURL("http://192.168.1.55:8000/docs/math.pdf")
assert_eq(is_v4, true, "Should be recognized as IPv4")
assert_eq(octs[1], 192, "o1")
assert_eq(octs[2], 168, "o2")
assert_eq(octs[3], 1, "o3")
assert_eq(octs[4], 55, "o4")
assert_eq(port, "8000", "port")
assert_eq(path, "docs/math.pdf", "path")
assert_eq(proto, "http://", "proto")

-- Test 2: Bare IP without scheme
local is_v4_2, octs_2, port_2, path_2, proto_2 = URLHandoff.parseURL("10.0.0.12:9999/test.pdf")
assert_eq(is_v4_2, true, "Bare IP should be recognized as IPv4")
assert_eq(octs_2[1], 10, "o1")
assert_eq(octs_2[4], 12, "o4")
assert_eq(port_2, "9999", "port")
assert_eq(path_2, "test.pdf", "path")

-- Test 3: Domain name URL (Alphanumeric only)
local is_v4_3 = URLHandoff.parseURL("https://nas.home.local/download/paper.pdf")
assert_eq(is_v4_3, false, "Domain name must not be treated as bare IPv4")

-- Test 4: IPv6 URL
local is_v4_4 = URLHandoff.parseURL("http://[fe80::1]:8080/doc.pdf")
assert_eq(is_v4_4, false, "IPv6 must remain in Alphanumeric mode")

-- Test 5: Round-trip from OctetTabber -> string -> parseURL -> new OctetTabber
local tabber1 = OctetTabber.new({ 192, 168, 18, 145 }, 9999, "book.pdf")
local exported_url = URLHandoff.toFullURL(tabber1)
assert_eq(exported_url, "http://192.168.18.145:9999/book.pdf", "Exported URL match")

local ok, r_octs, r_port, r_path = URLHandoff.parseURL(exported_url)
assert_eq(ok, true, "Round-trip parse should succeed")
local tabber2 = OctetTabber.new(r_octs, r_port, r_path)
assert_eq(tabber2:getURL(), exported_url, "Round-trip URL must be identical")

print("All Dual-Mode URL Handoff tests passed successfully!")
