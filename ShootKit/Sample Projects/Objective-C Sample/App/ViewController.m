//
//  ViewController.m
//  Objective-C Sample
//
//  Created by Michael Forrest on 02/06/2023.
//

#import "ViewController.h"
#import "Lib/SampleBufferDisplayView.h"
#import "Lib/CameraSource.h"
#import "Lib/CoreImageView.h"

@import ShootKit;
@import AVKit;

@interface ViewController()<ShootServerDelegate, VideoPencilClientDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>{
    NSMutableSet<ShootCamera*>*shootCameras;
    CMSampleBufferRef latestVideoPencilBuffer;
    CMSampleBufferRef latestCameraBuffer;
    NSViewController * shootControlsViewController;
    dispatch_queue_t videoPencilQueue;
}

@property(strong, nonatomic) ShootServer * shootServer;

@property(strong, nonatomic) VideoPencilClient * videoPencilClient;

@property(strong, nonatomic) CameraSource * cameraSource;

@property (weak) IBOutlet SampleBufferDisplayView *shootCameraView;
@property (weak) IBOutlet NSTextField *shootInfoLabel;
@property (weak) IBOutlet NSStackView *shootStackView;
@property (weak) IBOutlet NSView *shootControlsContainer;

@property (weak) IBOutlet SampleBufferDisplayView *cameraPreview;
@property (weak) IBOutlet CoreImageView *videoPencilLayerView;
@property (weak) IBOutlet NSTextField *videoPencilLabel;
@property (weak) IBOutlet NSStackView *videoPencilStackView;
@end


@implementation ViewController{
    
}

- (void)viewDidLoad {
    [super viewDidLoad];
    shootCameras = [[NSMutableSet alloc] init];
    latestVideoPencilBuffer = nil;
    videoPencilQueue = dispatch_queue_create("Video Pencil Return",
                                                                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    self.shootServer = [[ShootServer alloc] initWithName: @"Obj-C Demo" delegate: self];
    self.videoPencilClient = [[VideoPencilClient alloc] initWithName: @"Obj-C Demo" size: CGSizeMake(1920, 1080) delegate: self queue: videoPencilQueue ciContext:nil];
    
    [self startMacCamera];
}

#pragma mark - VideoPencilClientDelegate
- (void)videoPencilDidConnect:(VideoPencilClient * _Nonnull)client {
    self.videoPencilLabel.stringValue = @"Connected to Video Pencil";
}

-(void) videoPencilDidReceiveFrom:(VideoPencilClient *)from frame:(CIImage *)frame presentationTimeStamp:(CMTime)presentationTimeStamp presentationDuration:(CMTime)presentationDuration{

    dispatch_async(dispatch_get_main_queue(), ^{
        self.videoPencilLayerView.image = frame;
    });
}

- (void)videoPencilDidDisconnect:(VideoPencilClient * _Nonnull)client {
    self.videoPencilLabel.stringValue = @"Disconnected";
}



#pragma mark - ShootServerDelegate
-(BOOL)shootCameraShouldCreateSampleBuffers{
    return true; // otherwise you just get CVPixelBuffers
}
- (void)shootServerDidDiscoverWithCamera:(ShootCamera *)camera{
    [shootCameras addObject:camera];
    [camera startVideoStream];
    
    self.shootInfoLabel.stringValue = camera.name;
    
    
    // Supply ShootCamera buffers to self.shootCameraView
    AVSampleBufferDisplayLayer * layer = self.shootCameraView.sampleBufferLayer;
    [layer requestMediaDataWhenReadyOnQueue:dispatch_get_main_queue() usingBlock:^{
        if(layer.isReadyForMoreMediaData){
            [layer enqueueSampleBuffer: camera.latestSampleBuffer];
        }
    }];
    
    // Add the camera controls
    if(shootControlsViewController != nil) return;
    
    shootControlsViewController = [ShootControlsViewFactory makeShootControlsFor:camera minWidth: 300];
    
    NSWindow *floatingWindow = [[NSWindow alloc] initWithContentRect: NSMakeRect(300, 300, 600, 400)
                                                           styleMask: NSWindowStyleMaskResizable  | NSWindowStyleMaskTitled | NSWindowStyleMaskHUDWindow
                                                             backing: NSBackingStoreBuffered
                                                               defer: NO];
    [floatingWindow setTitle: camera.name];
    [floatingWindow setLevel: NSNormalWindowLevel];
    [floatingWindow setContentViewController: shootControlsViewController];
    [floatingWindow makeKeyAndOrderFront:nil];
    
}

- (void)shootServerWasDisconnectedFrom:(ShootCamera * _Nonnull)camera {
    [shootCameras removeObject: camera];
}

#pragma mark - Mac Camera
-(void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection{
    AVSampleBufferDisplayLayer * layer = self.cameraPreview.sampleBufferLayer;
    if (layer.isReadyForMoreMediaData) {
        [layer enqueueSampleBuffer:sampleBuffer];
    }

    CIImage* frame = [[CIImage alloc] initWithCVPixelBuffer:CMSampleBufferGetImageBuffer(sampleBuffer)];
    NSError * error;
    [self.videoPencilClient sendFrame:frame presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer) presentationDuration:CMSampleBufferGetDuration(sampleBuffer) error:&error];
}



#pragma mark - Demo-specific

-(void)startMacCamera{
    
    self.cameraSource = [[CameraSource alloc] initWithCaptureDelegate:self];
    [self.cameraSource selectCameraNamed: @"FaceTime HD Camera"];
   
    
}


#pragma mark - All the other protocol callbacks for reference

- (void)videoPencilDidReceiveFrom:(VideoPencilClient * _Nonnull)from pixelBuffer:(CVPixelBufferRef _Nonnull)pixelBuffer presentationTimeStamp:(CMTime)presentationTimeStamp presentationDuration:(CMTime)presentationDuration{
    
}
// bit awkward that I'm pushing the individual camera callbacks to the server delegate
// this can be refined in time.
- (void)shootCameraWasDisconnectedWithCamera:(ShootCamera * _Nonnull)camera {
    
}

- (void)shootCameraWasIdentifiedWithCamera:(ShootCamera * _Nonnull)camera {
    
}

- (void)shootCameraWithCamera:(ShootCamera * _Nonnull)camera didReceivePixelBuffer:(CVPixelBufferRef _Nonnull)pixelBuffer presentationTimeStamp:(CMTime)presentationTimeStamp presentationDuration:(CMTime)presentationDuration {
    
}

- (void)shootCameraWithCamera:(ShootCamera * _Nonnull)camera didReceiveSampleBuffer:(CMSampleBufferRef _Nonnull)sampleBuffer {
    
}
@end
