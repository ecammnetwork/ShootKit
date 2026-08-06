//
//  CoreImageView.h
//  Objective-C Sample
//
//  A Metal-backed view that renders a CIImage each frame via a CIContext.
//

#import <MetalKit/MetalKit.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

@interface CoreImageView : MTKView

@property (nonatomic, strong, nullable) CIImage *image;

@end

NS_ASSUME_NONNULL_END
