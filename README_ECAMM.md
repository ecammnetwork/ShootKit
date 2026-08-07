# Ecamm ShootKit branch

The `ecamm` branch of `ecammnetwork/ShootKit` contains the Video Pencil changes
used by Ecamm Live. It is kept as a small fork so the integration does not
depend on edits inside a generated CocoaPods checkout. The changes are
intentionally documented in the source with comments beginning with `Ecamm:`
so they are easy to review and upstream independently.

## Host integration additions

- `VideoPencilClientDelegate` has an optional authorization callback. A host can
  approve a discovered Bonjour service before ShootKit opens the TCP connection
  or exchanges video.
- `remoteDeviceName` and `remoteDeviceIdentifier` expose the Bonjour identity
  associated with the current connection.
- `disconnect()` and `reconnect()` let a host apply permission changes without
  recreating its render engine.
- `logHandler` routes ShootKit messages into the host application's logging
  system. When no handler is installed, messages use the searchable
  `VideoPencil:` prefix instead of the original colored-square emoji.
- `videoContentRect` reports the active-picture area inside the fixed 1920x1080
  transport frame. Hosts use this to map the returned drawing over a source
  that was pillarboxed or letterboxed.

## Render and codec safety

- `sendFrame` no longer rasterizes Core Image or creates VideoToolbox sessions
  on the caller's thread. It stores only the newest source frame and returns.
- Source-frame preparation runs on a dedicated queue and is capped at 30 fps.
- Every source shape is aspect-fitted into a black 1920x1080 canvas. Tall and
  narrow sources are pillarboxed; extra-wide sources are letterboxed.
- A three-buffer `CVPixelBufferPool` bounds prepared-frame memory. Pool
  exhaustion drops a frame instead of allocating without limit.
- The HEVC encoder and decoder permit one frame in flight and one newest waiting
  frame. Their pre-codec dispatch handoffs are latest-only too, so a stalled
  VideoToolbox queue cannot retain an unbounded sequence of frame closures.
- The network sender permits one send in flight and one waiting compressed frame.
  On overflow it discards prediction frames and forces a new keyframe, keeping
  slow Wi-Fi bounded without sending a broken HEVC reference chain.
- ShootKit requires a hardware HEVC encoder and does not repeatedly create a
  failed encoder from the host render loop.

## Memory and lifecycle fixes

- The VideoToolbox encoder callback retain is balanced during asynchronous
  invalidation. This replaces the previous permanent `passRetained` leak.
- Decoder input is copied into Core Media-owned memory before asynchronous
  decoding. The old implementation referenced temporary Swift array storage.
- HEVC parameter-set pointers now reference stable `NSData` storage during Core
  Media format-description creation.
- Decoder input is latest-frame bounded, matching the outbound encoder policy.
- Bonjour, connection, and viability handlers capture the client weakly and are
  cleared during teardown.
- Connection loss notifies the host before clearing the connection, so a
  cancelled callback cannot be accidentally suppressed.
- Only one `receiveMessage` operation is outstanding at a time.
- Encoder and decoder teardown is asynchronous and never waits on the host's
  render or UI thread.

## Protocol hardening

- The custom network framer rejects messages larger than 16 MB before asking
  Network.framework to buffer the body.
- HEVC parameter sets have tighter count and size validation.
- This branch deliberately retains ShootKit's existing local-network TCP
  transport. It does **not** add TLS or cryptographic device identity.

## Ecamm-side behavior

Ecamm Live remembers the approved Bonjour service name in its Remote Control
preferences, logs connection activity with the `VideoPencil:` prefix, and
removes the 16:9 transport bars before scaling the transparent drawing back over
the original program or preview shape.
