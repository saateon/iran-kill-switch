# FAQ and limits

[Back to README](../README.md)

**Does it replace my VPN?**
No. It makes sure foreign traffic can only leave through whatever VPN you use.

**Do I have to change settings in Hiddify, v2rayN or another client?**
No. VPN programs are allowed by program, not by server address, so new servers,
subscriptions and CDN configs just work. For Iranian sites to skip the VPN without
client settings, run the VPN in TUN mode and keep *Iran direct* on.

**What happens when the VPN app crashes or I close it?**
Foreign sites stop loading; Iranian sites keep working. Nothing leaks with your real IP.

**Does it slow my connection?**
No measurable effect: the filters are evaluated in the kernel, once per connection.

**An Iranian "what is my IP" site shows my real IP. Is that a leak?**
No, that is the point: Iranian traffic goes direct.

**Is Windows Firewall changed?**
No. The tool uses its own WFP sublayer; Windows Firewall rules and profiles stay as they are.

## Limits

| | |
|---|---|
| WSL2 / Hyper-V virtual machines | their NAT traffic is forwarded by Windows and not covered |
| VPNs with their own kill switch | e.g. WireGuard's "block untunneled traffic" also blocks Iran direct; turn that option off, this tool replaces it |
| Android VPNs inside BlueStacks | the kill switch works; Iran direct must be configured inside that VPN |
| Proxy-only (System Proxy) mode | the kill switch works; Iran direct needs the VPN client's own Iran rules (Hiddify: Region = Iran); direct sites use the Windows "no proxy" list while the app runs |
| Direct sites | only the listed name and its `www.` twin; subdomains are not discovered; CDN addresses are shared with other sites |
| Iranian sites hosted abroad | they have no Iranian IP, so they go through the VPN (they still open) |
| Code signing | the installer is unsigned; SmartScreen may ask once |
