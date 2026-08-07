//
//  H265Encoder.swift
//  TPVideoCall
//
//  Created by Truc Pham on 25/05/2022.
//

import Foundation
import VideoToolbox

protocol H265EncoderDelegate:AnyObject, ConnectionLogger {
    func videoEncoderDidYieldVideoData(_ encoder : H265Encoder, compressedVideo : Data)
    func videoEncoderDidExtractParameterSet(_ encoder : H265Encoder, parameterSet: [Data])
    func videoEncoderDidEncodeSampleBuffer(_ encoder: H265Encoder, sampleBuffer: CMSampleBuffer)
    func videoEncoderDidFail(_ encoder: H265Encoder, error: OSStatus)
}

class H265Encoder {
    // Ecamm: VideoToolbox is asynchronous and needs a small pipeline to sustain
    // real-time frame rates without allowing an unbounded number of submissions.
    private static let maximumFramesInFlight = 4

    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let duration: CMTime
    }

    weak var delegate : H265EncoderDelegate?
    private var frameID:Int64 = 0
    var parameterSet: [Data]?
    var width: Int32 = 1920
    var height:Int32 = 1080
    var bitRate : Int32 = 0 // specified below
    var fps : Int32 = 0 // specified below
    
    @Published var totalBytesEncoded: Int = 0
    
    func addToTotal(bytes: Int){
        DispatchQueue.main.async { [weak self] in
            self?.totalBytesEncoded += bytes
        }
    }
    
    private var encodeQueue = DispatchQueue(label: "encode")
    private var callBackQueue: DispatchQueue
    private let submissionLock = NSLock()
    
    var encodeSession:VTCompressionSession?
    var encodeCallBack:VTCompressionOutputCallback?
    var codecType: CMVideoCodecType
    private var callbackRetain: Unmanaged<H265Encoder>?
    private var pendingFrame: PendingFrame?
    private var pendingSubmission: PendingFrame?
    private var submissionScheduled = false
    private var acceptingFrames = true
    private var framesInFlight = 0
    private var invalidated = false
    private var extractedParameterSet = false

    // Ecamm: Callers use this after construction to avoid accepting frames when
    // VideoToolbox could not allocate the required hardware encoder.
    var isReady: Bool { encodeSession != nil }
    
    init(codecType: CMVideoCodecType = kCMVideoCodecType_HEVC, width:Int32, height:Int32, bitRate : Int32?, fps: Int32?, callbackQueue: DispatchQueue) {
        self.codecType = codecType
        self.width = width
        self.height = height
        self.bitRate = bitRate != nil ? bitRate! : height * 3 * 4
        self.fps = (fps != nil) ? fps! : 30
        self.callBackQueue = callbackQueue
        delegate?.log(message:"Encoder configuration size: \(self.width)x\(self.height) bitRate: \(self.bitRate) fps: \(self.fps)", color: .systemGreen)
        setCallBack()
        initVideoToolBox()
    }
    
    @discardableResult
    private func initVideoToolBox() -> Bool {
        // Ecamm: Video Pencil must never silently fall back to a software encoder
        // and consume the CPU needed by the host application's primary encoders.
        // VideoToolbox has no encode equivalent of VTIsHardwareDecodeSupported;
        // requiring hardware here makes session creation itself the availability check.
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ] as CFDictionary

        // Ecamm: VideoToolbox treats refcon as an unmanaged pointer. Retain the
        // encoder explicitly and balance it in invalidate(), after the session has
        // stopped issuing callbacks. This avoids both use-after-free and the old
        // permanent passRetained leak.
        let callbackRetain = Unmanaged.passRetained(self)
        self.callbackRetain = callbackRetain
        //create VTCompressionSession
        let state = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height, codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodeCallBack ,
            refcon: UnsafeMutableRawPointer(callbackRetain.toOpaque()),
            compressionSessionOut: &self.encodeSession)
        
        if state != noErr {
            callbackRetain.release()
            self.callbackRetain = nil
            delegate?.log(message: "create VTCompressionSession failed", color: .systemRed)
            return false
        }
        
        guard let encodeSession = encodeSession else {
            callbackRetain.release()
            self.callbackRetain = nil
            return false
        }
        
        //Set real-time encoding output
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        //Set encoding method
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        //Set whether to generate B frames (because B frames are not necessary when decoding, B frames can be discarded)
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        //Set key frame interval
        var frameInterval = 30
        let number = CFNumberCreate(kCFAllocatorDefault, CFNumberType.intType, &frameInterval)
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: number)
        
        //Set the desired frame rate, not the actual frame rate
        let fpscf = CFNumberCreate(kCFAllocatorDefault, CFNumberType.intType, &fps)
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fpscf)
        
        //Set the average bit rate, the unit is bps. If the bit rate is higher, it will be very clear, but at the same time the file will be larger. If the bit rate is small, the image will sometimes be blurred, but it can barely be seen
        //Code rate calculation formula reference notes
        //        var bitrate = width * height * 3 * 4
        let bitrateAverage = CFNumberCreate(kCFAllocatorDefault, CFNumberType.intType, &bitRate)
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateAverage)
        
        //Bit rate limit
        let bitRatesLimit :CFArray = [bitRate * 2,1] as CFArray
        VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_DataRateLimits, value: bitRatesLimit)
        
        if #available(macOS 11.3, *) {
            VTSessionSetProperty(encodeSession, key: kVTVideoEncoderSpecification_EnableLowLatencyRateControl, value: kCFBooleanTrue)
        }
        
//        VTSessionSetProperty(encodeSession, key: kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)
        let prepareState = VTCompressionSessionPrepareToEncodeFrames(encodeSession)
        if prepareState != noErr {
            delegate?.log(message: "prepare VTCompressionSession failed: \(OSErrorCodeDescription(prepareState))", color: .systemRed)
            // Ecamm: Construction is still synchronous here, so tear down now.
            // Scheduling invalidate() would briefly report isReady == true.
            VTCompressionSessionInvalidate(encodeSession)
            self.encodeSession = nil
            callbackRetain.release()
            self.callbackRetain = nil
            return false
        }

        return true
    }
    
    private func setCallBack()  {
        //Coding complete callback
        encodeCallBack = {(outputCallbackRefCon, sourceFrameRefCon, status, flag, sampleBuffer)  in
            guard let outputCallbackRefCon = outputCallbackRefCon else {return}
            let encoder : H265Encoder =
                 Unmanaged<H265Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
            encoder.handleCompressionOutput(status: status, sampleBuffer: sampleBuffer)
        }
    }

    private func handleCompressionOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        // Ecamm: Every submitted frame must release its bounded pipeline slot, even
        // when VideoToolbox returns an error or no sample buffer.
        defer {
            encodeQueue.async { [weak self] in
                guard let self = self else { return }
                self.framesInFlight = max(0, self.framesInFlight - 1)
                self.submitPendingFrameIfPossible()
            }
        }

        guard status == noErr, let sampleBuffer = sampleBuffer else {
            callBackQueue.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.log(message: "HEVC encoder callback failed: \(OSErrorCodeDescription(status))", color: .red)
                self.delegate?.videoEncoderDidFail(self, error: status)
            }
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyFrame = !notSync // absent or false means this is a sync (key) frame

        // Obtain VPS/SPS/PPS once, before delivering the matching compressed data.
        if keyFrame && !extractedParameterSet {
            let parameterSet = getParameterSet(sampleBuffer)
            if !parameterSet.isEmpty {
                extractedParameterSet = true
                DispatchQueue.main.async { [weak self] in
                    self?.parameterSet = parameterSet
                }
                callBackQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.log(message: "Encoding parameters extracted from sampleBuffer: \(parameterSet)", color: .green)
                    self.delegate?.videoEncoderDidExtractParameterSet(self, parameterSet: parameterSet)
                }
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var dataPointer: UnsafeMutablePointer<Int8>?
        var totalLength = 0
        let blockState = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard blockState == noErr, let dataPointer = dataPointer, totalLength > 0 else {
            delegate?.log(message: "Failed to get encoded data \(blockState)", color: .red)
            return
        }

        let data = Data(bytes: dataPointer, count: totalLength)
        callBackQueue.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoEncoderDidYieldVideoData(self, compressedVideo: data)
            self.addToTotal(bytes: data.count)
        }
    }
    

    
    //Start coding
    func encode(pixelBuffer:CVPixelBuffer, presentationTimeStamp:CMTime, duration:CMTime){
        let frame = PendingFrame(pixelBuffer: pixelBuffer,
                                 presentationTimeStamp: presentationTimeStamp,
                                 duration: duration)

        // Ecamm: Bound work before it reaches encodeQueue as well. If a
        // VideoToolbox call stalls that queue, callers still retain only the
        // newest pixel buffer instead of accumulating dispatch blocks.
        submissionLock.lock()
        guard acceptingFrames else {
            submissionLock.unlock()
            return
        }
        pendingSubmission = frame
        let shouldScheduleSubmission = !submissionScheduled
        submissionScheduled = true
        submissionLock.unlock()

        if shouldScheduleSubmission {
            encodeQueue.async { [weak self] in
                self?.acceptLatestSubmission()
            }
        }
    }

    private func acceptLatestSubmission() {
        submissionLock.lock()
        let frame = pendingSubmission
        pendingSubmission = nil
        submissionScheduled = false
        let shouldAcceptFrame = acceptingFrames
        submissionLock.unlock()

        guard shouldAcceptFrame, !invalidated, let frame = frame else { return }
        pendingFrame = frame
        submitPendingFrameIfPossible()
    }

    private func submitPendingFrameIfPossible() {
        guard !invalidated,
              framesInFlight < Self.maximumFramesInFlight,
              let encodeSession = encodeSession,
              let frame = pendingFrame
        else { return }

        // Ecamm: VideoToolbox requires buffers to match the session dimensions.
        // Reject mismatches instead of repeatedly asking the framework to fail.
        guard CVPixelBufferGetWidth(frame.pixelBuffer) == Int(width),
              CVPixelBufferGetHeight(frame.pixelBuffer) == Int(height)
        else {
            pendingFrame = nil
            callBackQueue.async { [weak self] in
                self?.delegate?.log(message: "Dropped HEVC frame with dimensions that do not match \(self?.width ?? 0)x\(self?.height ?? 0)", color: .red)
            }
            return
        }

        pendingFrame = nil
        framesInFlight += 1
        var flags = VTEncodeInfoFlags()
        let state = VTCompressionSessionEncodeFrame(encodeSession,
                                                    imageBuffer: frame.pixelBuffer,
                                                    presentationTimeStamp: frame.presentationTimeStamp,
                                                    duration: frame.duration,
                                                    frameProperties: nil,
                                                    sourceFrameRefcon: nil,
                                                    infoFlagsOut: &flags)
        if state != noErr {
            framesInFlight -= 1
            callBackQueue.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.log(message: "encode failure \(OSErrorCodeDescription(state))", color: .red)
                self.delegate?.videoEncoderDidFail(self, error: state)
            }
            submitPendingFrameIfPossible()
        } else if flags.contains(.frameDropped) {
            // Ecamm: A synchronously dropped frame has no output callback, so it
            // must release its slot here or the encoder pipeline eventually stalls.
            framesInFlight -= 1
            submitPendingFrameIfPossible()
        }
    }

    func invalidate() {
        // Ecamm: Teardown is serialized behind any submit already in progress and
        // never waits synchronously on VideoToolbox or the application's render queue.
        submissionLock.lock()
        acceptingFrames = false
        pendingSubmission = nil
        submissionLock.unlock()

        encodeQueue.async { [self] in
            guard !invalidated else { return }
            invalidated = true
            pendingFrame = nil
            framesInFlight = 0
            if let encodeSession = encodeSession {
                VTCompressionSessionInvalidate(encodeSession)
                self.encodeSession = nil
            }
            callbackRetain?.release()
            callbackRetain = nil
        }
    }

    deinit {
        // Ecamm: invalidate() normally clears the session while the explicit
        // callback retain still keeps this object alive. This is a final safety net
        // for construction failures where no session was published.
        if let encodeSession = encodeSession {
            VTCompressionSessionInvalidate(encodeSession)
        }
    }
}

private func getParameterSet(_ sampleBuffer: CMSampleBuffer) -> [Data] {
    var result = [Data]()
    let codecStartCode =  [UInt8](arrayLiteral: 0x00, 0x00, 0x00, 0x01)
//    parameterSet.append(contentsOf: codecStartCode)
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return []}
    
    var numParams = 0
    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &numParams, nalUnitHeaderLengthOut: nil)
    // in H264 Stream, index 0 == sps, 1 == pps
    // in HEVC Stream, index 0 == vps, 1 == sps, 2 == pps
    for index in 0 ..< numParams {
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetLength = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        
        if let parameterSetPointer = parameterSetPointer{
            var data = Data()
            
            data.append(contentsOf: codecStartCode)
            data.append(parameterSetPointer, count: parameterSetLength)
            
            result.append(data)
        }
    }
    
    return result
}
