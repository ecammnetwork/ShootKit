//
//  H265Encoder.swift
//  TPVideoCall
//
//  Created by Truc Pham on 25/05/2022.
//

import Foundation
import VideoToolbox

protocol H265EncoderDelegate:AnyObject, ConnectionLogger {
    func videoEncoderDidYieldVideoData(_ encoder : H265Encoder, compressedVideo : Data, presentationTimeStamp: CMTime)
    func videoEncoderDidExtractParameterSet(_ encoder : H265Encoder, parameterSet: [Data])
    func videoEncoderDidEncodeSampleBuffer(_ encoder: H265Encoder, sampleBuffer: CMSampleBuffer)
    func videoEncoderDidFail(_ encoder: H265Encoder, error: OSStatus)
}

class H265Encoder {
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
    private let workMonitor: VideoWorkMonitor
    
    var encodeSession:VTCompressionSession?
    var encodeCallBack:VTCompressionOutputCallback?
    var codecType: CMVideoCodecType
    // Ecamm: Balance the C callback retain after invalidation, not in an unreachable deinit.
    private var callbackRetain: Unmanaged<H265Encoder>?
    private var invalidated = false
    private var extractedParameterSet = false
    var isReady: Bool { encodeSession != nil }
    
    init(codecType: CMVideoCodecType = kCMVideoCodecType_HEVC, width:Int32, height:Int32, bitRate : Int32?, fps: Int32?, callbackQueue: DispatchQueue, delegate: H265EncoderDelegate? = nil, workMonitor: VideoWorkMonitor = VideoWorkMonitor()) {
        self.workMonitor = workMonitor
        self.codecType = codecType
        self.width = width
        self.height = height
        self.bitRate = bitRate != nil ? bitRate! : height * 3 * 4
        self.fps = (fps != nil) ? fps! : 30
        self.callBackQueue = callbackQueue
        // Ecamm: Install logging before synchronous session creation can fail.
        self.delegate = delegate
        delegate?.log(message:"Encoder configuration size: \(self.width)x\(self.height) bitRate: \(self.bitRate) fps: \(self.fps)", color: .systemGreen)
        setCallBack()
        initVideoToolBox()
    }
    
    private func initVideoToolBox() {
        // Ecamm: A decoding capability check says nothing about encoding. Require
        // hardware at creation so the companion stream cannot silently use software.
        // Ecamm: Low-latency rate control is a creation option, not a session property.
        // Restore standard rate control for comparison after quality pulsing was reported in low-latency mode.
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let owner = Unmanaged.passRetained(self)
        callbackRetain = owner
        //create VTCompressionSession
        // Ecamm: Keep the callback owner alive through this single hardware creation attempt.
        let state = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height, codecType: codecType,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodeCallBack,
            refcon:
//                unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
                UnsafeMutableRawPointer(owner.toOpaque()),
            compressionSessionOut: &self.encodeSession)
        
        if state != noErr || encodeSession == nil {
            // Ecamm: Tear down a partial result before releasing its owner; there is no software retry.
            // Ecamm: Even an unsuccessful creation must not leave a session with a released refcon.
            if let session = encodeSession { VTCompressionSessionInvalidate(session) }
            encodeSession = nil
            owner.release()
            callbackRetain = nil
            delegate?.log(message: "create VTCompressionSession failed: \(OSErrorCodeDescription(state))", color: .systemRed)
            return
        }
        
        guard let encodeSession = encodeSession else { return }
        delegate?.log(message: "HEVC encoder: standard hardware rate control (low-latency disabled)", color: .systemGreen)
        
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
        let averageStatus = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrateAverage)
        // Ecamm: Log rejected settings instead of silently assuming the requested rate was applied.
        if averageStatus != noErr {
            delegate?.log(message: "Could not set average bitrate: \(OSErrorCodeDescription(averageStatus))", color: .systemRed)
        }
        
        //Bit rate limit
        // Ecamm: DataRateLimits uses [bytes, seconds], unlike AverageBitRate's bits/second.
        // Allow three times the average over one second for motion, converting to bytes with a wide intermediate.
        // At 900,000 bps this is 337,500 bytes/second (2,700,000 bps), not 2,700,000 bytes/second.
        let bitRatesLimit :CFArray = [Int64(bitRate) * 3 / 8, 1] as CFArray
        let limitStatus = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_DataRateLimits, value: bitRatesLimit)
        if limitStatus != noErr {
            delegate?.log(message: "Could not set bitrate limit: \(OSErrorCodeDescription(limitStatus))", color: .systemRed)
        }

        // Ecamm: Deliberately preserve Michael's keyframe and other codec defaults.
        // There is no new MaxFrameDelayCount, pacing algorithm, or submission window.
        
        VTSessionSetProperty(encodeSession, key: kVTVideoEncoderList_IsHardwareAccelerated, value: kCFBooleanTrue)
//        
        // Ecamm: The former 11.3-guarded low-latency setter was a creation option, not a valid setter.
        // Leave it unset at creation too, restoring the standard rate control used before the experiment.
        
//        VTSessionSetProperty(encodeSession, key: kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)
        
    }
    
    private func setCallBack()  {
        //Coding complete callback
        encodeCallBack = {(outputCallbackRefCon, sourceFrameRefCon, status, flag, sampleBuffer)  in
            guard let outputCallbackRefCon = outputCallbackRefCon else {return}
            let encoder : H265Encoder =
                 Unmanaged<H265Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
            let callBackQueue = encoder.callBackQueue
            // Ecamm: Count the frame until delivery, not just until VideoToolbox accepts it.
            let monitor = encoder.workMonitor
            let token = UInt(bitPattern: sourceFrameRefCon)
            var handedOff = false
            defer { if !handedOff { monitor.finish(token) } }

            // Ecamm: Report actual failures, but a successful frame drop needs no restart.
            guard status == noErr else {
                callBackQueue.async { [weak encoder] in
                    guard let encoder else { return }
                    encoder.delegate?.videoEncoderDidFail(encoder, error: status)
                }
                return
            }
            guard !flag.contains(.frameDropped) else { return }
            
            guard let sampleBuffer = sampleBuffer else {
                return
            }
            
           
            /// 0. Raw byte data 8 bytes
            let buffer : [UInt8] = [0x00,0x00,0x00,0x01]
            /// 1. [UInt8] -> UnsafeBufferPointer<UInt8>

            
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let keyFrame = !notSync // absent or false means this is a sync (key) frame
            
            //  Obtain sps pps
            if keyFrame && !encoder.extractedParameterSet {
                let parameterSet = getParameterSet(sampleBuffer)
                if parameterSet.count > 0 {
                    // Ecamm: Do not wait for the main-thread UI property before marking
                    // parameters delivered. Their callback precedes this frame's data.
                    encoder.extractedParameterSet = true
                    DispatchQueue.main.async { [weak encoder] in
                        encoder?.parameterSet = parameterSet
                        encoder?.delegate?.log(message: "Encoding parameters extracted from sampleBuffer: \(parameterSet)", color: .green)
                    }
                    callBackQueue.async { [weak encoder] in
                        guard let encoder else { return }
                        encoder.delegate?.videoEncoderDidExtractParameterSet(encoder, parameterSet: parameterSet)
                    }
                }
            }
            // --------- data input ----------
            
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            //                let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            //                let timeAgo = CMTimeSubtract(timeStamp, CMClockGetTime(CMClockGetHostTimeClock()))
            //                encoder.delegate?.log(message: "Encoded buffer with timestamp \(timeStamp.seconds) \(timeAgo.seconds)")
            //var arr = [Int8]()
            //let pointer = arr.withUnsafeMutableBufferPointer({$0})
            var dataPointer: UnsafeMutablePointer<Int8>?  = nil
            var totalLength :Int = 0
            let blockState = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            if blockState != noErr || dataPointer == nil {
                encoder.delegate?.log(message: "Failed to get data\(blockState)", color: .red)
                return
            }
            // now dataPointer has our blockBuffer
            
            var data = Data(capacity: totalLength)
            let p = unsafeBitCast(dataPointer, to: UnsafePointer<UInt8>.self)
            data.append(p, count: totalLength)
            let byteCount = data.count
            
            let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            handedOff = true
            callBackQueue.async { [weak encoder] in
                defer { monitor.finish(token) }
                if let encoder = encoder{
                    encoder.delegate?.videoEncoderDidYieldVideoData(encoder, compressedVideo: data, presentationTimeStamp: presentationTimeStamp)
                    encoder.addToTotal(bytes: byteCount)
                }
            }
        }
    }
    

    
    //Start coding
    func encode(pixelBuffer:CVPixelBuffer, presentationTimeStamp:CMTime, duration:CMTime){
        // Ecamm: A failed/cancelled session is not recreated from the frame path.
        // Only unsubmitted raw frames may be skipped; never drop an encoded prediction frame.
        let monitor = workMonitor
        guard let token = monitor.begin(.encode, owner: self) else { return }
        encodeQueue.async {[weak self] in
            guard let self = self, !self.invalidated, let encodeSession = self.encodeSession else {
                monitor.finish(token)
                return
            }
            var flags: VTEncodeInfoFlags = VTEncodeInfoFlags()
            let state = VTCompressionSessionEncodeFrame(encodeSession, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTimeStamp, duration: duration, frameProperties: nil, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: token), infoFlagsOut: &flags)
            if state != noErr || flags.contains(.frameDropped) { monitor.finish(token) }
            if state != noErr{
                callBackQueue.async{
                    self.delegate?.log(message: "encode failure \(OSErrorCodeDescription(state))", color: .red)
                    self.delegate?.videoEncoderDidFail(self, error: state)
                }
            }
        }
        
    }

    func invalidate() {
        // Ecamm: Serialize teardown behind submissions. No UI/render caller waits
        // for VideoToolbox, and the C refcon stays valid through the last callback.
        let token = workMonitor.begin(.teardown)
        encodeQueue.async { [self] in
            defer { if let token { workMonitor.finish(token) } }
            guard !invalidated else { return }
            invalidated = true
            if let session = encodeSession {
                VTCompressionSessionInvalidate(session)
                encodeSession = nil
            }
            workMonitor.finishInvalidatedCodec(self)
            callbackRetain?.release()
            callbackRetain = nil
        }
    }
    
    deinit {
        if let encodeSession = encodeSession {
            // Ecamm: Cancellation discards output; never flush/wait for all frames here.
            VTCompressionSessionInvalidate(encodeSession);
//            self.encodeSession = nil;
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
