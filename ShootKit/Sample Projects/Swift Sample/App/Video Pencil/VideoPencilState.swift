//
//  VideoPencilState.swift
//  ShootKit
//
//  Created by Michael Forrest on 02/06/2023.
//

import Foundation
import AVKit
import ShootKit
import CoreImage

class VideoPencilState: NSObject, ObservableObject{
    @Published var isConnected = false
    
    var videoPencilClient: VideoPencilClient?
    var cameraSource: CameraSource?
    var latestCameraFrame: CIImage?
    var latestDrawingFrame: CIImage?
    var cameraBuffers = BufferSource()
    let queue = DispatchQueue(label: "VideoPencilState", qos: .userInitiated)
    
    override init(){
        super.init()
        cameraSource = CameraSource(captureDelegate: self, queue: queue)
        videoPencilClient = VideoPencilClient(name: "Swift Sample", size: CGSize(width: 1920, height: 1080), delegate: self, queue: queue, ciContext: nil)
    }
    
}

// Handle local camera output
extension VideoPencilState: AVCaptureVideoDataOutputSampleBufferDelegate{
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Keep a buffer to display in the demo
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
//        latestCameraFrame = frame
        
        // Send to Video Pencil
        try? videoPencilClient?.sendFrame(frame, presentationTimeStamp: CMClockGetHostTimeClock().time, presentationDuration: CMTime(value: 1, timescale: 30))
    }
    
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { }
    
}

// Receive transparent frames from Video Pencil
extension VideoPencilState: VideoPencilClientDelegate{
    func videoPencilDidReceive(from: VideoPencilClient, frame: CIImage, presentationTimeStamp: CMTime, presentationDuration: CMTime) {
        self.latestDrawingFrame = frame
    }
    func videoPencilDidConnect(_ client: VideoPencilClient) {
        DispatchQueue.main.async {
            self.isConnected = true
        }
    }
    func videoPencilDidDisconnect(_ client: VideoPencilClient) {
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }
}

// helper class to drive the SampleBufferPlayer
final class BufferSource: SampleBufferSource{
    var latestSampleBuffer: CMSampleBuffer?
}
