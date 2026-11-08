# Ecamm's clean XPC integration branch

This branch, `codex/ecamm-xpc`, starts at Michael's original ShootKit revision
`5f83909083316e8c60b4b254844f03d6ccb5450d` and now merges Michael's main through
`361d3a81e6630a5eb6323f1542087cdfe8cbbb4f` (timestamp protocol, October 10, 2026).
It is independent of the older
`ecamm` branch and its experimental streaming changes. Changes below are marked
with practical `Ecamm:` comments in the source to make upstream review easier.

The periodic iPad playback glitch reproduced outside Ecamm with unmodified
ShootKit. This branch therefore keeps safety and host-integration fixes, **not**
the earlier attempts to change codec/network timing to cure that glitch.

## Changes retained, and why

### Essential: memory ownership

- Decoder compressed bytes are copied into Core Media-owned memory before
  decoding. The original block buffer referenced a temporary Swift array.
  Michael now fixes this upstream; we use his implementation, not a second patch.
- HEVC parameter pointers reference stable `NSData` owners kept alive through
  `CMVideoFormatDescriptionCreateFromHEVCParameterSets`.
- Lazy/scaled `CIImage` inputs are rasterized into fresh pixel buffers rather
  than overwriting storage still owned by an asynchronous encoder.
- Encoder callback ownership is balanced by explicit asynchronous invalidation.
  Decoder invalidation also retains its owner until VideoToolbox teardown ends.

### Essential: cancellation and permission boundaries

- An optional delegate callback asks permission before TCP connection/video.
  Existing hosts without this callback keep automatic connection behavior.
- Bonjour names are exposed to the host; they are **not authenticated identity**.
- `disconnect()` suppresses automatic reconnection until the host explicitly
  calls `reconnect()`. Ecamm uses this for revocation, sleep, and user switching.
- Weak discovery/connection handlers and connection-generation checks reject
  obsolete approvals, receives, retries, and codec callbacks.
- Teardown clears callbacks, cancels connections, and invalidates codecs.
  The host receives a disconnect notification even after the connection is nil.
- Only one receive operation is outstanding. Empty-body stream-control messages
  are accepted. Control sends do not start extra receive loops.
- Parameters are queued before the first encoded frame. The first keyframe is
  not discarded while waiting for parameter-send completion.

### Important: malformed input and codec failure handling

- The framer rejects messages over 16 MiB before buffering their bodies and
  applies the same limit before converting outgoing sizes to `UInt32`.
- Parameter JSON has a 64 KiB limit. Parameter arrays have count/size limits and
  Annex B start-code validation before pointer conversion.
- Parameter/session changes are serialized on the decoder queue.
- Actual VideoToolbox errors are checked. A successful dropped frame is not
  treated as corrupt data; a failed prediction stream is reconnected as a whole.
- Encoder creation requires hardware support through VideoToolbox's encoder
  specification (not a nonexistent hardware-encode query or a decode-capability
  check). A failed encoder is not recreated from every incoming frame.
- The old sample-attachment ordering fix is superseded: upstream removed the
  ineffective decoder DisplayImmediately attachment. The host schedules output.

### Useful: Ecamm integration and diagnostics

- `logHandler` forwards diagnostics to the host. Ecamm relays these across XPC
  into `EcammLog` using `VideoPencil:`. Without a handler, the fallback also uses
  `VideoPencil:` rather than the colored-square emoji.
- Connection diagnostics now report our type-18 advertisement, the peer's parsed
  timestamp capability (including an absent flag or invalid JSON), and the actual
  outgoing-video/incoming-drawing wire types: 17 for timestamps, 2 for legacy.
  Repeated capabilities/frame types are silent; reconnects and mode changes log
  again. This establishes protocol use, not the iPad's actual playback behavior.
- An optional streaming-state callback lets Ecamm stop preparing source frames
  when the iPad cancels its stream, even if the TCP connection remains open.
- Decoder output is IOSurface-backed for the helper's cross-process handoff.
- Encoder dimensions honor the client's requested `size`, with checked integer
  conversion. Ecamm's 540p smoothness comparison supplies 960x540 snapshots;
  leaving the encoder hard-coded to 1920x1080 would not test actual 540p encoding.
  The incoming drawing decoder remains 1920x1080. Frame rate and keyframe
  settings are unchanged, and hosts supplying 1920x1080 keep that size.
- `encoderBitRate` is exposed to Objective-C hosts, in bits/second, and must be
  set on the owner queue before streaming starts. Its upstream default remains
  1,920,000 bps; Ecamm now requests 900,000 bps for its 960x540 feed.
- The encoder's one-second burst limit now correctly converts bits to bytes:
  `[Int64(bitRate) * 3 / 8, 1]`. At 900 kbps this requests a 337,500-byte limit
  (2.7 Mbps), three times the average, giving motion more headroom than the
  previous 2.4 Mbps cap. The original bits/bytes bug accidentally requested
  sixteen times the average. Rejected settings are logged through the host.
- `ShootCamera` uses the decoder's queue-confined parameter setter and explicit
  invalidation too, so shared decoder changes do not leave that caller behind.
- The unused `CMTime: SliderValueType` camera-control conformance is restricted
  to macOS 13+, matching Apple's `CMTime: Hashable` availability. Video Pencil
  does not use this conformance, and its streaming API remains available on
  Ecamm's macOS 12 minimum. The 11.3 low-latency creation option is available there;
  the macOS 13 conformance guard is still needed on macOS 12.

### Low-latency encoder configuration experiment

- `EnableLowLatencyRateControl` is now passed in `encoderSpecification` to
  `VTCompressionSessionCreate`, as Apple documents, rather than sent to
  `VTSessionSetProperty` afterwards with its result ignored.
- If creation fails, invalidate any partial session and retry once without that
  option. Both attempts require hardware HEVC; there is no software fallback.
  The same retained callback owner remains alive through creation/teardown, and
  a final failure releases it. No new retries occur in the per-frame path.
- The log states whether creation accepted low-latency rate control or required
  the standard-hardware fallback, including the original failure status.
- This is a bounded experiment for encoding delay/variation, not a claim that
  iPad playback stutter is fixed. Keyframe interval (30), requested frame rate,
  960x540 feed, 900 kbps average, 3x burst cap, timestamp buffering, and send order
  remain unchanged. Initialization and logging stay inside the XPC helper.
- On the tested Apple Silicon Mac, low-latency creation and both bitrate setters
  succeed, and encoded frames preserve source PTS. DataRateLimits readback returns
  `kVTPropertyNotSupportedErr` in this mode, so the diagnostic reports that limitation
  rather than claiming it measured an enforced burst ceiling. It still rejects
  setter failures and unexpected readback errors.

### Upstream timestamps, with narrow input/lifecycle safeguards

- Michael's encoder delegate carries the encoded sample's source PTS. Both peers
  announce JSON capabilities (type 18); type 17 frames are sent only when the peer
  advertises `acceptsVideoFrameHeaders`. Legacy peers continue to receive type 2.
- The frame body is upstream's UInt32 little-endian JSON length, VideoFrameHeader
  JSON, then HEVC. Optional duration/DTS are accepted; the current upstream encoder
  emits only PTS. There is no Ecamm-private ECPTS1 wire extension in this fork.
- Capability state resets on every stop/new connection, including replacement
  after connection became nil. This prevents sending headers to an older peer.
- Header parsing bounds JSON at 64 KiB and total payload at 16 MiB; validates
  numeric epoch-zero times and finite ranges; rejects an empty compressed body.
  Malformed headers report a decoder failure so the client restarts the prediction
  chain rather than skipping compressed frames and corrupting later predictions.
- RemoteClockMap is Michael's minimum-arrival-delay/drift-limited estimator with
  its 70 ms cushion, not the earlier private experiment's fixed 250 ms mapping.
  Arrival time is captured before queueing, while parsing/map/session state are
  confined to the decoder queue. Parameter changes reset the map; backwards clocks
  or large clock discontinuities re-anchor it. A warm-up estimate change cannot
  schedule a newer frame before its predecessor.
- Ecamm forwards the translated host-clock PTS across XPC. Its worker publishes
  an owned drawing when due, with an eight-buffer bound and a generation guard
  against post-disconnect drawings. The helper reply acknowledges the copy, not
  the future display time. Nothing waits or schedules playback on the render thread.
- The independent Mac test receiver now negotiates this same upstream wire format,
  while retaining its diagnostic fixed 250 ms playback cushion.

## Deliberately excluded

There is no custom 30-fps source scheduler, encoder submission window, decoder
FIFO/submission window, compressed-frame replacement, send FIFO, keyframe
resynchronization policy, forced flush, TCP_NODELAY change, or experimental
frame-rate/keyframe-interval tuning. Apart from Michael's upstream timestamp
playout, the low-latency creation option, and the explicit feed size/bitrate settings above, original codec settings
and ordered sends remain.
Per-message limits are not a claim that all internal
Network/VideoToolbox queues have bounded total memory.

There is no TLS or cryptographic device identity. Approval still trusts the
Bonjour service name on the local network, as explicitly chosen for Ecamm.

## Host threading and ownership contract

ShootKit itself is **not a real-time-safe render-thread API**. Initialization,
frame rasterization, and codec work can block. Ecamm links it only into a bundled
XPC service, never into the main app. The Objective-C bridge, service target,
permission UI, and aspect mapping live in Ecamm's repository, not this framework.

The host uses one serial callback/owner queue for client calls and state. The
authorization and connection delegate notifications arrive on main; streaming
and decoded-frame callbacks use the supplied queue. Host log hooks must be safe
from codec/background callbacks too. Explicit disconnect/reconnect enqueue on
the owner queue; call other stateful APIs on that queue.

Direct `CIImage(cvPixelBuffer:)` inputs must own pixels that will not be mutated
until the encoder releases them. Ecamm's helper makes a separate pool-backed
snapshot before acknowledging an incoming IOSurface. Decoded output is retained
until the main app acknowledges its own copy. An IOSurface reference alone is
not sufficient to prevent a producer's original CVPixelBuffer pool from reuse.

Ecamm bounds its raw-frame and decoded-drawing XPC handoffs and drops only
unsubmitted raw frames or already-decoded drawings when busy. It does not drop
arbitrary compressed prediction frames. The render thread never waits for
ShootKit, a helper reply, rasterization, or a drawing lock. Frame preparation,
16:9 letterboxing/pillarboxing, and IPC run on background workers.

The Ecamm helper watchdog terminates a service whose owner queue stops making
progress. This isolates a third-party stall; it is not a guarantee against every
OS/GPU stall or an independently stalled internal codec queue. Physical-iPad
testing remains necessary before shipping.
