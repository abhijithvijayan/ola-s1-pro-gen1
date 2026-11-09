# Network Probe & Root Access

## Summary

The Ola S1 Pro Gen 1 head unit runs a Go-based gRPC service (`diagnostics_server`) on TCP port 50005 that accepts unauthenticated commands and executes them as **root (uid 0)**. No ADB, no pairing, no auth token needed — just Wi-Fi connectivity to the scooter.

## Prerequisites

- Scooter powered on (ignition or charger)
- Laptop on the same Wi-Fi network as the scooter
- [`grpcurl`](https://github.com/fullstorydev/grpcurl) installed (`brew install grpcurl`)
- The proto file from this repo (`proto/wifican.proto`)

## Find the Scooter

The head unit gets a DHCP address on your home Wi-Fi. Find it via:

```bash
# Check your router's DHCP leases, or:
arp -a  # look for an unfamiliar device on your network
```

## Verify Root

```bash
grpcurl -plaintext \
  -import-path proto -proto wifican.proto \
  -d '{"cmd_msg": "id"}' \
  <SCOOTER_IP>:50005 \
  wifican.WifiCanRpc/ExecuteADBCommand
```

Expected response:

```json
{
  "status": "RESP_SUCCESS",
  "statusMsg": "uid=0(root) gid=0(root) groups=0(root) context=u:r:init:s0\n"
}
```

Or use the helper script:

```bash
SCOOTER_IP=<your-scooter-ip> bash scripts/grpc-cmd.sh "id"
```

## Shell Limitations

The gRPC `ExecuteADBCommand` does NOT run commands through a shell. It splits the `cmd_msg` on whitespace and exec's the tokens directly:

| Feature | Works? | Workaround |
|---------|--------|------------|
| Simple commands (`ls`, `id`, `getprop`) | Yes | — |
| Pipe (`\|`) | No | `sh -c` + `${IFS}` trick |
| Redirect (`>`, `>>`) | No | `sh -c` + `${IFS}` trick |
| Arguments with spaces | No | `${IFS}` trick |
| Quotes in commands | No | They get mangled |

### The `${IFS}` Trick

Replace all spaces with `${IFS}` in the command passed to `sh -c`:

```bash
# Instead of:  sh -c "echo hello | grep hello"
# Use:         sh -c echo${IFS}hello|grep${IFS}hello
grpcurl ... -d '{"cmd_msg": "sh -c echo${IFS}hello|grep${IFS}hello"}' ...
```

How it works:
1. gRPC daemon splits on whitespace: `sh`, `-c`, `echo${IFS}hello|grep${IFS}hello`
2. `sh -c` receives the third token as the command string (no spaces = single token)
3. `sh` expands `${IFS}` to whitespace, interprets `|` as pipe and `>>` as redirect

## Gen 1 vs E2 Differences

Known differences between the Gen 1 head unit (this repo's target) and the E2 / Gen 2 platform:

| Aspect | Gen 1 | E2 |
|--------|-------|-----|
| SoC | Qualcomm SDM450 (Snapdragon 450) | MediaTek MT8768 |
| Screen | 1280x768 | 800x480 |
| Android | 10 (SDK 29) | 13 |
| gRPC on IPv4 | Open (no firewall) | Blocked (IPv6 only) |
| ADB key path | `/data/misc/adb/adb_keys` | Mode-dependent (`/adb_keys` or `/adbkeymoveos3_pub_prod`) |
| Init script | `/vendor/etc/ola_e2.rc` | `/vendor/etc/init/ola_e2.rc` |

## Security Posture

| Property | Value |
|----------|-------|
| SELinux | Permissive |
| Build | `test-keys` (not production-signed) |
| dm-verity | Enforcing (`/system` read-only) |
| A/B OTA | Yes |
| Encryption | Block-level on `/data` (transparent with root) |
| Scooter mode | `mfg` (manufacturing) — hardcoded in init |
| gRPC auth | None |

## Proto Extraction

The `proto/wifican.proto` file was extracted directly from `/vendor/bin/diagnostics_server` on the head unit. Go's `protoc-gen-go` embeds a serialized `FileDescriptorProto` in every binary it compiles. We:

1. Pulled the binary via ADB (`adb pull /vendor/bin/diagnostics_server`)
2. Searched for the protobuf wire encoding of `wifican.proto` (field 1 tag `0x0a`, length `0x0d`, then the filename bytes)
3. Parsed the raw `FileDescriptorProto` using `google.protobuf.descriptor_pb2`
4. Decoded it back to `.proto` source

The result is the authoritative definition: **42 RPC methods** (the community proto had 38 — missing `pushFile`, `ClearStorage`, `CheckManifestFile`, and `TechPackUpdate`), **26 messages** (missing `FileRequest` and `PackageName`), and **20 enums**.

No gRPC reflection is available on the server (`grpcurl list` returns "server does not support the reflection API").

## Dangerous RPCs — Do Not Call

| Method | Risk |
|--------|------|
| `SwUpdate*` | Firmware flashing |
| `ProvisionVin`, `ProvisionConfig` | Identity changes |
| `GenerateCerts`, `RegisterInstallCerts` | Certificate operations |
| `RemoveWifiCredentials` | Nukes saved Wi-Fi networks |
| `ScooterModeChange` | Changes `persist.ola.security.scootermode`. Setting it to `cust` fires `/vendor/etc/ola_e2.rc`'s `close_port` → iptables DROPs ports 50005 and 5555, firewalling off ADB and this very gRPC service until the next reboot (the `on post-fs-data` init hook resets the property to `mfg` on every boot and re-opens the ports). Avoid setting it mid-ride if you'll need network access again this session; see `docs/scootermode-and-recovery.md`. |
| `ClearStorage` | Wipes app data |
| `pushFile` | Writes files to device |
| `Deinit` | Unclear behavior |

Also avoid writing to CAN IDs `0x6BC` or `0x6A1` without understanding what you're sending.
