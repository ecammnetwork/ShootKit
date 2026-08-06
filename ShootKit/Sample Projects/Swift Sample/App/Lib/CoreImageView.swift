//
//  CoreImageView.swift
//  ShootKit
//
//  Created by Michael Forrest on 06/08/2026.
//


import SwiftUI
import AVKit
import MetalKit
import CoreImage

struct CoreImageView: NSViewRepresentable {
    var state: VideoPencilState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.state = state
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var state: VideoPencilState
        let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let ciContext: CIContext
        private let colorSpace = CGColorSpaceCreateDeviceRGB()

        init(state: VideoPencilState) {
            self.state = state
            let device = MTLCreateSystemDefaultDevice()!
            self.device = device
            self.commandQueue = device.makeCommandQueue()!
            self.ciContext = CIContext(mtlCommandQueue: commandQueue, options: nil)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable else { return }

            let camera = state.latestCameraFrame
            let drawing = state.latestDrawingFrame

            var composited: CIImage?
            if let camera, let drawing {
                composited = drawing
                    .premultiplyingAlpha()
                    .composited(over: camera)
            } else {
                composited = drawing ?? camera
            }

            guard let image = composited,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let drawableSize = view.drawableSize
            let extent = image.extent
            let scale = min(drawableSize.width / extent.width,
                            drawableSize.height / extent.height)
            let scaledWidth = extent.width * scale
            let scaledHeight = extent.height * scale
            let tx = (drawableSize.width - scaledWidth) * 0.5 - extent.origin.x * scale
            let ty = (drawableSize.height - scaledHeight) * 0.5 - extent.origin.y * scale
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
            let rendered = image.transformed(by: transform)

            let clearPass = MTLRenderPassDescriptor()
            clearPass.colorAttachments[0].texture = drawable.texture
            clearPass.colorAttachments[0].loadAction = .clear
            clearPass.colorAttachments[0].storeAction = .store
            clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            commandBuffer.makeRenderCommandEncoder(descriptor: clearPass)?.endEncoding()

            ciContext.render(rendered,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: colorSpace)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
