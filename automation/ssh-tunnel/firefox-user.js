// Firefox proxy settings for the SSH SOCKS5 tunnel.
//
// Use a dedicated profile so your normal browsing is unaffected:
//   1. Open about:profiles, create a profile called "vpn-lab", launch it.
//   2. Find its folder (about:support, "Profile Folder", Open).
//   3. Copy this file into that folder as user.js, then restart the profile.
//
// The same values can be set by hand in Settings > Network Settings.

user_pref("network.proxy.type", 1);                 // manual proxy configuration
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 1080);
user_pref("network.proxy.socks_version", 5);

// Resolve hostnames on the server, not locally. Without this your ISP still sees
// every domain you visit even though the traffic is tunnelled. This is the
// "Proxy DNS when using SOCKS v5" checkbox.
user_pref("network.proxy.socks_remote_dns", true);

// Stop WebRTC from announcing your local network addresses to websites.
user_pref("media.peerconnection.ice.default_address_only", true);
