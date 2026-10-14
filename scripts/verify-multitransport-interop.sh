#!/bin/bash
set -euo pipefail

# Independent UDP2 + TLS + RDPEMT client; test-only, outside the app dependency graph.
# Requires the Rust 1.94.0 toolchain. The upstream revision is pinned for repeatability.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
interop_dir="$(mktemp -d "${TMPDIR:-/tmp}/swiftrdp-interop.XXXXXX")"
trap 'rm -rf "$interop_dir"' EXIT
mkdir -p "$interop_dir/src"

# The pinned Tokio wrapper hashes the cookie as raw bytes. MS-RDPEUDP 2.2.2.9
# transmits eight network-order DWORDs, as mstsc does. Correct the initialization
# fixtures in a temporary checkout: wire hash, direct v3 DATA bootstrap, and the
# independent UDP2 sequence space. Data transport, TLS and tunnel codecs stay independent.
git init -q "$interop_dir/ironrdp"
git -C "$interop_dir/ironrdp" fetch -q --depth 1 https://github.com/Devolutions/IronRDP \
    bf019ca502d1e52616853a5ded68c885cec1e322
git -C "$interop_dir/ironrdp" checkout -q --detach FETCH_HEAD
python3 - "$interop_dir/ironrdp/crates/ironrdp-rdpeudp-tokio/src/transport.rs" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
original = '    Sha256::digest(tunnel_config.security_cookie).into()'
replacement = '''    let mut digest: [u8; 32] = Sha256::digest(tunnel_config.security_cookie).into();
    for word in digest.chunks_exact_mut(4) { word.reverse(); }
    digest'''
assert source.count(original) == 1, 'Pinned cookie hash fixture changed'
path.write_text(source.replace(original, replacement))
path = path.parents[2] / 'ironrdp-rdpeudp/src/connection.rs'
source = path.read_text()
start = source.index('    fn enqueue_final_ack(&mut self, remote_isn: u32) {')
end = source.index('\n    /// Sample the handshake round trip', start)
replacement = '''    fn enqueue_final_ack(&mut self, _remote_isn: u32) {
        // v3 proceeds directly with its first UDP2 DATA, as mstsc does.
    }
'''
source = source[:start] + replacement + source[end:]
original = '''        let local_initial_data_seq = u64::from(params.local_isn) + 1;
        let remote_initial_data_seq = u64::from(params.remote_isn) + 1;'''
replacement = '''        let (local_initial_data_seq, remote_initial_data_seq) = match params.wire {
            WireFormat::V1 { .. } => (u64::from(params.local_isn) + 1, u64::from(params.remote_isn) + 1),
            WireFormat::V2 => (100u64, 100u64),
        };'''
assert source.count(original) == 1, 'Pinned UDP2 initial sequence fixture changed'
path.write_text(source.replace(original, replacement))
PY

cat > "$interop_dir/Cargo.toml" <<'TOML'
[package]
name = "swiftrdp-udp2-interop"
version = "0.1.0"
edition = "2024"

[dependencies]
ironrdp-rdpeudp-tokio = { path = "ironrdp/crates/ironrdp-rdpeudp-tokio", features = ["rustls-ring"] }
ironrdp-rdpemt = { path = "ironrdp/crates/ironrdp-rdpemt" }
ironrdp-tls = { path = "ironrdp/crates/ironrdp-tls", features = ["rustls-verifier"] }
tokio = { version = "1", features = ["macros", "rt", "time"] }
serde_json = "1"
TOML
cat > "$interop_dir/src/main.rs" <<'RUST'
use std::{fs, sync::Arc, time::Duration};
use ironrdp_rdpemt::TunnelConfig;
use ironrdp_rdpeudp_tokio::{UdpTransportConfig, connect_udp};
use ironrdp_tls::CertificateValidation;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("missing test configuration")?;
    let info: serde_json::Value = serde_json::from_str(&fs::read_to_string(path)?)?;
    let cookie: Vec<u8> = serde_json::from_value(info["cookie"].clone())?;
    let certificate: Vec<u8> = serde_json::from_value(info["certificateDER"].clone())?;
    let mut config = UdpTransportConfig::new(
        info["server"].as_str().ok_or("missing server")?.parse()?, "localhost".into(),
        TunnelConfig {
            request_id: info["requestID"].as_u64().ok_or("missing request ID")? as u32,
            security_cookie: cookie.try_into().map_err(|_| "invalid cookie size")?,
        },
    );
    config.tls.certificate_validation = CertificateValidation::Strict;
    // Pin the same self-signed leaf as the authenticated main RDP connection.
    config.tls.certificate_validation_callback = Some(Arc::new(move |der, _, _| der == certificate));
    let mut transport = tokio::time::timeout(Duration::from_secs(12), connect_udp(config)).await??;
    // Exercise native idle dummy probes through the independent decoder before data transfer.
    tokio::time::sleep(Duration::from_secs(5)).await;
    for sequence in 0..40 {
        let bytes: Vec<u8> = (0..60_000).map(|i| ((i + sequence * 17) % 251) as u8).collect();
        transport.send(bytes.clone()).await?;
        let echo = tokio::time::timeout(Duration::from_secs(5), transport.recv()).await?.ok_or("tunnel closed")?;
        if echo != bytes { return Err("ordered tunnel data differs".into()); }
    }
    println!("Independent IronRDP UDP2/TLS/RDPEMT exchange passed: 2.4 MB each direction");
    transport.shutdown().await?;
    Ok(())
}
RUST
rustup run 1.94.0 cargo build --manifest-path "$interop_dir/Cargo.toml"
cd "$repo_dir"
SWIFTRDP_IRONRDP_INTEROP_CLIENT="$interop_dir/target/debug/swiftrdp-udp2-interop" \
    swift test --filter MultitransportIntegrationTests/testIndependentIronRDPClient
