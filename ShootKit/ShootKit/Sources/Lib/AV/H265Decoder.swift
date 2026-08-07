//
//  H265Decoder.swift
//  TPVideoCall
//
//  Created by Truc Pham on 25/05/2022.
//

import Foundation
import VideoToolbox
import OSLog

protocol H265DecoderDelegate:AnyObject, ConnectionLogger{
    func videoDecoder(_ decoder: H265Decoder, failedWith error: OSStatus)
    func videoDecoderDidDecodePixelBuffer(_ decoder: H265Decoder, pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, presentationDuration: CMTime)
}

class H265Decoder {
    // Ecamm: Preserve compressed HEVC ordering while keeping a firm memory bound.
    // Prediction frames cannot be replaced with a newer frame like raw video can.
    private static let maximumQueuedFrames = 12
    private static let maximumQueuedBytes = 32 * 1024 * 1024
    private static let maximumFramesInFlight = 4

    weak var delegate : H265DecoderDelegate?
    var expectsNalu: Bool = true
    var width: Int32
    var height:Int32
    
    var decodeQueue = DispatchQueue(label: "decode") // both serial queues
    var callBackQueue:DispatchQueue
    var decodeDesc : CMVideoFormatDescription?
    private let submissionLock = NSLock()
    
    private var parameterSet: [Data]?
    @Published var parameterSetView: [Data]?

    @Published var totalBytesDecoded: Int = 0
    
    var decompressionSession : VTDecompressionSession?
    var callback : VTDecompressionOutputCallback?
    private var queuedSubmissions = [Data]()
    private var queuedSubmissionBytes = 0
    private var submissionScheduled = false
    private var submissionOverflowed = false
    private var acceptingFrames = true
    private var framesInFlight = 0
    private var invalidated = false
    
    var pixelBufferPool: CVPixelBufferPool?
    private var outputBufferAuxAttributes: NSDictionary?

    
    
    public init( width: Int32, height: Int32, callbackQueue: DispatchQueue) {
        self.width = width
        self.height = height
        self.callBackQueue = callbackQueue
    }

    func setParameterSet(_ newParameterSet: [Data]) {
        // Ecamm: Parameter sets arrive on a connection queue while decoding runs
        // on decodeQueue. Serialize the handoff so the decoder never reads an
        // Array concurrently with its replacement.
        decodeQueue.async { [weak self] in
            guard let self = self, !self.invalidated else { return }
            self.parameterSet = newParameterSet
            DispatchQueue.main.async { [weak self] in
                self?.parameterSetView = newParameterSet
            }
            self.scheduleSubmissionDrain()
        }
    }
    
    func initDecoder() -> Bool {
        
        if decompressionSession != nil {
            return true
        }
        guard let parameterSet = parameterSet else {
            return false
        }
        //var frameData = Data(capacity: Int(size))
        //frameData.append(length, count: 4)
        //let point :UnsafePointer<UInt8> = [UInt8](data).withUnsafeBufferPointer({$0}).baseAddress!
        //frameData.append(point + UnsafePointer<UInt8>.Stride(4), count: Int(naluSize))
        //Processing sps/pps
        
        // Ecamm: Each HEVC parameter set starts with a four-byte Annex B start
        // code. Validate that assumption before slicing so malformed network data
        // cannot trap in suffix(from:).
        guard !parameterSet.isEmpty,
              parameterSet.count <= 8,
              parameterSet.allSatisfy({ $0.count > 4 }),
              parameterSet.reduce(0, { $0 + $1.count }) <= 64 * 1024
        else {
            delegate?.log(message: "Rejected invalid HEVC parameter set", color: .red)
            return false
        }

        // Ecamm: NSData owns stable storage for the duration of the Core Media
        // call. The old pointers escaped withUnsafeBufferPointer closures, whose
        // lifetime ended before CMVideoFormatDescription used them.
        let parameterValues = parameterSet.map { NSData(data: Data($0.dropFirst(4))) }
        let parameterSetPointers = parameterValues.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = parameterValues.map { $0.length }
        
        /**
         Set decoding parameters according to sps pps
         param kCFAllocatorDefault allocator
         param 2 Number of parameters
         param parameterSetPointers parameter set pointers
         param parameterSetSizes parameter set size
         length of param naluHeaderLen nalu nalu start code 4
         param _decodeDesc Decoder description
         return status
         */
        let descriptionState = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: parameterSetPointers.count, parameterSetPointers: parameterSetPointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &decodeDesc)
        if descriptionState != noErr {
            // error reference (I'm getting 12714) https://www.osstatus.com/search/results?platform=all&framework=all
            // -12714 = kCMFormatDescriptionBridgeError_InvalidSerializedSampleDescription
            delegate?.log(message: "Description creation failed with error \(ErrorCodeLookup[descriptionState] ?? "\(descriptionState)") for , sizes: \(sizes)", color: .red )
            return false
        }
        guard let decodeDesc = decodeDesc else { return false}
        //Decoding callback setting
        /*
         VTDecompressionOutputCallbackRecord is a simple structure with a pointer (decompressionOutputCallback) to the callback method after the frame is decompressed. You need to provide an instance (decompressionOutputRefCon) where this callback method can be found. The VTDecompressionOutputCallback callback method includes seven parameters:
         Parameter 1: Reference of the callback
         Parameter 2: Reference of the frame
         Parameter 3: A status identifier (contains undefined codes)
         Parameter 4: Indicate synchronous/asynchronous decoding, or whether the decoder intends to drop frames
         Parameter 5: Buffer of the actual image
         Parameter 6: Timestamp of occurrence
         Parameter 7: Duration of appearance
         */
        setCallBack()
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon:
                // unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        /*
         Decoding parameters:
         * kCVPixelBufferPixelFormatTypeKey: the output data format of the camera
         kCVPixelBufferPixelFormatTypeKey, the measured available value is
         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, which is 420v
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, which is 420f
         kCVPixelFormatType_32BGRA, iOS converts YUV to BGRA format internally
         YUV420 is generally used for standard-definition video, and YUV422 is used for high-definition video. The limitation here is surprising. However, under the same conditions, the calculation time and transmission pressure of YUV420 are smaller than those of YUV422.
         
         * kCVPixelBufferWidthKey/kCVPixelBufferHeightKey: the resolution of the video source width*height
         * kCVPixelBufferOpenGLCompatibilityKey: It allows the decoded image to be drawn directly in the context of OpenGL instead of copying data between the bus and the CPU. This is sometimes called a zero-copy channel, because the undecoded image is copied during the drawing process.
         
         */
        let imageBufferAttributes = [
//            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, // FORCE A CONVERSION COS I'M USING IT ELSEWHERE?
//            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8, // this comes through correctly in the pixel buffer
            kCVPixelBufferWidthKey:width,
            kCVPixelBufferHeightKey:height,
            kCVPixelBufferMetalCompatibilityKey: true,
            //            kCVPixelBufferOpenGLCompatibilityKey:true
        ] as [CFString : Any]
        
        if pixelBufferPool == nil {
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, imageBufferAttributes as NSDictionary, &pixelBufferPool)
            outputBufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5] // not used anywherez
        }
//
        //Create session
        
        /*!
         @function VTDecompressionSessionCreate
         @abstract creates a session for decompressing video frames.
         @discussion The decompressed frame will be sent out by calling OutputCallback
         @param allocator memory session. By using the default kCFAllocatorDefault allocator.
         @param videoFormatDescription describes the source video frame
         @param videoDecoderSpecification specifies the specific video decoder that must be used. NULL
         @param destinationImageBufferAttributes describes the requirements of the source pixel buffer NULL
         @param outputCallback Callback called using the decompressed frame
         @param decompressionSessionOut points to a variable to receive a new decompression session
         */
        let state = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: decodeDesc, decoderSpecification: nil, imageBufferAttributes: imageBufferAttributes as CFDictionary, outputCallback: &callbackRecord, decompressionSessionOut: &decompressionSession)
        
        if state != noErr {
            delegate?.log(message: "Failed to create decodeSession \(OSErrorCodeDescription(state))", color: .red)
            return false
        }
        guard let decompressionSession = decompressionSession else { return false }
        VTSessionSetProperty(decompressionSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(self.decompressionSession!, key: kVTDecompressionPropertyKey_PixelBufferPool, value: pixelBufferPool!)
        
        delegate?.log(message: "Created decompression session with parameter set \(parameterSet)", color: .systemOrange)
        
        return true
        
    }
        
    //Successfully decoded back
    private func setCallBack()  {

       //(UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, OSStatus, VTDecodeInfoFlags, CVImageBuffer?, CMTime, CMTime) -> Void
        callback = { decompressionOutputRefCon, sourceFrameRefCon, status, inforFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            guard let outputCallbackRefCon = decompressionOutputRefCon else { return }
            let decoder : H265Decoder =
                //unsafeBitCast(decompressionOutputRefCon, to: H265Decoder.self)
             Unmanaged<H265Decoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()

            // Ecamm: Release one of the bounded asynchronous decoder slots on
            // every callback path, then submit the next compressed frame in order.
            defer {
                decoder.decodeQueue.async {
                    decoder.framesInFlight = max(0, decoder.framesInFlight - 1)
                    decoder.submitQueuedFramesIfPossible()
                }
            }

            if let delegate = decoder.delegate  {

                if inforFlags.contains(.frameDropped){
                    delegate.log(message: "Dropped frame", color: .red)
                }
                guard let imageBuffer = imageBuffer else {
                    delegate.log(message: "Decoding error: Image buffer creation failed - \(ErrorCodeLookup[status] ?? "\(status)")", color: .red)
                    decoder.callBackQueue.async {
                        delegate.videoDecoder(decoder, failedWith: status)
                    }
                    return
                }
                decoder.callBackQueue.async {
                    delegate.videoDecoderDidDecodePixelBuffer(decoder, pixelBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, presentationDuration: presentationDuration)
                }
            }
        }
    }
    func decode(_ data: Data) {
        // Ecamm: Bound compressed-frame memory independently of the network
        // framer because H265Decoder is also used by ShootCamera.
        guard data.count <= VideoProtocol.maximumMessageLength else {
            delegate?.log(message: "Rejected oversized HEVC frame", color: .red)
            return
        }

        // Ecamm: Queue compressed frames in arrival order. Replacing an HEVC
        // prediction frame with a newer one corrupts the decoder reference chain.
        submissionLock.lock()
        guard acceptingFrames else {
            submissionLock.unlock()
            return
        }

        let wouldOverflow = queuedSubmissions.count >= Self.maximumQueuedFrames ||
            queuedSubmissionBytes > Self.maximumQueuedBytes - data.count
        if wouldOverflow {
            let shouldReportOverflow = !submissionOverflowed
            submissionOverflowed = true
            submissionLock.unlock()

            if shouldReportOverflow {
                callBackQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.log(message: "HEVC decoder input queue overflowed", color: .red)
                    self.delegate?.videoDecoder(self, failedWith: kVTVideoDecoderMalfunctionErr)
                }
            }
            return
        }

        queuedSubmissions.append(data)
        queuedSubmissionBytes += data.count
        let shouldScheduleSubmission = !submissionScheduled
        submissionScheduled = true
        submissionLock.unlock()

        if shouldScheduleSubmission {
            decodeQueue.async { [weak self] in
                self?.submitQueuedFramesIfPossible()
            }
        }
    }

    private func scheduleSubmissionDrain() {
        submissionLock.lock()
        let shouldSchedule = acceptingFrames &&
            !queuedSubmissions.isEmpty &&
            !submissionScheduled
        if shouldSchedule {
            submissionScheduled = true
        }
        submissionLock.unlock()

        if shouldSchedule {
            decodeQueue.async { [weak self] in
                self?.submitQueuedFramesIfPossible()
            }
        }
    }

    private func nextQueuedSubmission() -> Data? {
        submissionLock.lock()
        guard !queuedSubmissions.isEmpty else {
            submissionScheduled = false
            submissionLock.unlock()
            return nil
        }
        let data = queuedSubmissions.removeFirst()
        queuedSubmissionBytes -= data.count
        submissionLock.unlock()
        return data
    }

    private func submitQueuedFramesIfPossible() {
        guard !invalidated else { return }
        guard parameterSet != nil, initDecoder() else {
            // A parameter set normally arrives before the first frame. Allow its
            // setter to restart this preserved queue when it becomes available.
            submissionLock.lock()
            submissionScheduled = false
            submissionLock.unlock()
            return
        }

        while framesInFlight < Self.maximumFramesInFlight,
              let data = nextQueuedSubmission() {
            framesInFlight += 1
            let decodeState = decode(frame: data)
            if decodeState != noErr {
                // A synchronous rejection does not produce a callback, so release
                // its slot here and let the client restart the damaged stream.
                framesInFlight -= 1
                callBackQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.videoDecoder(self, failedWith: decodeState)
                }
                return
            }
        }
    }
    
    private func decode(frame:Data) -> OSStatus {
        //
        var blockBuffer: CMBlockBuffer?
        let size = frame.count
        //        var memoryBlock = frame1.withUnsafeMutableBytes({$0}).baseAddress
        //        var ddd = Data(bytes: frame, count: Int(size))
        //Create blockBuffer
        /*!
         Parameter 1: structureAllocator kCFAllocatorDefault
         Parameter 2: memoryBlock frame
         Parameter 3: frame size
         Parameter 4: blockAllocator: Pass NULL
         Parameter 5: customBlockSource Pass NULL
         Parameter 6: offsetToData data offset
         Parameter 7: dataLength data length
         Parameter 8: flags function and control flags
         Parameter 9: newBBufOut blockBuffer address, cannot be empty
         */
        // Ecamm: Ask Core Media to allocate and own the block, then copy Data into
        // it. The previous kCFAllocatorNull block referenced temporary Swift array
        // storage that could disappear while asynchronous decoding still used it.
        let blockState = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                            memoryBlock: nil,
                                                            blockLength: size,
                                                            blockAllocator: kCFAllocatorDefault,
                                                            customBlockSource: nil,
                                                            offsetToData:0,
                                                            dataLength: size,
                                                            flags: 0,
                                                            blockBufferOut: &blockBuffer)
        if blockState != noErr {
            self.delegate?.log(message: "Failed to create blockBuffer \(OSErrorCodeDescription(blockState))", color: .red)
            return blockState
        }
        guard let blockBuffer = blockBuffer else {
            return kCMBlockBufferBadCustomBlockSourceErr
        }
        let copyState = frame.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: size)
        }
        if copyState != noErr {
            self.delegate?.log(message: "Failed to copy HEVC data into blockBuffer \(OSErrorCodeDescription(copyState))", color: .red)
            return copyState
        }
        //
        var sampleSizeArray :[Int] = [Int(size)]
        var sampleBuffer :CMSampleBuffer?
        //Create sampleBuffer
        /*
         Parameter 1: allocator allocator, use the default memory allocation, kCFAllocatorDefault
         Parameter 2: blockBuffer. The data blockBuffer that needs to be encoded. Cannot be NULL
         Parameter 3: formatDescription, video output format
         Parameter 4: numSamples.CMSampleBuffer number.
         Parameter 5: numSampleTimingEntries must be 0,1,numSamples
         Parameter 6: sampleTimingArray. Array. Empty
         Parameter 7: numSampleSizeEntries defaults to 1
         Parameter 8: sampleSizeArray
         Parameter 9: sampleBuffer object
         */
        let readyState = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                   dataBuffer: blockBuffer,
                                                   formatDescription: decodeDesc,
                                                   sampleCount: CMItemCount(1),
                                                   sampleTimingEntryCount: CMItemCount(),
                                                   sampleTimingArray: nil,
                                                   sampleSizeEntryCount: CMItemCount(1),
                                                   sampleSizeArray: &sampleSizeArray,
                                                   sampleBufferOut: &sampleBuffer)
        if readyState != noErr {
            self.delegate?.log(message: "Sample Buffer Create Ready failed \(OSErrorCodeDescription(readyState))", color: .red)
            return readyState
        }
        
        guard let decompressionSession = self.decompressionSession, let sampleBuffer = sampleBuffer else { return kVTInvalidSessionErr }

        // Ecamm: Set display-immediately before submitting the sample; changing
        // attachments after an asynchronous decode has begun is a data race.
        let attachments:CFArray? = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
        if let attachmentArray = attachments, CFArrayGetCount(attachmentArray) > 0 {
            let dic = unsafeBitCast(CFArrayGetValueAtIndex(attachmentArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dic,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        //Decode data
        /*
         Parameter 1: Decoding session
         Parameter 2: Source data CMsampleBuffer containing one or more video frames
         Parameter 3: Decoding flag
         Parameter 4: decoded data outputPixelBuffer
         Parameter 5: Synchronous/asynchronous decoding identification
         */
        let sourceFrame:UnsafeMutableRawPointer? = nil
        var inforFalg = VTDecodeInfoFlags.asynchronous
        let decodeState = VTDecompressionSessionDecodeFrame(
            decompressionSession,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags._EnableAsynchronousDecompression,
            frameRefcon: sourceFrame,
            infoFlagsOut: &inforFalg
        )
        if decodeState != noErr {
            delegate?.log(message: "Decoding failed for \(decompressionSession) \(OSErrorCodeDescription(decodeState))", color: .red)
        }
//        let numberOfFramesBeingDecoded = kVTDecompressionPropertyKey_NumberOfFramesBeingDecoded
        DispatchQueue.main.async {
            self.totalBytesDecoded += size
//            self.numberOfFramesBeingDecoded = numberOfFramesBeingDecoded
        }

        return decodeState
    }

    func invalidate() {
        // Ecamm: Teardown is asynchronous so connection loss cannot wait on the
        // decoder queue or VideoToolbox from a UI or render-sensitive caller.
        submissionLock.lock()
        acceptingFrames = false
        queuedSubmissions.removeAll()
        queuedSubmissionBytes = 0
        submissionLock.unlock()

        decodeQueue.async { [self] in
            guard !invalidated else { return }
            invalidated = true
            framesInFlight = 0
            if let decompressionSession = decompressionSession {
                VTDecompressionSessionInvalidate(decompressionSession)
                self.decompressionSession = nil
            }
        }
    }
    
    deinit {
        if let decompressionSession = self.decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
            self.decompressionSession = nil
        }
        
    }
}
