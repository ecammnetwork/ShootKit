//
//  VideoConnectionDesktopState.swift
//  Video Pencil Camera
//
//  Created by Michael Forrest on 07/12/2022.
//

import Foundation
import Network
import VideoToolbox
import AppKit
import CoreImage

@objc public protocol VideoPencilClientDelegate: AnyObject {
    func videoPencilDidConnect(_ client: VideoPencilClient)
    func videoPencilDidDisconnect(_ client: VideoPencilClient)
    func videoPencilDidReceive(from: VideoPencilClient, frame: CIImage, presentationTimeStamp: CMTime, presentationDuration: CMTime)

    // Ecamm: Hosts can make a first-use privacy decision before ShootKit opens
    // a TCP connection or exchanges any video with the discovered device.
    @objc optional func videoPencil(_ client: VideoPencilClient,
                                    shouldConnectToDeviceNamed deviceName: String,
                                    identifier: String,
                                    decisionHandler: @escaping (Bool) -> Void)
}

@objc public class VideoPencilClient: NSObject, ObservableObject {
    private struct PendingSourceFrame {
        let image: CIImage
        let presentationTimeStamp: CMTime
        let presentationDuration: CMTime
    }

    private struct PendingEncodedFrame {
        let data: Data
        let isKeyFrame: Bool
    }

    // Ecamm: Video Pencil's transport and drawing coordinates use one predictable
    // 16:9 raster. Non-16:9 host video is aspect-fitted into this canvas.
    private static let encodedFrameSize = CGSize(width: 1920, height: 1080)
    private static let maximumSourceFramesPerSecond = 30.0
    private static let pixelBufferPoolCapacity = 3

    public var logger = BaseConnectionLogger()

    // Ecamm: A host logger avoids framework-only emoji output and lets Ecamm put
    // connection and codec diagnostics into the same log as the rest of the app.
    @objc public var logHandler: ((String) -> Void)?

    @objc public var name: String
    @objc public var size: CGSize
    @objc public private(set) var remoteDeviceName = ""
    @objc public private(set) var remoteDeviceIdentifier = ""

    // Ecamm: Expose the transport raster with the active content rectangle so
    // Objective-C hosts can map decoded overlay coordinates without hard-coding
    // ShootKit's 1920x1080 implementation detail.
    @objc public var videoFrameSize: CGSize {
        Self.encodedFrameSize
    }

    // Ecamm: The host uses this rectangle to map the returned 1920x1080 drawing
    // back over the original source while excluding any pillarbox/letterbox bars.
    @objc public var videoContentRect: CGRect {
        Self.aspectFitRect(sourceSize: size, destinationSize: Self.encodedFrameSize)
    }

    @Published var hasReceivedControlMessage = false
    @Published var mostRecentVideoSelection: String?
    @Published var latestCompressedSampleBuffer: CMSampleBuffer?
    @Published var encoderBitRate: Int32 = 1920 * 1000

    private let ciContext: CIContext
    private let queue: DispatchQueue
    private let frameQueue: DispatchQueue
    private let frameStateLock = NSLock()

    // These properties are protected by frameStateLock. sendFrame may be called
    // from a real-time render thread while connection changes happen on queue.
    private var pendingSourceFrame: PendingSourceFrame?
    private var frameWorkerRunning = false
    private var frameStreamingEnabled = false
    private var lastAcceptedSourceFrameTime: TimeInterval = 0
    private var pixelBufferPool: CVPixelBufferPool?

    var encoder: H265Encoder?
    var decoder: H265Decoder?

    // Network and codec lifecycle state below is confined to queue.
    @Published var connection: NWConnection?
    private var pendingAuthorizationIdentifier: String?
    private var receivePending = false
    private var didNotifyConnected = false
    private var reconnectScheduled = false
    private var reconnectGeneration = 0
    private var videoSendInFlight = false
    private var pendingEncodedVideoFrame: PendingEncodedFrame?
    private var hasSentParameterSet = false
    private var waitingForEncodedKeyFrame = false
    private var videoStreamGeneration = 0

    let bonjourBrowser = ShootKit.nwBrowser(for: .videoPencilApp)
    weak var delegate: VideoPencilClientDelegate?

    public var hasConnection: Bool {
        connection != nil
    }

    @objc public init(name: String,
                      size: CGSize,
                      delegate: VideoPencilClientDelegate,
                      queue: DispatchQueue,
                      ciContext: CIContext? = nil) {
        self.name = name
        self.size = size
        self.delegate = delegate
        self.queue = queue
        self.frameQueue = DispatchQueue(label: "Video Pencil Frame Queue", qos: .userInitiated)
        self.ciContext = ciContext ?? CIContext()
        super.init()
        startBonjourDiscovery()
    }

    deinit {
        // Ecamm: Break Network.framework callback ownership explicitly. The old
        // browser and connection handlers captured the client strongly, so clients
        // recreated after an output-size change could remain alive forever.
        bonjourBrowser.browseResultsChangedHandler = nil
        bonjourBrowser.cancel()
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        encoder?.invalidate()
        decoder?.invalidate()
    }

    private func startBonjourDiscovery() {
        bonjourBrowser.browseResultsChangedHandler = { [weak self] newResults, changes in
            guard let self = self else { return }
            self.log(message: "Bonjour results changed \(newResults.debugDescription)", color: NSColor.brown)

            if let connection = self.connection {
                let endpointDisappeared = !newResults.contains(where: { $0.endpoint == connection.endpoint })
                if endpointDisappeared {
                    // Ecamm: Notify the host immediately rather than waiting for a
                    // cancelled callback after connection has already been cleared.
                    self.log(message: "Video Pencil endpoint disappeared, cancelling connection", color: .red)
                    self.stopConnection(notifyDelegate: true)
                    self.scheduleReconnect()
                }
            } else if let result = newResults.first {
                self.connectIfAuthorized(to: result)
            }
        }

        if let service = bonjourBrowser.browseResults.first {
            connectIfAuthorized(to: service)
        }
        bonjourBrowser.start(queue: queue)
    }

    private func start() {
        guard connection == nil, let result = bonjourBrowser.browseResults.first else { return }
        connectIfAuthorized(to: result)
    }

    private func scheduleReconnect() {
        // Ecamm: Coalesce failure and viability callbacks into one delayed attempt.
        // The delay also avoids a tight connection loop when the peer is unhealthy.
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        let generation = reconnectGeneration
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self,
                  self.reconnectScheduled,
                  self.reconnectGeneration == generation
            else { return }
            self.reconnectScheduled = false
            self.start()
        }
    }

    private func deviceInfo(for result: NWBrowser.Result) -> (name: String, identifier: String) {
        // Ecamm: Bonjour service names provide the user-facing identity used by
        // the host approval list without exposing a transient network address.
        if case let .service(name, _, _, _) = result.endpoint {
            let prefix = "Video Pencil on "
            let displayName = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
            return (displayName, name)
        }
        let fallbackName = result.endpoint.debugDescription
        return (fallbackName, fallbackName)
    }

    private func connectIfAuthorized(to result: NWBrowser.Result) {
        guard connection == nil else { return }

        let device = deviceInfo(for: result)
        remoteDeviceName = device.name
        remoteDeviceIdentifier = device.identifier
        guard pendingAuthorizationIdentifier == nil else { return }
        pendingAuthorizationIdentifier = device.identifier

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.delegate?.videoPencil?(self,
                                           shouldConnectToDeviceNamed: device.name,
                                           identifier: device.identifier,
                                           decisionHandler: { [weak self] allowed in
                                               self?.finishAuthorization(allowed, for: result, identifier: device.identifier)
                                           }) == nil {
                // Preserve upstream automatic connection behavior for hosts that
                // do not implement the optional authorization delegate method.
                self.finishAuthorization(true, for: result, identifier: device.identifier)
            }
        }
    }

    private func finishAuthorization(_ allowed: Bool,
                                     for result: NWBrowser.Result,
                                     identifier: String) {
        queue.async { [weak self] in
            guard let self = self,
                  self.pendingAuthorizationIdentifier == identifier
            else { return }

            self.pendingAuthorizationIdentifier = nil
            guard allowed,
                  self.connection == nil,
                  self.bonjourBrowser.browseResults.contains(where: { $0.endpoint == result.endpoint })
            else { return }
            self.connectToIPad(at: result)
        }
    }

    private func connectToIPad(at networkBrowserResult: NWBrowser.Result) {
        guard connection == nil else { return }

        log(message: "Attempt to connect to Video Pencil at \(networkBrowserResult) port \(networkBrowserResult.metadata)", color: .systemMint)
        let newConnection = NWConnection(to: networkBrowserResult.endpoint, using: ShootKit.applicationServiceParameters())
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            self?.handleConnectionStateChanges(state, for: newConnection)
        }
        newConnection.viabilityUpdateHandler = { [weak self, weak newConnection] isViable in
            guard let self = self,
                  let newConnection = newConnection,
                  newConnection === self.connection,
                  !isViable
            else { return }

            self.log(message: "Connection viability lost, scheduling reconnection", color: .systemRed)
            self.stopConnection(notifyDelegate: true)
            self.scheduleReconnect()
        }

        connection = newConnection
        newConnection.start(queue: queue)

        // Send the host name as the connection's initial unframed handshake data.
        newConnection.send(content: name.data(using: .unicode), completion: .idempotent)
    }

    private func handleConnectionStateChanges(_ newState: NWConnection.State,
                                              for stateConnection: NWConnection?) {
        guard let stateConnection = stateConnection, stateConnection === connection else { return }

        switch newState {
        case .ready:
            log(message: "Video Pencil connection ready, awaiting message", color: .systemMint)
            didNotifyConnected = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoPencilDidConnect(self)
            }
            awaitNextMessage()

        case .failed(let error):
            log(message: "Video Pencil connection failed: " + error.localizedDescription, color: .systemRed)
            stopConnection(notifyDelegate: true)
            scheduleReconnect()

        case .preparing:
            log(message: "Preparing connection to Video Pencil... \(stateConnection.parameters)", color: .systemMint)

        case .waiting(let error):
            log(message: "Waiting for Video Pencil connection: \(error.localizedDescription)", color: .orange)

        case .cancelled:
            log(message: "Video Pencil connection cancelled \(stateConnection.endpoint.debugDescription)", color: .systemRed)
            stopConnection(notifyDelegate: true, cancelConnection: false)
            scheduleReconnect()

        default:
            log(message: "Video Pencil Connection state changed to \(newState)", color: .orange)
        }
    }

    private func startVideoStream() {
        cancelVideoStream()
        hasSentParameterSet = false
        pendingEncodedVideoFrame = nil
        videoSendInFlight = false
        waitingForEncodedKeyFrame = false

        let targetSize = Self.encodedFrameSize
        let newEncoder = H265Encoder(width: Int32(targetSize.width),
                                     height: Int32(targetSize.height),
                                     bitRate: encoderBitRate,
                                     fps: Int32(Self.maximumSourceFramesPerSecond),
                                     callbackQueue: queue)
        newEncoder.delegate = self
        encoder = newEncoder

        guard newEncoder.isReady else {
            log(message: "Video Pencil hardware HEVC encoder is unavailable", color: .systemRed)
            newEncoder.invalidate()
            encoder = nil
            return
        }

        // Ecamm: The render producer is enabled only after the iPad requests a
        // stream and the hardware encoder has been created successfully.
        setFrameStreamingEnabled(true)
    }

    private func cancelVideoStream() {
        // Ecamm: Invalidate completions from the previous encoder stream before
        // clearing its state. Network.framework may deliver them after a new
        // stream has already started on the same TCP connection.
        videoStreamGeneration += 1
        setFrameStreamingEnabled(false)
        encoder?.invalidate()
        encoder = nil
        pendingEncodedVideoFrame = nil
        videoSendInFlight = false
        hasSentParameterSet = false
        waitingForEncodedKeyFrame = false
    }

    private func send<T>(basicMessage: BasicControlMessage<T>) {
        guard let data = try? JSONEncoder().encode(basicMessage),
              let connection = connection
        else { return }

        let message = NWProtocolFramer.Message(videoMessageType: .control)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [message])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                self?.log(message: "Error sending control message " + error.debugDescription, color: .red)
            }
        }))
    }

    private func awaitNextMessage() {
        // Ecamm: Maintain exactly one outstanding receive. Upstream registered a
        // receive before ready, another on ready, and another after control sends.
        guard !receivePending,
              let currentConnection = connection,
              currentConnection.state == .ready
        else { return }

        receivePending = true
        currentConnection.receiveMessage { [weak self, weak currentConnection] content, context, isComplete, error in
            guard let self = self else { return }
            self.queue.async {
                guard let currentConnection = currentConnection,
                      currentConnection === self.connection
                else { return }

                self.receivePending = false
                if let message = context?.protocolMetadata(definition: VideoProtocol.definition) as? NWProtocolFramer.Message {
                    self.handleReceivedMessage(message, content: content)
                }

                if let error = error {
                    self.log(message: "Error receiving message \(error)", color: .red)
                    self.stopConnection(notifyDelegate: true)
                    self.scheduleReconnect()
                } else {
                    self.awaitNextMessage()
                }
            }
        }
    }

    private func handleReceivedMessage(_ message: NWProtocolFramer.Message, content: Data?) {
        switch message.videoMessageType {
        case .requestVideoStream:
            log(message: "Video stream requested by Video Pencil", color: .systemOrange)
            startVideoStream()

        case .cancelVideoStream:
            log(message: "Video stream cancelled by Video Pencil", color: .systemOrange)
            cancelVideoStream()

        case .hevcParameterSet:
            guard let frame = content,
                  frame.count <= 64 * 1024,
                  let parameterSet = try? JSONDecoder().decode(H265ParameterSet.self, from: frame)
            else {
                log(message: "Rejected invalid HEVC parameter set from Video Pencil", color: .systemRed)
                return
            }

            log(message: "HEVC parameter set received from Video Pencil (decoder exists? \(decoder != nil))", color: .systemOrange)
            createDecoderIfNeeded()
            decoder?.setParameterSet(parameterSet.parameters)

        case .videoFrame:
            guard let frame = content else { return }
            decode(frame: frame)

        case .invalid, .cameraAvailable, .handshake:
            break

        default:
            break // Unknown future messages are intentionally ignored.
        }
    }

    func send(controlMessage: VideoPencilControlMessage) {
        let message = BasicControlMessage(command: controlMessage)
        send(basicMessage: message)
    }

    private func createDecoderIfNeeded() {
        if decoder == nil {
            let targetSize = Self.encodedFrameSize
            decoder = H265Decoder(width: Int32(targetSize.width),
                                  height: Int32(targetSize.height),
                                  callbackQueue: queue)
            decoder?.delegate = self
        }
    }

    private func decode(frame: Data) {
        createDecoderIfNeeded()
        decoder?.decode(frame)
    }

    @objc enum RenderError: Int, Error {
        case formatDescriptionUnavailable
        case sampleBufferNotCreated
    }

    @objc public func sendFrame(_ image: CIImage,
                                presentationTimeStamp: CMTime,
                                presentationDuration: CMTime) throws {
        let now = ProcessInfo.processInfo.systemUptime
        var shouldStartWorker = false

        frameStateLock.lock()
        if frameStreamingEnabled {
            // Ecamm: Throttle before retaining the CIImage. At 60 fps this avoids
            // even creating work that the 30 fps Video Pencil stream cannot use.
            let minimumInterval = 1.0 / Self.maximumSourceFramesPerSecond
            if lastAcceptedSourceFrameTime == 0 || now - lastAcceptedSourceFrameTime >= minimumInterval {
                lastAcceptedSourceFrameTime = now
                pendingSourceFrame = PendingSourceFrame(image: image,
                                                        presentationTimeStamp: presentationTimeStamp,
                                                        presentationDuration: presentationDuration)
                if !frameWorkerRunning {
                    frameWorkerRunning = true
                    shouldStartWorker = true
                }
            }
        }
        frameStateLock.unlock()

        // Ecamm: sendFrame returns without rasterizing or invoking VideoToolbox.
        // This is the key guarantee that keeps host render loops responsive.
        if shouldStartWorker {
            frameQueue.async { [weak self] in
                self?.drainSourceFrames()
            }
        }
    }

    private func drainSourceFrames() {
        while true {
            frameStateLock.lock()
            guard let sourceFrame = pendingSourceFrame else {
                frameWorkerRunning = false
                frameStateLock.unlock()
                return
            }
            pendingSourceFrame = nil
            frameStateLock.unlock()

            autoreleasepool {
                guard framesAreEnabled(),
                      let pixelBuffer = renderSourceFrameToPixelBuffer(sourceFrame.image)
                else { return }

                // Encoder and connection ownership is confined to queue. The
                // frame worker only prepares a uniquely retained pixel buffer.
                queue.async { [weak self] in
                    guard let self = self,
                          self.framesAreEnabled(),
                          let connection = self.connection,
                          connection.state == .ready,
                          let encoder = self.encoder
                    else { return }

                    encoder.encode(pixelBuffer: pixelBuffer,
                                   presentationTimeStamp: sourceFrame.presentationTimeStamp,
                                   duration: sourceFrame.presentationDuration)
                }
            }
        }
    }

    private func setFrameStreamingEnabled(_ enabled: Bool) {
        frameStateLock.lock()
        frameStreamingEnabled = enabled
        if !enabled {
            pendingSourceFrame = nil
            lastAcceptedSourceFrameTime = 0
        }
        frameStateLock.unlock()
    }

    private func framesAreEnabled() -> Bool {
        frameStateLock.lock()
        let enabled = frameStreamingEnabled
        frameStateLock.unlock()
        return enabled
    }

    private func renderSourceFrameToPixelBuffer(_ image: CIImage) -> CVPixelBuffer? {
        guard let normalizedImage = normalizedSourceImage(image),
              let pool = sourcePixelBufferPool()
        else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let allocationOptions = [
            kCVPixelBufferPoolAllocationThresholdKey: Self.pixelBufferPoolCapacity
        ] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
                                                                         pool,
                                                                         allocationOptions,
                                                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else {
            // A full pool means the encoder still owns prior frames. Dropping is
            // intentional; allocating outside the bound would reintroduce backlog.
            return nil
        }

        let bounds = CGRect(origin: .zero, size: Self.encodedFrameSize)
        ciContext.render(normalizedImage, to: pixelBuffer, bounds: bounds, colorSpace: nil)
        return pixelBuffer
    }

    private func sourcePixelBufferPool() -> CVPixelBufferPool? {
        if let pixelBufferPool = pixelBufferPool {
            return pixelBufferPool
        }

        let size = Self.encodedFrameSize
        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey: Self.pixelBufferPoolCapacity
        ] as CFDictionary
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             poolAttributes,
                                             pixelAttributes as CFDictionary,
                                             &newPool)
        guard status == kCVReturnSuccess else {
            log(message: "Could not create Video Pencil pixel buffer pool: \(status)", color: .red)
            return nil
        }
        pixelBufferPool = newPool
        return newPool
    }

    private func normalizedSourceImage(_ image: CIImage) -> CIImage? {
        let sourceExtent = image.extent
        guard !sourceExtent.isEmpty,
              !sourceExtent.isInfinite,
              sourceExtent.width.isFinite,
              sourceExtent.height.isFinite
        else { return nil }

        let targetRect = CGRect(origin: .zero, size: Self.encodedFrameSize)
        let fittedRect = Self.aspectFitRect(sourceSize: sourceExtent.size,
                                            destinationSize: targetRect.size)

        // Move arbitrary Core Image coordinates to zero before scaling, then
        // center the result in the 16:9 transport canvas.
        var fittedImage = image.transformed(by: CGAffineTransform(translationX: -sourceExtent.minX,
                                                                  y: -sourceExtent.minY))
        fittedImage = fittedImage.transformed(by: CGAffineTransform(scaleX: fittedRect.width / sourceExtent.width,
                                                                    y: fittedRect.height / sourceExtent.height))
        fittedImage = fittedImage.transformed(by: CGAffineTransform(translationX: fittedRect.minX,
                                                                    y: fittedRect.minY))

        // Video Pencil should see deterministic black bars rather than undefined
        // pixels outside a non-16:9 source image.
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: targetRect)
        return fittedImage.composited(over: background).cropped(to: targetRect)
    }

    private static func aspectFitRect(sourceSize: CGSize, destinationSize: CGSize) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0
        else { return CGRect(origin: .zero, size: destinationSize) }

        let scale = min(destinationSize.width / sourceSize.width,
                        destinationSize.height / sourceSize.height)
        let fittedSize = CGSize(width: sourceSize.width * scale,
                                height: sourceSize.height * scale)
        return CGRect(x: (destinationSize.width - fittedSize.width) / 2,
                      y: (destinationSize.height - fittedSize.height) / 2,
                      width: fittedSize.width,
                      height: fittedSize.height)
    }

    private func stopConnection(notifyDelegate: Bool, cancelConnection: Bool = true) {
        // This method is queue-confined. It updates host-visible state before
        // cancelling so a later Network.framework callback cannot be lost.
        pendingAuthorizationIdentifier = nil
        receivePending = false
        reconnectGeneration += 1
        reconnectScheduled = false
        cancelVideoStream()
        decoder?.invalidate()
        decoder = nil

        let oldConnection = connection
        connection = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.viabilityUpdateHandler = nil
        if cancelConnection {
            oldConnection?.cancel()
        }

        if notifyDelegate && didNotifyConnected {
            didNotifyConnected = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoPencilDidDisconnect(self)
            }
        } else if !notifyDelegate {
            didNotifyConnected = false
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopConnection(notifyDelegate: true)
        }
    }

    @objc public func disconnect() {
        // Ecamm: External permission revocation uses the same serialized teardown
        // as network loss, including stopping both video directions immediately.
        stop()
    }

    @objc public func reconnect() {
        // Ecamm: Reconnection always passes through host authorization again.
        queue.async { [weak self] in
            self?.start()
        }
    }
}

extension VideoPencilClient: H265EncoderDelegate {
    func videoEncoderDidExtractParameterSet(_ encoder: H265Encoder, parameterSet frames: [Data]) {
        guard encoder === self.encoder,
              let connection = connection,
              let data = try? JSONEncoder().encode(H265ParameterSet(parameters: frames))
        else { return }

        log(message: "Sending encoder parameters to Video Pencil", color: .blue)
        let generation = videoStreamGeneration
        let message = NWProtocolFramer.Message(videoMessageType: .hevcParameterSet)
        let context = NWConnection.ContentContext(identifier: "parameterSet", metadata: [message])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self, weak connection, weak encoder] error in
            guard let self = self else { return }
            self.queue.async {
                guard let connection = connection,
                      connection === self.connection,
                      let encoder = encoder,
                      encoder === self.encoder,
                      generation == self.videoStreamGeneration
                else { return }
                if let error = error {
                    self.log(message: "Error sending encoder parameters " + error.debugDescription, color: .red)
                } else {
                    self.hasSentParameterSet = true
                    // Ecamm: Frames encoded while the parameter-set send was in
                    // flight may depend on frames intentionally discarded during
                    // that wait. Keep the original keyframe, then force a fresh
                    // prediction chain for all subsequent video.
                    if self.pendingEncodedVideoFrame?.isKeyFrame == false {
                        self.pendingEncodedVideoFrame = nil
                    }
                    self.waitingForEncodedKeyFrame = true
                    self.encoder?.requestKeyFrame()
                    self.sendNextEncodedVideoData()
                }
            }
        }))
    }

    func videoEncoderDidYieldVideoData(_ encoder: H265Encoder,
                                      compressedVideo data: Data,
                                      isKeyFrame: Bool) {
        guard encoder === self.encoder, !data.isEmpty else { return }
        let frame = PendingEncodedFrame(data: data, isKeyFrame: isKeyFrame)

        // Ecamm: Preserve the first keyframe while its parameter set is being
        // acknowledged. Later prediction frames cannot be sent safely if any
        // predecessor was discarded during that wait.
        guard hasSentParameterSet else {
            if pendingEncodedVideoFrame == nil || isKeyFrame {
                pendingEncodedVideoFrame = frame
            }
            return
        }

        if waitingForEncodedKeyFrame {
            guard isKeyFrame else { return }
            waitingForEncodedKeyFrame = false
            pendingEncodedVideoFrame = frame
            sendNextEncodedVideoData()
            return
        }

        if pendingEncodedVideoFrame != nil {
            // Ecamm: The one-frame waiting slot is full. Dropping arbitrary HEVC
            // prediction frames would corrupt the receiver's reference chain, so
            // discard until a newly forced keyframe can replace the waiting frame.
            waitingForEncodedKeyFrame = true
            encoder.requestKeyFrame()
            log(message: "Video sender fell behind; resynchronizing at a keyframe", color: .orange)
            return
        }

        pendingEncodedVideoFrame = frame
        sendNextEncodedVideoData()
    }

    private func sendNextEncodedVideoData() {
        guard hasSentParameterSet,
              !videoSendInFlight,
              let frame = pendingEncodedVideoFrame,
              let connection = connection,
              connection.state == .ready
        else { return }

        pendingEncodedVideoFrame = nil
        videoSendInFlight = true
        let generation = videoStreamGeneration
        let message = NWProtocolFramer.Message(videoMessageType: .videoFrame)
        let context = NWConnection.ContentContext(identifier: "videoFrame", metadata: [message])
        connection.send(content: frame.data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self, weak connection] error in
            guard let self = self else { return }
            self.queue.async {
                guard let connection = connection,
                      connection === self.connection,
                      generation == self.videoStreamGeneration
                else { return }
                self.videoSendInFlight = false
                if let error = error {
                    self.log(message: "Error sending encoded video: " + error.debugDescription, color: .red)
                }
                self.sendNextEncodedVideoData()
            }
        }))
    }

    func videoEncoderDidEncodeSampleBuffer(_ encoder: H265Encoder, sampleBuffer: CMSampleBuffer) {
    }

    func videoEncoderDidFail(_ encoder: H265Encoder, error: OSStatus) {
        guard encoder === self.encoder else { return }
        log(message: "Video Pencil encoder failed: \(OSErrorCodeDescription(error))", color: .red)
        cancelVideoStream()
    }
}

extension VideoPencilClient: ConnectionLogger {
    public func log(_ text: String, color: NSColor) {
        if let logHandler = logHandler {
            logHandler(text)
        } else {
            // Ecamm: Keep fallback messages searchable and remove upstream's
            // color-square emoji prefix.
            print("VideoPencil:", text)
        }
    }

    public func log(message: String, color: NSColor) {
        log(message, color: color)
    }
}

extension VideoPencilClient: H265DecoderDelegate {
    func videoDecoderDidDecodePixelBuffer(_ decoder: H265Decoder,
                                          pixelBuffer: CVPixelBuffer,
                                          presentationTimeStamp: CMTime,
                                          presentationDuration: CMTime) {
        guard decoder === self.decoder else { return }
        delegate?.videoPencilDidReceive(from: self,
                                        frame: CIImage(cvPixelBuffer: pixelBuffer),
                                        presentationTimeStamp: presentationTimeStamp,
                                        presentationDuration: presentationDuration)
    }

    func videoDecoder(_ decoder: H265Decoder, failedWith error: OSStatus) {
        guard decoder === self.decoder else { return }
        log(message: "Video Pencil decoder failed: \(OSErrorCodeDescription(error))", color: .red)
    }
}
