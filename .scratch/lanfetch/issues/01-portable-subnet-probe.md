Type: research
Status: resolved

# Portable Subnet Probe & Android Compatibility

## Question

How can KOReader portably detect the active local IPv4 subnet and IP address across Kindle (Linux), Kobo (Linux), Android (KOReader Android JNI / LuaSocket), and desktop emulator without spawning shell commands or requiring root permissions?

## Answer

Use a non-blocking dummy connected UDP socket (`socket.udp():setpeername()`). 

On POSIX and Android Linux kernels:
1. Calling `setpeername("1.1.1.1", 80)` forces the kernel's Forwarding Information Base (FIB) routing table to bind the socket locally to the outbound network interface IP.
2. Zero network packets or ARP requests are transmitted over the wire, and no 3-way handshake occurs.
3. `getsockname()` retrieves the assigned local IP in microseconds without root permissions, shell execution (`io.popen`), or Android SELinux `procfs` restrictions (`/proc/net/route`).
4. Multi-target fallback cascade: primary probe to `1.1.1.1:80`, followed by `8.8.8.8:53` and RFC 1918 gateways (`192.168.1.1`, `192.168.0.1`, `10.0.0.1`) for isolated offline LANs. Fallback defaults to `192.168.1.100` / port `9999` with a non-blocking warning.
