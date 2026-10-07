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

@objc public protocol VideoPencilClientDelegate: AnyObject{
    func videoPencilDidConnect(_ client: VideoPencilClient)
    func videoPencilDidDisconnect(_ client: VideoPencilClient)
    func videoPencilDidReceive(from: VideoPencilClient, frame: CIImage, presentationTimeStamp: CMTime, presentationDuration: CMTime)
    // Ecamm: Approval precedes TCP/video; existing hosts retain automatic discovery.
    @objc optional func videoPencil(_ client: VideoPencilClient, shouldConnectToDeviceNamed name: String,
                                    identifier: String, decisionHandler: @escaping (Bool) -> Void)
    // Ecamm: The XPC host stops producing frames when the iPad stops requesting them.
    @objc optional func videoPencil(_ client: VideoPencilClient, streamingChanged streaming: Bool)
}

@objc public class VideoPencilClient: NSObject, ObservableObject{
    public var logger = BaseConnectionLogger()
    // Ecamm: Route framework diagnostics back through the application's EcammLog.
    @objc public var logHandler: ((String) -> Void)?
    @objc public private(set) var remoteDeviceName = ""
    @objc public private(set) var remoteDeviceIdentifier = ""
    @objc public private(set) var isStreaming = false
    
    @objc public var name: String
    @objc public var size: CGSize
    
    @Published var hasReceivedControlMessage = false
    @Published var mostRecentVideoSelection: String?
    @Published var latestCompressedSampleBuffer: CMSampleBuffer?
    @Published var encoderBitRate: Int32 = 1920 * 1000
    
    var ciContext: CIContext
    var referencePixelBuffer: CVPixelBuffer?
    var scaledReferencePixelBuffer: CVPixelBuffer?
    
    var encoder: H265Encoder?
    
    private let queue: DispatchQueue
    
    @Published var connection: NWConnection? // not visible outside ShootKit but this will trigger an objectWillChange.send() so that hasConnection will work
    
    let bonjourBrowser = ShootKit.nwBrowser(for: .videoPencilApp)
    
    var hasSentParameterSet = false
    // Ecamm: Connection state is queue-confined. Generations reject obsolete approvals/retries.
    private var generation = 0
    private var authorizationPending = false
    private var receivePending = false
    private var notifiedConnected = false
    private var reconnectPending = false
    private var explicitlyStopped = false
    
    public var hasConnection: Bool{
        connection != nil
    }
    
    weak var delegate: VideoPencilClientDelegate?
    
    @objc public init(name: String, size: CGSize, delegate: VideoPencilClientDelegate, queue: DispatchQueue, ciContext: CIContext?=nil){
        self.name = name
        self.size = size
        self.delegate = delegate
        self.queue = queue
        self.ciContext = ciContext ?? CIContext()
        super.init()
        startBonjourDiscovery()
    }
    
    func startBonjourDiscovery(){
        bonjourBrowser.browseResultsChangedHandler = { [weak self] newResults, changes in // main thread
            // Ecamm: Network.framework invokes this on queue, not the main thread.
            guard let self, !self.explicitlyStopped else { return }
            self.log(message: "Bonjour results changed \(newResults.debugDescription)", color: NSColor.brown)

            if let connection = self.connection{
                let myEndpointDisappeared = !newResults.contains(where: {$0.endpoint == connection.endpoint})
                if myEndpointDisappeared{
                    // endpoint that was being used has disappeared
                    self.log(message: "Video Pencil endpoint disappeared, cancelling connection", color: .red)
                    self.stop()
                    self.scheduleReconnect()
                }
            }else{
                if let result = newResults.first {
                    self.connectIfAuthorized(to: result)
                }
            }
        }
        if let service = bonjourBrowser.browseResults.first{
            connectIfAuthorized(to: service)
        }
        bonjourBrowser.start(queue: queue)
    }
    

    func start(){
        guard !explicitlyStopped, connection == nil else { return }
        if let result = bonjourBrowser.browseResults.first{
            connectIfAuthorized(to: result)
        }
    }
    
    func tryReconnecting(){
        stop()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        // Ecamm: Coalesce failure/viability events, and never retry a revoked connection.
        guard !explicitlyStopped, !reconnectPending else { return }
        reconnectPending = true
        let requestedGeneration = generation
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == requestedGeneration else { return }
            self.reconnectPending = false
            self.start()
        }
    }

    private func connectIfAuthorized(to result: NWBrowser.Result) {
        guard !explicitlyStopped, connection == nil, !authorizationPending else { return }
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        remoteDeviceIdentifier = name
        remoteDeviceName = name.hasPrefix("Video Pencil on ") ? String(name.dropFirst(16)) : name
        authorizationPending = true
        let requestedGeneration = generation
        let displayName = remoteDeviceName
        let decision: (Bool) -> Void = { [weak self] allowed in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.generation == requestedGeneration, self.authorizationPending else { return }
                self.authorizationPending = false
                guard allowed, !self.explicitlyStopped, self.connection == nil,
                      self.bonjourBrowser.browseResults.contains(where: { $0.endpoint == result.endpoint }) else { return }
                self.connectTo_iPad(at: result)
            }
        }
        // Ecamm: UI decisions stay on main; the result returns to the connection queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.delegate?.videoPencil?(self, shouldConnectToDeviceNamed: displayName,
                                           identifier: name, decisionHandler: decision) == nil {
                decision(true)
            }
        }
    }

    private func connectTo_iPad(at networkBrowserResult: NWBrowser.Result){
        if connection != nil {
            log(message: "Removing existing Video Pencil connection", color: .systemOrange)
            connection?.cancel()
            decoder?.invalidate()
            encoder?.invalidate()
            decoder = nil
            encoder = nil
            connection = nil
        }
        log(message: "Attempt to connect to Video Pencil at \(networkBrowserResult) port \(networkBrowserResult.metadata)", color: .systemMint)
        let connection = NWConnection(to: networkBrowserResult.endpoint, using: ShootKit.applicationServiceParameters())

        // Ecamm: Old handlers must neither retain this client nor affect a replacement connection.
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            self.handleConnectionStateChanges(newState: state)
        }
        
        connection.viabilityUpdateHandler = { [weak self, weak connection] isViable in
            guard let self, let connection, connection === self.connection else { return }
            if !isViable{
                self.log(message: "Connection viability lost, attempt reconnection", color: .systemRed)
                self.tryReconnecting()
            }
        }
        // send the device name with the initial connection
        connection.send(content: name.data(using: .unicode), completion: .idempotent)
        
        self.connection = connection
        connection.start(queue: queue)
        // Ecamm: Publish once, before callbacks; begin the sole receive loop only on ready.
    }
    func handleConnectionStateChanges(newState: NWConnection.State){
        guard let connection = connection else { return }
        switch(newState){
        case .ready:
            log(message: "Video Pencil connection ready, awaiting message", color: .systemMint)
            notifiedConnected = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.videoPencilDidConnect(self)
            }
            awaitNextMessage()
        case .failed(let error):
            log(message: "Video Pencil connection failed: " + error.localizedDescription, color: .systemRed)
            tryReconnecting()
        case .preparing:
            log(message: "Preparing connection to Video Pencil... \(connection.parameters)", color: .systemMint)
        case .waiting(let error):
            log(message: "Waiting for Video Pencil connection: \(error.localizedDescription)", color: .orange)
        case .cancelled:
            // guaranteed to be final
            log(message: "Video Pencil connection cancelled \(connection.endpoint.debugDescription)", color: .systemRed)
            stop()
            scheduleReconnect()
        default: // preparing
            log(message: "Video Pencil Connection state changed to \(newState)", color: .orange)
            break
        }
    }

    func startVideoStream(){
        cancelVideoStream()
        hasSentParameterSet = false
        // Ecamm: Honor the host's requested feed size so its 960x540 snapshots are
        // actually encoded at 540p, not fed into the original hard-coded 1080p session.
        // Validate before converting CGSize; the independent drawing decoder stays 1080p.
        guard let width = Int32(exactly: size.width), let height = Int32(exactly: size.height),
              width > 0, height > 0 else {
            log(message: "Invalid Video Pencil encoder size: \(size)", color: .systemRed)
            return
        }
        encoder = H265Encoder(width: width, height: height, bitRate: encoderBitRate, fps: 30, callbackQueue: queue, delegate: self)
        guard encoder?.isReady == true else {
            encoder?.invalidate()
            encoder = nil
            return
        }
        isStreaming = true
        delegate?.videoPencil?(self, streamingChanged: true)
    }
    
    func cancelVideoStream(){
        // Ecamm: Stop producer work before asynchronously invalidating the codec.
        if isStreaming {
            isStreaming = false
            delegate?.videoPencil?(self, streamingChanged: false)
        }
        encoder?.invalidate()
        encoder = nil
        hasSentParameterSet = false
    }
    
    func send<T>(basicMessage: BasicControlMessage<T>){
        guard let data = try? JSONEncoder().encode(basicMessage) else { return }
        let message = NWProtocolFramer.Message(videoMessageType: .control)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [message])
        
        connection?.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                self?.log(message: "Error sending control message " + error.debugDescription, color: .red)
            }
        }))
            
        // Ecamm: Sending control data does not start another receive chain.
    }
    
    func awaitNextMessage(){
        // Ecamm: Exactly one receive is outstanding, and stale callbacks are ignored.
        guard !receivePending, let current = connection, current.state == .ready else { return }
        receivePending = true
        current.receiveMessage(completion: { [weak self, weak current] content, context, isComplete, error in
            guard let self, let current, current === self.connection else { return }
            self.receivePending = false
//            self.log(message: "Got message \(content)")
            if let message = context?.protocolMetadata(definition: VideoProtocol.definition) as? NWProtocolFramer.Message {
                // Ecamm: Stream-control packets can legitimately have no body.
                let frame = content ?? Data()
                switch message.videoMessageType{
                case .requestVideoStream:
                    self.cancelVideoStream()
                    self.log(message: "Video stream requested by Video Pencil", color: .systemOrange)
                    self.startVideoStream()
                    
                case .cancelVideoStream:
                    self.log(message: "Video stream cancelled by Video Pencil", color: .systemOrange)
                    self.cancelVideoStream()
                    
                case .hevcParameterSet:
                    if frame.count <= 64 * 1024, let parameterSet = try? JSONDecoder().decode(H265ParameterSet.self, from: frame){
                        self.log(message: "HEVC parameter set received from Video Pencil (\(parameterSet.parameters), decoder exists? \(self.decoder != nil))", color: .systemOrange)
                        // received pencil layer parameterSet
                        self.createDecoderIfNeeded()
                        
                        self.decoder?.setParameterSet(parameterSet.parameters)
                    }else{
                        self.log(message: "Error parsing HEVC parameter set from Video Pencil \(frame)", color: .systemRed)
                    }
                
                case .videoFrame:
                    // received pencil layer
                    self.decode(frame: frame)
                    
                case .invalid, .cameraAvailable, .handshake:
                    break
                default:
                    break // need to be careful about future messages breaking things!
                }
            }
            if let error = error {
                self.log(message: "Error receiving message \(error)", color: .red)
                self.tryReconnecting()
            }else{
                self.awaitNextMessage()
            }
        })
    }
    
    func send(controlMessage: VideoPencilControlMessage){
        let message = BasicControlMessage(command: controlMessage)
        send(basicMessage: message)
    }
    
    var decoder: H265Decoder?
    func createDecoderIfNeeded(){
        if decoder == nil {
            decoder = H265Decoder(width: 1920, height: 1080, callbackQueue: queue)
            decoder?.delegate = self
        }
    }
    func decode(frame: Data){
        createDecoderIfNeeded()
        decoder?.decode(frame)
    }
    @objc enum RenderError: Int, Error{
        case formatDescriptionUnavailable
        case sampleBufferNotCreated
    }
    @objc public func sendFrame(_ image: CIImage, presentationTimeStamp: CMTime, presentationDuration: CMTime) throws{
        guard let connection = connection,
              let encoder = encoder,
              connection.state == .ready
        else { return }
        
        var pixelBuffer: CVPixelBuffer?
        let minDimension = min(image.extent.height, image.extent.width)
        if minDimension > 1080{
            // scale it down
            let scale = 1080 / minDimension
            let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
            // Ecamm: The asynchronous encoder may still own the previous raster.
            // Never overwrite it. Ecamm's XPC caller normally supplies a direct buffer.
            scaledReferencePixelBuffer = CIImage.createPixelBuffer(width: Int(scaled.extent.width), height: Int(scaled.extent.height))
            if let scaledReferencePixelBuffer{
                ciContext.render(scaled, to: scaledReferencePixelBuffer)
            }
            pixelBuffer = scaledReferencePixelBuffer
            
        }else{
            if let b = image.pixelBuffer{
                pixelBuffer = b
            }else{
                // Ecamm: Rasterize lazy images into separate owned storage before return.
                referencePixelBuffer = CIImage.createPixelBuffer(width: Int(image.extent.width), height: Int(image.extent.height))
                if let referencePixelBuffer{
                    ciContext.render(image, to: referencePixelBuffer)
                    pixelBuffer = referencePixelBuffer
                }
            }
        }
        guard let pixelBuffer  else { return }
        encoder.encode(pixelBuffer: pixelBuffer, presentationTimeStamp: presentationTimeStamp, duration: presentationDuration)
        
    }
    
    public func stop(){
        // Ecamm: Clear callbacks before cancellation and notify even though connection
        // is about to become nil. The original cancelled callback could lose this event.
        generation += 1
        reconnectPending = false
        authorizationPending = false
        receivePending = false
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = nil
        cancelVideoStream()
        decoder?.invalidate()
        decoder = nil
        if notifiedConnected {
            notifiedConnected = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.videoPencilDidDisconnect(self)
            }
        }
    }

    @objc public func disconnect() {
        // Ecamm: Explicit revocation stays stopped until the host authorizes a restart.
        queue.async { [weak self] in self?.explicitlyStopped = true; self?.stop() }
    }

    @objc public func reconnect() {
        queue.async { [weak self] in self?.explicitlyStopped = false; self?.start() }
    }

    deinit {
        // Ecamm: Break callback ownership and stop codecs when the XPC host replaces us.
        bonjourBrowser.browseResultsChangedHandler = nil
        bonjourBrowser.cancel()
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        encoder?.invalidate()
        decoder?.invalidate()
    }
}

extension CIImage{
    static func createPixelBuffer(width: Int, height: Int)->CVPixelBuffer?{
        guard width > 0 && height > 0 else { return nil }
        
        var copiedBuffer: CVPixelBuffer?
        
        let pixelFormat = kCVPixelFormatType_32BGRA //CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        
        CVPixelBufferCreate(
            nil,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &copiedBuffer
        )
        
        return copiedBuffer
    }
}

extension VideoPencilClient: H265EncoderDelegate{
    func videoEncoderDidExtractParameterSet(_ encoder: H265Encoder, parameterSet frames: [Data]) {
        guard encoder === self.encoder, let connection = connection else { return }
        log(message: "Sending encoder parameters to Video Pencil: \(frames.map{$0})", color: .blue)
        
        let message = NWProtocolFramer.Message(videoMessageType: .hevcParameterSet)
        let context = NWConnection.ContentContext(identifier: "parameterSet", metadata: [message])
        let parameterSet = H265ParameterSet(parameters: frames)
        guard let data = try? JSONEncoder().encode(parameterSet) else { return }
        
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self, weak connection, weak encoder] error in
            guard let self, let connection, connection === self.connection, let encoder, encoder === self.encoder else { return }
            if let error = error {
                self.log(message: "Error sending frame " + error.debugDescription, color: .red)
                self.tryReconnecting()
            }
        }))
        // Ecamm: Network preserves queued-send order. Mark after enqueue, not after
        // completion, so the initial keyframe is never discarded while parameters send.
        hasSentParameterSet = true
    }
    func videoEncoderDidYieldVideoData(_ encoder: H265Encoder, compressedVideo data: Data) {
        guard encoder === self.encoder, let connection = connection, hasSentParameterSet else {
            log("VideoPencilClient Ignoring frame, no keyframe received yet", color: .orange)
            return
        }
        guard data.underestimatedCount > 0 else {
            log(message: "Skipped sending nil data", color: .yellow)
            return
        }
        let packetSize = connection.maximumDatagramSize - 40
        guard packetSize > 0 else { return }
        
        let message = NWProtocolFramer.Message(videoMessageType: .videoFrame)
        let context = NWConnection.ContentContext(identifier: "videoFrame", metadata: [message])
//        log(message: "Sending everything in one go", color: .systemGreen)
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                self?.log(message: "Error sending encoded video:" + error.debugDescription, color: .red)

            }
        }))
    }
    func videoEncoderDidEncodeSampleBuffer(_ encoder: H265Encoder, sampleBuffer: CMSampleBuffer) {
    }
    func videoEncoderDidFail(_ encoder: H265Encoder, error: OSStatus) {
        // Ecamm: Ignore retired codecs; report and stop a genuinely failed stream.
        guard encoder === self.encoder else { return }
        log(message: "Video Pencil encoder failed: \(OSErrorCodeDescription(error))", color: .red)
        cancelVideoStream()
    }
}

extension VideoPencilClient: ConnectionLogger{
    public func log(_ text: String, color: NSColor) {
        // Ecamm: A host hook replaces emoji-only output; fallback remains searchable.
        if let logHandler { logHandler(text) } else { print("VideoPencil:", text) }
    }
    public func log(message: String, color: NSColor) {
        log(message, color: color)
    }
}

extension VideoPencilClient: H265DecoderDelegate{
    
    func videoDecoderDidDecodePixelBuffer(_ decoder: H265Decoder, pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, presentationDuration: CMTime) {
        // Ecamm: A cancelled decoder cannot publish drawings into its replacement.
        guard decoder === self.decoder else { return }
        delegate?.videoPencilDidReceive(from: self, frame: CIImage(cvPixelBuffer: pixelBuffer), presentationTimeStamp: presentationTimeStamp, presentationDuration: presentationDuration)
    }
    
    func videoDecoder(_ decoder: H265Decoder, failedWith error: OSStatus) {
        // handle error
        // Ecamm: Reset the whole compressed prediction chain, not arbitrary individual frames.
        guard decoder === self.decoder else { return }
        log(message: "Video Pencil decoder failed: \(OSErrorCodeDescription(error))", color: .red)
        tryReconnecting()
    }
}
