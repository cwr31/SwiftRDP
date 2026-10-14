# Video adaptation

SwiftRDP adapts the video source to keep delivery latency bounded. TCP and UDP2
own transport congestion control; `VideoTargetController` owns encoding targets
and Graphics admission. The application controller uses the feedback available
from a standard RDP client, without inferring network capacity from its own
paced video output.

## User settings

Picture quality is presented as Auto (Original), Original 20M, Ultra HD 8M,
HD 2M, or Custom. Auto and Original both allow up to 20 Mbps; selecting a tier
sets its encode budget ceiling, not a guaranteed visual quality or fixed wire
rate. Every mode retains congestion adaptation. "Original" does not mean
lossless: the current hardware path is AVC420. Custom supports 1-500 Mbps,
retains its value when switching tiers, and applies slider edits on release.
The Custom menu contains a native inline slider and a non-interactive hint,
not a switch or a separate window. Moving the slider selects Custom directly;
opening its submenu alone does not change the selected quality.
The menu bar uses an owned AppKit `NSStatusItem` and `NSMenu` hierarchy. The
custom slider is attached directly to its submenu, rather than replacing a
SwiftUI menu after tracking starts. Contents refresh on menu opening; preference
changes update only selection states without rebuilding an active slider.

Frame rate is an independent ceiling, currently up to 60 fps. New-client
defaults do not replace remembered client settings. Menu changes apply to the
active client's saved settings; the custom bitrate editor keeps that client
scope even if another client connects while it is open. Server configuration
and session snapshots carry the complete `VideoQualitySettings`, including the
selected mode and retained custom budget. Menus read that state directly rather
than inferring a mode from its bitrate ceiling. Persisted settings use only the
current quality model; bitrate-only formats are not migrated.

## Feedback and responsibilities

| Signal | Meaning | Application response |
| --- | --- | --- |
| Connect-time bandwidth probe | Initial path measurement | Start bitrate at 85% of the measurement, within configured limits; use at most 4 Mbps without a measurement. |
| Auto-detection or active UDP2 RTT | Independent round-trip measurement | Reference for delay and the bounded frame acknowledgement window. |
| Local outbound bytes and transport writability | Sender backlog and admission capacity | Stop producing additional frames until the queue drains; retain at most two queued video frames. |
| Graphics FRAME_ACK latency | Delivery plus client scheduling and decoding | Respond to sustained additional delay; report the source as `frameAck`, rather than identifying it as network RTT. |
| Graphics FRAME_ACK bytes / interval | Acknowledged delivery rate | Estimate known client backlog delay and report delivery; do not use it as network capacity. |
| Known client queue bytes | Client processing backlog | Reduce the decoder FPS cap; avoid charging the same backlog to network adaptation. |
| Continuous busy completion interval | Encoder throughput | Reduce the encoder FPS cap when sustained service cannot meet the requested cadence. |
| VideoToolbox submission-to-output latency | Pipeline latency | Diagnostic; multiple frames can overlap, so latency alone is not a throughput limit. |
| Graphics QoE command time | Includes command receive waiting | Diagnostic only. |

FRAME_ACK queue depth `0` means unavailable, and `0xFFFFFFFF` suspends frame
acknowledgements. Neither represents a measured empty queue. Suspension releases
outstanding frame credits and removes ACK delay from current feedback.

## Control policy

The local queue delay estimate uses the current pacing rate, bounded by a fresh
independent bandwidth measurement. A bandwidth measurement expires after 30
seconds; RTT updates cannot refresh it. Whole frames enter the byte pacer
atomically, so one frame period of serialization is allowed before counting
additional sender backlog.

Decoded-frame ACK feedback has an additional-delay budget of at least 100 ms,
or a frame period / measured RTT when either is longer. This is an application
policy, not an RDP protocol constant. It allows normal decoding and feedback
variation without repeatedly reducing a healthy connection's targets. The
minimum observed ACK delay remains the reference, bounded below by a fresh
independent RTT; sustained delay cannot silently become its own healthy baseline.
The independent reference follows the current smoothed transport RTT. The
historical minimum remains an auto-detection diagnostic; it is not renewed as
the current RTT when the path becomes slower.

Pressure must persist for 0.5 seconds before adaptation, with at least 0.5 seconds
between changes. Recovery requires one second below the lower pressure threshold.
FPS recovery runs independently of bitrate demand, so a path below the configured
bitrate can regain smooth motion. Bitrate probes require fresh source output using
at least 80% of the current bitrate budget. An empty queue during sparse desktop
updates does not establish available bandwidth. Quality priority uses smaller
FPS increments. Encoder and decoder limits remain independent ceilings.
The AVC encoder permits two in-flight pictures. Outputs are delivered in
submission order, including errors and timeouts. Completed pictures retain an
encode slot while waiting for actual Graphics credit, so neither encoding nor
output buffering can grow unbounded. Native completion intervals are sampled
only during uninterrupted outstanding work; sparse input does not establish
encoder capacity. Sustained throughput pressure reduces FPS, and healthy feedback
can recover smaller viable increments or probe again when the backend is free.
RemoteFX remains a serial CPU encoder and uses its actual encode work duration.

Capture pacing advances scheduled deadlines to avoid accumulating ordinary timer
lateness. A long stall skips missed frames and starts a fresh deadline.

VideoToolbox receives an explicit duration for the requested picture cadence,
while presentation timestamps retain actual elapsed time. Leaving duration
unknown lets Graphics credit or pacing gaps enlarge the next picture's bitrate
budget, producing another large frame and another delivery wait. A hardware
regression test introduces these gaps and checks that the per-picture budget
stays bounded.

ACK timing starts when the final local write completes. This excludes application
pacing wait; it does not prove remote receipt. During healthy delivery, the frame
credit window covers smoothed decoded-frame ACK latency at the target cadence,
plus one spare credit so capture and encoding can overlap feedback arrival.
Credits count frames rather than converting a byte budget using past picture
sizes. Tiny known client queues do not collapse the window: tightening requires
queue delay to reach the decoder pressure budget. Congestion does not earn more
credits. The window remains bounded by the client's ceiling and 12 frames, with
an initial two-frame minimum; real client backlog, severe ACK delay or stall
recovery restricts it to one frame.

## Capture delivery and static refinement

AVC admission distinguishes pending capture submissions from successfully wired
captures. A VideoToolbox-dropped final update remains eligible after a bounded
retry delay, even if ScreenCaptureKit publishes no further frame. Newer captures
supersede older failures. A native input drop keeps the existing reference chain;
an unsent encoded reference is rebuilt with an IDR before dependent pictures are
wired. Resize, output resume and Graphics resets discard generation-local state.
Capture wakeups are sticky and coalesced, so a publication or encoder completion
between checking work and entering a wait cannot lose its notification.

After 250 ms without a newly observed capture, AVC may attempt one static
reference refresh. Increasing the user quality ceiling or the actual adaptive
bitrate rearms one attempt, not a growing queue. Network/client pressure defers
pending optional work; pressure clearing does not replenish spent attempts and
therefore cannot create a self-sustaining refresh loop. Encoding slots and client
credits remain bounded as for ordinary pictures, and newer captures cancel
unsubmitted optional work.

Repeating a P-picture did not reliably improve text in the native experiment.
The refresh instead uses a short-lived isolated hardware encoder to produce an
IDR with a 200 ms picture budget, without changing the live FPS ceiling or
disabling native rate control. It is
sent only when VideoToolbox's measured NV12 reconstruction error improves by at
least 10% over the same delivered capture and its Annex-B payload fits 180 ms of
the current pacing rate; the remaining 10% reserves transport framing headroom.
Missing metrics, zero reconstruction error, worse quality, stale content or an
oversized picture do not produce a refresh. A rejected trial is stopped without
changing the live encoder or its reference chain, so even the next small update
can remain a P-picture. An accepted trial becomes the live encoder: subsequent
P-pictures reference exactly the IDR sent to the client. Trials never overlap
live encode work, are generation-scoped, and leave no second permanent encoder.
An optional native frame drop also consumes its attempt rather than causing an
IDR storm. Motion pictures retain their explicit ordinary cadence budget.

The hardware regression scrolls a 1024 x 768, 13-point monospace text fixture at
a 2 Mbps encode budget, then restores a 20 Mbps budget without a new capture.
One budgeted refresh reduced decoded luma MSE from about 24.65 to 3.47 with a
422 KB access unit in the 2026-10-14 run. This is a controlled image-fidelity
check, not proof of client presentation latency or full-screen 60 FPS. Transport
rejection, optional-frame rejection, reference repair, pressure recovery, quality
edits and generation resets also have focused regression coverage.

## Practical limits and validation

This is a bounded RDP sender controller, not a packet arrival bandwidth estimator.
Standard Graphics ACKs cannot precisely separate network delay from client decode
delay when queue depth is unavailable. The queue byte estimate also does not
measure bytes already accepted into the operating system's socket buffer.
Transport backpressure, independent measurements and conservative recovery are
therefore necessary together. Current adaptation floors are 1 Mbps and 5 fps;
they are product limits rather than guarantees that every path can sustain them.

Diagnostics distinguish capture, submitted and client-decoded FPS. A static
desktop can legitimately submit no frames while capture continues. Changing
content is required when assessing delivered frame rate.

Regression coverage includes self-paced ACK rate, low-FPS serialization, recovery
below configured bandwidth, tiny ACK outliers, normal decoded-frame jitter,
startup bandwidth, sparse source demand, stale measurements, client queue pressure
and encoder pressure, out-of-order completion, tightened client credits and timer
drift. In the 2026-10-12 mstsc session through a TCP forwarder at 3024 × 1964,
active samples with capture at least 50 fps averaged about 56 fps at capture and
50 fps at client decode after the pipeline and credit fixes. Before the credit
fix, the corresponding activity sample averaged about 44 decoded fps. These
sessions used different desktop activity and are not a controlled benchmark.
TCP retransmissions and feedback spikes remained visible, and large changes
could still reduce delivery. Neither the configured target nor a peak near
59 fps establishes sustained full-screen 60 fps capacity for the path or encoder.

The design follows the interactive media principles of low self-induced latency,
stable handling of application-limited traffic and recovery after congestion in
[RFC 8836](https://www.rfc-editor.org/rfc/rfc8836.html). RDP feedback semantics come
from Microsoft's [FRAME_ACK definition](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/0241e258-77ef-4a58-b426-5039ed6296ce)
and [FRAME_ACK processing](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/d64cfae6-f30a-47e7-9655-d019d3d8fb0f).
Encoder rate settings and source timing follow Apple's
[DataRateLimits documentation](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_dataratelimits)
and [low-latency encoding guidance](https://developer.apple.com/videos/play/wwdc2021/10158/).
