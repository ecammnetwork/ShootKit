//
//  CoreImageView.m
//  Objective-C Sample
//

#import "CoreImageView.h"

@implementation CoreImageView {
    CIContext *_ciContext;
    id<MTLCommandQueue> _commandQueue;
    CGColorSpaceRef _colorSpace;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self commonInit];
    return self;
}

- (instancetype)initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device {
    self = [super initWithFrame:frameRect device:device];
    if (self) [self commonInit];
    return self;
}

- (void)commonInit {
    if (self.device == nil) {
        self.device = MTLCreateSystemDefaultDevice();
    }
    self.framebufferOnly = NO;              // CIContext writes directly into the drawable's texture
    self.enableSetNeedsDisplay = YES;
    self.paused = YES;                      // Draw on demand rather than at a fixed frame rate
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

    // Allow the view to blend with what's behind it.
    self.layer.opaque = NO;
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);

    _commandQueue = [self.device newCommandQueue];
    _ciContext = [CIContext contextWithMTLCommandQueue:_commandQueue options:nil];
    _colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}

- (void)dealloc {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}

- (void)setImage:(CIImage *)image {
    _image = image;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    CIImage *image = self.image;
    id<CAMetalDrawable> drawable = self.currentDrawable;
    if (image == nil || drawable == nil) return;

    CGSize drawableSize = self.drawableSize;
    CGRect imageExtent = image.extent;

    // Aspect-fit the image into the drawable, centered.
    CGFloat scale = MIN(drawableSize.width  / imageExtent.size.width,
                        drawableSize.height / imageExtent.size.height);
    CGFloat scaledWidth  = imageExtent.size.width  * scale;
    CGFloat scaledHeight = imageExtent.size.height * scale;
    CGFloat tx = (drawableSize.width  - scaledWidth)  * 0.5 - imageExtent.origin.x * scale;
    CGFloat ty = (drawableSize.height - scaledHeight) * 0.5 - imageExtent.origin.y * scale;

    CGAffineTransform transform = CGAffineTransformMake(scale, 0, 0, scale, tx, ty);
    CIImage *rendered = [image imageByApplyingTransform:transform];

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];

    // Clear the drawable to transparent before rendering, so unfilled areas stay transparent
    // rather than showing whatever the previous drawable in the swap chain contained.
    MTLRenderPassDescriptor *clearPass = [MTLRenderPassDescriptor renderPassDescriptor];
    clearPass.colorAttachments[0].texture = drawable.texture;
    clearPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    clearPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> clearEncoder = [commandBuffer renderCommandEncoderWithDescriptor:clearPass];
    [clearEncoder endEncoding];

    [_ciContext render:rendered
          toMTLTexture:drawable.texture
         commandBuffer:commandBuffer
                bounds:CGRectMake(0, 0, drawableSize.width, drawableSize.height)
            colorSpace:_colorSpace];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
