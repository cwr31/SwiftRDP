# RDP multitransport

SwiftRDP supports reliable UDP2 graphics for clients that advertise both
`TRANSPORTTYPE_UDPFECR` and `SOFTSYNC_TCP_TO_UDP`. It uses MS-RDPEUDP's version
`0x0101` initialization, then MS-RDPEUDP2 data framing. Older UDP data formats
and lossy/DTLS tunnels are outside this implementation.

TCP remains the main RDP connection. Server graphics DVC traffic moves to UDP2;
static channels, audio, mouse/keyboard input and session control continue on TCP.
The client can send data for any open DVC on its approved reliable tunnel.
DVC PDUs retain the MS-RDPEDYC 3.1.5 limit of 1600 bytes on both reliable
transports. Moving graphics to UDP does not enlarge the DVC PDU limit; large
frames use DATA_FIRST / DATA fragments inside separate tunnel messages.

## Establishment and ordering

1. GCC advertises multitransport only when the UDP listener is available and the
   client has the message channel, DRDYNVC, GFX and Soft-Sync capabilities.
2. After licensing, the server sends a unique request ID and a random 128-bit
   security cookie over the secured main connection.
3. A client SYN must contain the matching SHA-256 cookie hash. Unmatched datagrams
   do not allocate a transport. Negotiations and receive buffers are bounded.
   The hash is encoded as eight network-order DWORDs (MS-RDPEUDP 2.2.2.9),
   rather than the raw 32 digest bytes. A fixed independent fixture checks this.
4. Reliable UDP2 exposes an ordered byte stream to the native NIOSSL server
   handler, using the same TLS context and certificate as the main connection.
   mstsc starts this phase with reliable channel 1 carrying TLS ClientHello,
   without a separate ACK. Its additional `0x200` header bit adds no payload
   field and is ignored during payload decoding. The first TLS bytes are retained.
   UDP2 DATA sequences form a new space independent of the initialization SYN's
   ISNs. The server sends from 100; its receive base comes from the first UDP2
   AckOfAcks field, or the first DATA sequence when AckOfAcks is absent. Reliable
   channel sequences start at 1 and remain unchanged on retransmission.
   They skip wire value zero on every 16-bit wrap, matching the Windows behavior
   documented in MS-RDPEUDP2 3.1.1.2.4.2. Transport DATA sequences wrap normally.
5. Tunnel Create must match the request ID and cookie inside TLS. Application
   data cannot enter an unauthenticated tunnel.
6. A successful Initiate Multitransport Response on TCP permits Soft-Sync. The
   Soft-Sync request uses the ordered TCP graphics lane behind all earlier GFX
   writes. New graphics writes enter UDP atomically, but remain held until the
   request's final TCP write completes.
7. Inbound UDP DVC messages remain buffered until the main connection consumes
   the client's Soft-Sync response. Compression histories belong to each DVC
   and remain intact across the switch.

## Flow control and recovery

UDP2 handles cumulative/selective ACKs, ACK-of-ACKs, reordering, duplicate
datagrams, dummy packets and 16-bit sequence reconstruction. Retransmission uses
a new transport sequence while preserving the reliable channel sequence.

The sender uses a bounded receive/send window, RTT-based loss timers, Reno
congestion control and byte pacing. Retransmit, delayed ACK, keepalive and idle
deadlines run as event-loop timers. Each drain has a bounded packet budget.
Idle dummy probes obtain fresh UDP RTT samples without reliable application
data or retransmission, so static desktops retain measured connection health.
Video frames enter atomically with at most two queued frames. Write completions
reflect the final local socket write, preserving GFX ACK latency semantics.
ACK vectors acknowledge only explicit received states. Split or reordered
vectors never implicitly acknowledge preceding gaps.
DelayAckInfo is decoded as its full byte field, with the local ACK batch capped
at 15 per MS-RDPEUDP2 3.1.5.2. A larger advertised count does not discard other
ACK information in the same packet.

Graphics backpressure and RTT measurements follow the active graphics path.
TCP queue pressure cannot block UDP graphics. A switch clears previous path
measurements while retaining consumed timestamps, so an old TCP bandwidth
measurement cannot become fresh again when returning to TCP.

Failure before migration leaves the TCP graphics channel in place. Failure after
migration closes the old GFX DVC over the main connection and creates a new GFX
DVC on TCP, with a fresh codec generation. The main RDP session continues.

The main TCP event loop owns DVC creation, closure, recovery deadlines and
auto-detection probes. TCP uses per-connection keepalive deadlines and a
30-second retransmission limit. Three consecutive unanswered application RTT
probes also terminate an unresponsive main connection.
Each authenticated UDP peer uses a connected socket bound to the local address
and interface reported by the kernel on its SYN. This preserves the return path
on hosts with public port forwarding, VPNs or multiple interfaces. The shared
listener handles new SYNs; connected sockets retain the configured RDP port.

Pending TCP handshakes are bounded and cannot displace the authenticated desktop.
Auto-reconnection parses the Client Info cookie field and verifies the TLS
HMAC-MD5 SecurityVerifier. Only the current desktop can issue a replacement
cookie; credentials rotate on takeover and hourly while connected.

## Verification

`swift test` covers fixed wire fixtures, invalid packets, authentication,
bidirectional loss/reordering/duplicates, sequence wrap, compression isolation,
TCP flush ordering, bounded frame admission and real UDP/TLS exchange with a
certificate pinned to the main connection's certificate.

For independent interoperability, install Rust 1.94.0 and run:

```bash
rustup toolchain install 1.94.0 --profile minimal
bash scripts/verify-multitransport-interop.sh
```

The script builds an IronRDP client at a pinned upstream revision in a temporary
directory, verifies the same TLS certificate, and exchanges 40 messages of
60,000 bytes in each direction. Rust is a verification tool, not an app dependency.
That revision emits raw cookie hash bytes, a v1 final ACK, and DATA sequences
derived from SYN ISNs. The script corrects these three initialization fixtures
in its temporary checkout to match the observed mstsc v3 bootstrap. Its data
transport, TLS and RDPEMT implementations remain independent. The native UDP/TLS
test uses a large SYN ISN and independent DATA sequences, and fixed wire tests
check the first ACK, initial loss and sequence wrap. A 65,540-packet regression
checks the reserved channel-zero boundary; the native encrypted graphics test
transfers 96 MB across that boundary and verifies complete frame reconstruction.
The Microsoft specification
defines the DATA sequence and its reconstruction but does not prescribe the
initial value 100; that value follows current mstsc behavior.

References: [MS-RDPEUDP2](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpeudp2/9db34630-e880-4bfd-9d8d-50bc044c3288),
[MS-RDPEMT](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpemt/d22b606c-32c4-4647-b356-86f75e23a22c),
[Soft-Sync](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpedyc/b64bcbe9-569f-4cec-906d-b02659aee043),
[independent IronRDP implementation](https://github.com/Devolutions/IronRDP/tree/bf019ca502d1e52616853a5ded68c885cec1e322/crates/ironrdp-rdpeudp).
