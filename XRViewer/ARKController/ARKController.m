#import "ARKController.h"
#import <os/lock.h>
#import "WebARKHeader.h"
#import <AVFoundation/AVFoundation.h>
#import "ARKMetalController.h"
#import <Accelerate/Accelerate.h>
#import "Compression.h"
#import "XRViewer-Swift.h"

@interface ARKController ()
{
    NSDictionary *arkData;
    os_unfair_lock lock;
    NSDictionary* computerVisionData;
}

@property(nonatomic) ShowMode showMode;
@property(nonatomic) ShowOptions showOptions;

/*
 Computer vision properties
 We hold different data structures, like accelerate, NSData, and NSString buffers,
 to avoid allocating/deallocating a huge amount of memory on each frame
 */
/// Luma buffer
@property vImage_Buffer lumaBuffer;
/// A temporary luma buffer used by the Accelerate framework in the buffer scale opration
@property void* lumaScaleTemporaryBuffer;
/// The luma buffer size that's being sent to JS
@property CGSize lumaBufferSize;
/// A data buffer holding the luma information. It's created only onced reused on every frame
/// by means of the replaceBytesInRange method
@property(nonatomic, strong) NSMutableData* lumaDataBuffer;
/// The luma string buffer being sent to JS
@property(nonatomic, strong) NSMutableString* lumaBase64StringBuffer;
/*
 The same properties for luma are used for chroma
 */
@property vImage_Buffer chromaBuffer;
@property void* chromaScaleTemporaryBuffer;
@property CGSize chromaBufferSize;
@property(nonatomic, strong) NSMutableData* chromaDataBuffer;
@property(nonatomic, strong) NSMutableString* chromaBase64StringBuffer;

/// The CV image being sent to JS is downscaled using the metho
/// downscaleByFactorOf2UntilLargestSideIsLessThan512AvoidingFractionalSides
/// This call has a side effect on computerVisionImageScaleFactor, that's later used
/// in order to scale the intrinsics of the camera
@property (nonatomic) float computerVisionImageScaleFactor;

@end

@implementation ARKController {
}

#pragma mark Interface

- (void)dealloc
{
    DDLogDebug(@"ARKController dealloc");
}

- (instancetype)initWithType:(ARKType)type rootView:(UIView *)rootView
{
    self = [super init];
    
    if (self)
    {
        lock = OS_UNFAIR_LOCK_INIT;
        self.objects = [NSMutableDictionary new];
        computerVisionData = NULL;
        arkData = NULL;

        self.addedAnchorsSinceLastFrame = [NSMutableArray new];
        self.removedAnchorsSinceLastFrame = [NSMutableArray new];
        self.arkitGeneratedAnchorIDUserAnchorIDMap = [NSMutableDictionary new];
        [self setShouldUpdateWindowSize:YES];

        [self setSession:[ARSession new]];
        [[self session] setDelegate:self];
        [self setArSessionState:ARKSessionUnknown];
        
        // don't want anyone using this
        self.backgroundWorldMap = nil;

        /**
         A configuration for running world tracking.
         
         @discussion World tracking provides 6 degrees of freedom tracking of the device.
         By finding feature points in the scene, world tracking enables performing hit-tests against the frame.
         Tracking can no longer be resumed once the session is paused.
         */
        
        ARWorldTrackingConfiguration* worldTrackingConfiguration = [ARWorldTrackingConfiguration new];
        
        [worldTrackingConfiguration setPlaneDetection:ARPlaneDetectionHorizontal | ARPlaneDetectionVertical];
        [worldTrackingConfiguration setWorldAlignment:ARWorldAlignmentGravityAndHeading];
        [self setConfiguration: worldTrackingConfiguration];
        
        Class cls = (type == ARKMetal) ? [ARKMetalController class] : [ARKSceneKitController class];
        id<ARKControllerProtocol> controller = [[cls alloc] initWithSesion:[self session] size:[rootView bounds].size];
        [self setController:controller];
        [rootView addSubview:[controller getRenderView]];
        [[controller getRenderView] setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[[[controller getRenderView] topAnchor] constraintEqualToAnchor:[rootView topAnchor]] setActive:YES];
        [[[[controller getRenderView] leftAnchor] constraintEqualToAnchor:[rootView leftAnchor]] setActive:YES];
        [[[[controller getRenderView] rightAnchor] constraintEqualToAnchor:[rootView rightAnchor]] setActive:YES];
        [[[[controller getRenderView] bottomAnchor] constraintEqualToAnchor:[rootView bottomAnchor]] setActive:YES];
        
        [[self controller] setHitTestFocus:[[[self controller] getRenderView] center]];

        self.interfaceOrientation = [Utils getInterfaceOrientationFromDeviceOrientation];
        
        self.lumaDataBuffer = nil;
        self.lumaBase64StringBuffer = nil;
        self.chromaDataBuffer = nil;
        self.chromaBase64StringBuffer = nil;
        self.computerVisionImageScaleFactor = 4.0;
        self.lumaBufferSize = CGSizeMake(0.0f, 0.0f);

        self.sendingWorldSensingDataAuthorizationStatus = SendWorldSensingDataAuthorizationStateNotDetermined;
        self.detectionImageActivationPromises = [NSMutableDictionary new];
        self.referenceImageMap = [NSMutableDictionary new];
        self.detectionImageCreationRequests = [NSMutableArray new];
        self.detectionImageCreationPromises = [NSMutableDictionary new];
        self.detectionImageActivationAfterRemovalPromises = [NSMutableDictionary new];
        
        self.getWorldMapPromise = nil;
        self.setWorldMapPromise = nil;
        
        NSFileManager *filemgr = [NSFileManager defaultManager];

        NSArray *dirPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES );
        NSURL *docsDir = [NSURL fileURLWithPath:[dirPaths objectAtIndex:0]];
        NSURL *newDir = [docsDir URLByAppendingPathComponent:@"maps" isDirectory:YES];
        //if ([storeURL checkResourceIsReachableAndReturnError:&error]) {
        NSError* theError = nil;
        if ([filemgr createDirectoryAtURL:newDir withIntermediateDirectories:YES attributes:nil error:&theError] == NO)
        {
            // Failed to create directory
            self.worldSaveURL = nil;
            DDLogError(@"Couldn't create map save directory error - %@", theError);
        } else {
            self.worldSaveURL = [newDir URLByAppendingPathComponent:@"webxrviewer"];
        }
 
        self.numberOfFramesWithoutSendingFaceGeometry = 0;
    }
    
    return self;
}

- (void)viewWillTransitionToSize:(CGSize)size
{
    [[self controller] setHitTestFocus:CGPointMake(size.width / 2, size.height / 2)];
    self.interfaceOrientation = [Utils getInterfaceOrientationFromDeviceOrientation];
}

- (NSDictionary *)arkData
{
    NSDictionary *data;
    
    os_unfair_lock_lock(&(lock));
    data = arkData;
    os_unfair_lock_unlock(&(lock));
    
  //  return [data copy];
    return data;
}

- (NSDictionary*)computerVisionData {
    NSDictionary* data;
    
    os_unfair_lock_lock(&(lock));
    data = computerVisionData;
    computerVisionData = NULL;
    os_unfair_lock_unlock(&(lock));
    
 //   return [data copy];
    return data;
}

- (NSData *) getDecompressedData:(NSData *) compressed {
    size_t dst_buffer_size = compressed.length * 8;
    
    uint8_t *src_buffer = malloc(compressed.length);
    [compressed getBytes:src_buffer length:compressed.length];

    while (YES) {
        uint8_t *dst_buffer = malloc(dst_buffer_size);
        size_t decompressedSize = compression_decode_buffer(dst_buffer, dst_buffer_size, src_buffer, compressed.length, nil, COMPRESSION_ZLIB);

        // error!
        if (decompressedSize == 0) {
            free(dst_buffer);
            free(src_buffer);
            return NULL;
        }

        // overflow, try again
        if (decompressedSize == dst_buffer_size) {
            dst_buffer_size *= 2;
            free(dst_buffer);
            continue;
        }
        NSData *decompressed = [[NSData alloc] initWithBytes:dst_buffer length:decompressedSize];
        free(dst_buffer);
        free(src_buffer);
        return decompressed;
    }
}

- (NSData *) getCompressedData:(NSData*) input {
    size_t dst_buffer_size = MAX(input.length / 8, 10);

    uint8_t *src_buffer = malloc(input.length);
    [input getBytes:src_buffer length:input.length];

    while (YES)
    {
        uint8_t *dst_buffer = malloc(dst_buffer_size);
        size_t compressedSize = compression_encode_buffer(dst_buffer, dst_buffer_size, src_buffer, input.length, nil, COMPRESSION_ZLIB);

        // overflow, try again
        if (compressedSize == 0) {
            dst_buffer_size *= 2;
            free(dst_buffer);
            continue;
        }
        NSData *compressed = [[NSData alloc] initWithBytes:dst_buffer length:compressedSize];
        free(dst_buffer);
        free(src_buffer);
        return compressed;
    }
}

- (void)setShowMode:(ShowMode)showMode
{
    _showMode = showMode;
    
    [[self controller] setShowMode:showMode];
}

- (void)setShowOptions:(ShowOptions)showOptions
{
    _showOptions = showOptions;
    
    [[self controller] setShowOptions:showOptions];
}

- (NSArray *)hitTestNormPoint:(CGPoint)normPoint types:(NSUInteger)type
{
    CGSize renderSize = [[[self controller] getRenderView] bounds].size;
    
    CGPoint point = CGPointMake(normPoint.x * renderSize.width, normPoint.y * renderSize.height);
    
    NSArray *result = [[self controller] hitTest:point with:type];
    
    return hitTestResultArrayFromResult(result);
}

- (void)setSendingWorldSensingDataAuthorizationStatus:(SendWorldSensingDataAuthorizationState)authorizationStatus {
    _sendingWorldSensingDataAuthorizationStatus = authorizationStatus;
    
    switch (self.sendingWorldSensingDataAuthorizationStatus) {
        case SendWorldSensingDataAuthorizationStateNotDetermined: {
            NSLog(@"World sensing auth changed to not determined");
            break;
        }
        case SendWorldSensingDataAuthorizationStateAuthorized: {
            NSLog(@"World sensing auth changed to authorized");
            
            // make sure all the anchors are in the objects[] array, and mark them as added
            NSArray *anchors = [[[self session] currentFrame] anchors];
            for (ARAnchor* addedAnchor in anchors) {
                if (!self.objects[[self anchorIDFor:addedAnchor]]) {
                    NSMutableDictionary *addedAnchorDictionary = [[self createDictionaryFor:addedAnchor] mutableCopy];
                    self.objects[[self anchorIDFor:addedAnchor]] = addedAnchorDictionary;
                }
                [self.addedAnchorsSinceLastFrame addObject: self.objects[[self anchorIDFor:addedAnchor]]];
            }
            
            [self createRequestedDetectionImages];

            // Only need to do this if there's an outstanding world map request
            if (self.getWorldMapPromise) {
                [self _getWorldMap];
            }
            break;
        }
        case SendWorldSensingDataAuthorizationStateSinglePlane: {
            NSLog(@"World sensing auth changed to single plane");
            if (self.getWorldMapPromise) {
                [self _getWorldMap];
            }
            break;
        }
        case SendWorldSensingDataAuthorizationStateDenied: {
            NSLog(@"World sensing auth changed to denied");

            // still need to send the "required" anchors
            NSArray *anchors = [[[self session] currentFrame] anchors];
            for (ARAnchor* addedAnchor in anchors) {
                if (self.objects[[self anchorIDFor:addedAnchor]]) {
                    // if the anchor is in the current object list, and is now not being sent
                    // mark it as removed and remove from the object list
                    if (![self shouldSend:addedAnchor]) {
                        [self.removedAnchorsSinceLastFrame addObject:[self anchorIDFor:addedAnchor]];
                        self.objects[[self anchorIDFor:addedAnchor]] = nil;
                    }
                } else {
                    // if the anchor was not being sent but is in the approved list, start sending it
                    if ([self shouldSend:addedAnchor]) {
                        NSMutableDictionary *addedAnchorDictionary = [[self createDictionaryFor:addedAnchor] mutableCopy];
                        [self.addedAnchorsSinceLastFrame addObject: addedAnchorDictionary];
                        self.objects[[self anchorIDFor:addedAnchor]] = addedAnchorDictionary;
                    }
                }
            }
            
            if (self.getWorldMapPromise) {
                self.getWorldMapPromise(NO, @"The user denied access to world sensing data", nil);
                self.getWorldMapPromise = nil;
            }

            for (NSDictionary* referenceImageDictionary in self.detectionImageCreationRequests) {
                DetectionImageCreatedCompletionType block = self.detectionImageCreationPromises[referenceImageDictionary[@"uid"]];
                block(NO, @"The user denied access to world sensing data");
            }
            [self.detectionImageCreationRequests removeAllObjects];
            [self.detectionImageCreationPromises removeAllObjects];
            break;
        }
    }
}

#pragma mark Private

- (void)updateARKDataWithFrame:(ARFrame *)frame
{
    @synchronized(self)
    {
        if ([self request] == nil)
        {
            return;
        }
        
        if (frame)
        {
            NSMutableDictionary *newData = [NSMutableDictionary dictionaryWithCapacity:3]; // max request object
            NSInteger ts = (NSInteger) ([frame timestamp] * 1000.0);
            newData[@"timestamp"] = @(ts);

            // status of ARKit World Mapping
            newData[WEB_AR_WORLDMAPPING_STATUS_MESSAGE] = worldMappingState(frame);
            
            if ([[self request][WEB_AR_LIGHT_INTENSITY_OPTION] boolValue])
            {
                newData[WEB_AR_LIGHT_INTENSITY_OPTION] = @([[frame lightEstimate] ambientIntensity]);
                
                NSMutableDictionary* lightDictionary = [NSMutableDictionary new];
                lightDictionary[WEB_AR_LIGHT_INTENSITY_OPTION] = @([[frame lightEstimate] ambientIntensity]);
                lightDictionary[WEB_AR_LIGHT_AMBIENT_COLOR_TEMPERATURE_OPTION] = @([[frame lightEstimate] ambientColorTemperature]);
                
                if ([[frame lightEstimate] isKindOfClass:[ARDirectionalLightEstimate class]]) {
                    ARDirectionalLightEstimate* directionalLightEstimate = (ARDirectionalLightEstimate*)[frame lightEstimate];
                    lightDictionary[WEB_AR_PRIMARY_LIGHT_DIRECTION_OPTION] = @{
                                                                               @"x": @(directionalLightEstimate.primaryLightDirection[0]),
                                                                               @"y": @(directionalLightEstimate.primaryLightDirection[1]),
                                                                               @"z": @(directionalLightEstimate.primaryLightDirection[2])
                                                                               };
                    lightDictionary[WEB_AR_PRIMARY_LIGHT_INTENSITY_OPTION] = @(directionalLightEstimate.primaryLightIntensity);
                    
                }
                newData[WEB_AR_LIGHT_OBJECT_OPTION] = lightDictionary;
            }
            if ([[self request][WEB_AR_CAMERA_OPTION] boolValue])
            {
                CGSize size = [[self controller] getRenderView].frame.size;
                matrix_float4x4 projectionMatrix = [[frame camera] projectionMatrixForOrientation:self.interfaceOrientation
                                                                               viewportSize:size
                                                                                      zNear:AR_CAMERA_PROJECTION_MATRIX_Z_NEAR
                                                                                       zFar:AR_CAMERA_PROJECTION_MATRIX_Z_FAR];
                newData[WEB_AR_PROJ_CAMERA_OPTION] = arrayFromMatrix4x4(projectionMatrix);
             
                matrix_float4x4 viewMatrix = [frame.camera viewMatrixForOrientation:self.interfaceOrientation];
                matrix_float4x4 modelMatrix = matrix_invert(viewMatrix);
                
                newData[WEB_AR_CAMERA_TRANSFORM_OPTION] = arrayFromMatrix4x4(modelMatrix);
                newData[WEB_AR_CAMERA_VIEW_OPTION] = arrayFromMatrix4x4(viewMatrix);
            }
            if ([[self request][WEB_AR_3D_OBJECTS_OPTION] boolValue])
            {
                NSArray* anchorsArray = [self currentAnchorsArray];
                newData[WEB_AR_3D_OBJECTS_OPTION] = anchorsArray;

                // Prepare the objectsRemoved array
                NSArray *removedObjects = [self.removedAnchorsSinceLastFrame copy];
                [self.removedAnchorsSinceLastFrame removeAllObjects];
                newData[WEB_AR_3D_REMOVED_OBJECTS_OPTION] = removedObjects;
                
                // Prepare the newObjects array
                NSArray *newObjects = [self.addedAnchorsSinceLastFrame copy];
                [self.addedAnchorsSinceLastFrame removeAllObjects];
                newData[WEB_AR_3D_NEW_OBJECTS_OPTION] = newObjects;
            }
            if ([self computerVisionDataEnabled] && [self computerVisionFrameRequested]) {
                NSMutableDictionary *cameraInformation = [NSMutableDictionary new];
                CGSize cameraImageResolution = [[frame camera] imageResolution];
                cameraInformation[@"cameraImageResolution"] = @{
                                                                @"width": @(cameraImageResolution.width),
                                                                @"height": @(cameraImageResolution.height)
                                                                };
                
                
                matrix_float3x3 cameraIntrinsics = [[frame camera] intrinsics];
                matrix_float3x3 resizedCameraIntrinsics = [[frame camera] intrinsics];
                for (int i = 0; i < 3; i++) {
                    for (int j = 0; j < 3; j++) {
                        resizedCameraIntrinsics.columns[i][j] = cameraIntrinsics.columns[i][j]/self.computerVisionImageScaleFactor;
                    }
                }
                resizedCameraIntrinsics.columns[2][2] = 1.0f;

                cameraInformation[@"cameraIntrinsics"] = arrayFromMatrix3x3(resizedCameraIntrinsics);
                
                // Get the projection matrix
                CGSize viewportSize = [[self controller] getRenderView].frame.size;
                matrix_float4x4 projectionMatrix = [[frame camera] projectionMatrixForOrientation:self.interfaceOrientation
                                                                                     viewportSize:viewportSize
                                                                                            zNear:AR_CAMERA_PROJECTION_MATRIX_Z_NEAR
                                                                                             zFar:AR_CAMERA_PROJECTION_MATRIX_Z_FAR];
                cameraInformation[@"projectionMatrix"] = arrayFromMatrix4x4(projectionMatrix);
                
                // Get the view matrix
                matrix_float4x4 viewMatrix = [frame.camera viewMatrixForOrientation:self.interfaceOrientation];
                cameraInformation[@"viewMatrix"] = arrayFromMatrix4x4(viewMatrix);
                
                cameraInformation[@"inverse_viewMatrix"] = arrayFromMatrix4x4(matrix_invert(viewMatrix));
                
                
                // Send also the interface orientation
                cameraInformation[@"interfaceOrientation"] = @(self.interfaceOrientation);
                
                NSMutableDictionary *cvInformation = [NSMutableDictionary new];
                NSMutableDictionary *frameInformation = [NSMutableDictionary new];
                NSInteger timestamp = (NSInteger) ([frame timestamp] * 1000.0);
                frameInformation[@"timestamp"] = @(timestamp);
                
                // TODO: prepare depth data
                frameInformation[@"capturedDepthData"] = nil;
                frameInformation[@"capturedDepthDataTimestamp"] = nil;
                
                // Computer vision data
                [self updateBase64BuffersFromPixelBuffer:frame.capturedImage];
                
                NSMutableDictionary *lumaBufferDictionary = [NSMutableDictionary new];
                lumaBufferDictionary[@"size"] = @{
                                        @"width": @(self.lumaBufferSize.width),
                                        @"height": @(self.lumaBufferSize.height),
                                        @"bytesPerRow": @(self.lumaBufferSize.width * sizeof(Pixel_8)),
                                        @"bytesPerPixel": @(sizeof(Pixel_8))
                                        };
                lumaBufferDictionary[@"buffer"] = self.lumaBase64StringBuffer;
                
                
                NSMutableDictionary *chromaBufferDictionary = [NSMutableDictionary new];
                chromaBufferDictionary[@"size"] = @{
                                        @"width": @(self.chromaBufferSize.width),
                                        @"height": @(self.chromaBufferSize.height),
                                        @"bytesPerRow": @(self.chromaBufferSize.width * sizeof(Pixel_16U)),
                                        @"bytesPerPixel": @(sizeof(Pixel_16U))
                                        };
                chromaBufferDictionary[@"buffer"] = self.chromaBase64StringBuffer;
                
                frameInformation[@"buffers"] = @[lumaBufferDictionary, chromaBufferDictionary];
                frameInformation[@"pixelFormatType"] = [self stringForOSType:CVPixelBufferGetPixelFormatType(frame.capturedImage)];
                
                cvInformation[@"frame"] = frameInformation;
                cvInformation[@"camera"] = cameraInformation;
                
                os_unfair_lock_lock(&(lock));
                computerVisionData = [cvInformation copy];
                os_unfair_lock_unlock(&(lock));
            }

            newData[WEB_AR_3D_GEOALIGNED_OPTION] = @([[self configuration] worldAlignment] == ARWorldAlignmentGravityAndHeading ? YES : NO);
            newData[WEB_AR_3D_VIDEO_ACCESS_OPTION] = @([self computerVisionDataEnabled] ? YES : NO);
            
            os_unfair_lock_lock(&(lock));
            arkData = [newData copy];
            os_unfair_lock_unlock(&(lock));
        }
    }
}

-(void)logPixelBufferInfo:(CVPixelBufferRef)capturedImagePixelBuffer {
    size_t capturedImagePixelBufferWidth = CVPixelBufferGetWidth(capturedImagePixelBuffer);
    size_t capturedImagePixelBufferHeight = CVPixelBufferGetHeight(capturedImagePixelBuffer);
    size_t capturedImagePixelBufferBytesPerRow = CVPixelBufferGetBytesPerRow(capturedImagePixelBuffer);
    size_t capturedImageNumberOfPlanes = CVPixelBufferGetPlaneCount(capturedImagePixelBuffer);
    CFTypeID capturedImagePixelBufferTypeID = CVPixelBufferGetTypeID();
    size_t capturedImagePixelBufferDataSize = CVPixelBufferGetDataSize(capturedImagePixelBuffer);
    OSType capturedImagePixelBufferPixelFormatType = CVPixelBufferGetPixelFormatType(capturedImagePixelBuffer);
    void* capturedImagePixelBufferBaseAddress = CVPixelBufferGetBaseAddress(capturedImagePixelBuffer);

    NSLog(@"\n\nnumberOfPlanes: %zu\npixelBufferWidth: %zu\npixelBufferHeight: %zu\npixelBufferTypeID: %lu\npixelBufferDataSize: %zu\npixelBufferBytesPerRow: %zu\npixelBufferPIxelFormatType: %@\npixelBufferBaseAddress: %p\n",
          capturedImageNumberOfPlanes,
          capturedImagePixelBufferWidth,
          capturedImagePixelBufferHeight,
          capturedImagePixelBufferTypeID,
          capturedImagePixelBufferDataSize,
          capturedImagePixelBufferBytesPerRow,
          [self stringForOSType:capturedImagePixelBufferPixelFormatType],
          capturedImagePixelBufferBaseAddress);
}

-(void)updateBase64BuffersFromPixelBuffer:(CVPixelBufferRef)capturedImagePixelBuffer {

    // Luma
    CVPixelBufferLockBaseAddress(capturedImagePixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    //[self logPixelBufferInfo:capturedImagePixelBuffer];

    size_t lumaBufferWidth = CVPixelBufferGetWidthOfPlane(capturedImagePixelBuffer, 0);
    size_t lumaBufferHeight = CVPixelBufferGetHeightOfPlane(capturedImagePixelBuffer, 0);
    
    vImage_Buffer lumaSrcBuffer;
    lumaSrcBuffer.data = CVPixelBufferGetBaseAddressOfPlane(capturedImagePixelBuffer, 0);
    lumaSrcBuffer.width = lumaBufferWidth;
    lumaSrcBuffer.height = lumaBufferHeight;
    lumaSrcBuffer.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(capturedImagePixelBuffer, 0);
    
    size_t extraColumnsOnLeft;
    size_t extraColumnsOnRight;
    size_t extraColumnsOnTop;
    size_t extraColumnsOnBottom;
    CVPixelBufferGetExtendedPixels(capturedImagePixelBuffer, &extraColumnsOnLeft, &extraColumnsOnRight, &extraColumnsOnTop, &extraColumnsOnBottom);
    
    if (self.lumaBufferSize.width == 0.0f) {
        self.lumaBufferSize = [self downscaleByFactorOf2UntilLargestSideIsLessThan512AvoidingFractionalSides: CGSizeMake(lumaBufferWidth, lumaBufferHeight)];
    }
    self.chromaBufferSize = CGSizeMake(self.lumaBufferSize.width/2.0, self.lumaBufferSize.height/2.0);
    
    if (self.lumaBuffer.data == nil) {
        vImageBuffer_Init(&self->_lumaBuffer, self.lumaBufferSize.height, self.lumaBufferSize.width, 8 * sizeof(Pixel_8), kvImageNoFlags);
        vImageScale_Planar8(&self->_lumaBuffer, &self->_lumaBuffer, NULL, kvImageGetTempBufferSize);
        size_t scaledBufferSize = vImageScale_Planar8(&lumaSrcBuffer, &self->_lumaBuffer, NULL, kvImageGetTempBufferSize);
        self.lumaScaleTemporaryBuffer = malloc(scaledBufferSize * sizeof(Pixel_8));
    }

    vImage_Error scaleError = vImageScale_Planar8(&lumaSrcBuffer, &self->_lumaBuffer, self.lumaScaleTemporaryBuffer, kvImageNoFlags);
    if (scaleError != 0) {
        NSLog(@"Error scaling luma image");
        CVPixelBufferUnlockBaseAddress(capturedImagePixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    
    if (self.lumaDataBuffer == nil) {
        self.lumaDataBuffer = [NSMutableData dataWithBytes:self.lumaBuffer.data
                                                    length:self.lumaBuffer.width * self.lumaBuffer.height * sizeof(Pixel_8)];
    }
    for (int currentRow = 0; currentRow < self.lumaBuffer.height; currentRow++) {
        [self.lumaDataBuffer replaceBytesInRange:NSMakeRange(self.lumaBuffer.width * currentRow, self.lumaBuffer.width)
                                       withBytes:self.lumaBuffer.data + self.lumaBuffer.rowBytes * currentRow];
    }
    
    if (self.lumaBase64StringBuffer == nil) {
        self.lumaBase64StringBuffer = [NSMutableString new];
    }
    [self.lumaBase64StringBuffer setString:[self.lumaDataBuffer base64EncodedStringWithOptions:0]];
    

    // Chroma
    vImage_Buffer chromaSrcBuffer;
    chromaSrcBuffer.data = CVPixelBufferGetBaseAddressOfPlane(capturedImagePixelBuffer, 1);
    chromaSrcBuffer.width = CVPixelBufferGetWidthOfPlane(capturedImagePixelBuffer, 1);
    chromaSrcBuffer.height = CVPixelBufferGetHeightOfPlane(capturedImagePixelBuffer, 1);
    chromaSrcBuffer.rowBytes = CVPixelBufferGetBytesPerRowOfPlane(capturedImagePixelBuffer, 1);
    
    if (self->_chromaBuffer.data == nil) {
        vImageBuffer_Init(&self->_chromaBuffer, self.chromaBufferSize.height, self.chromaBufferSize.width, 8 * sizeof(Pixel_16U), kvImageNoFlags);
        size_t scaledBufferSize = vImageScale_Planar8(&chromaSrcBuffer, &self->_chromaBuffer, NULL, kvImageGetTempBufferSize);
        self.chromaScaleTemporaryBuffer = malloc(scaledBufferSize * sizeof(Pixel_16U));
    }

    scaleError = vImageScale_CbCr8(&chromaSrcBuffer, &self->_chromaBuffer, self.chromaScaleTemporaryBuffer, kvImageNoFlags);
    if (scaleError != 0) {
        NSLog(@"Error scaling chroma image");
        CVPixelBufferUnlockBaseAddress(capturedImagePixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }

    if (self.chromaDataBuffer == nil) {
        self.chromaDataBuffer = [NSMutableData dataWithBytes:self.chromaBuffer.data
                                                      length:self.chromaBuffer.width * self.chromaBuffer.height * sizeof(Pixel_16U)];
    }
    for (int currentRow = 0; currentRow < self.chromaBuffer.height; currentRow++) {
        [self.chromaDataBuffer replaceBytesInRange:NSMakeRange(self.chromaBuffer.width * currentRow * sizeof(Pixel_16U), self.chromaBuffer.width * sizeof(Pixel_16U))
                                         withBytes:self.chromaBuffer.data + self.chromaBuffer.rowBytes * currentRow];
    }

    if (self.chromaBase64StringBuffer == nil) {
        self.chromaBase64StringBuffer = [NSMutableString new];
    }
    [self.chromaBase64StringBuffer setString:[self.chromaDataBuffer base64EncodedStringWithOptions:0]];
    
    CVPixelBufferUnlockBaseAddress(capturedImagePixelBuffer, kCVPixelBufferLock_ReadOnly);
}

- (CGSize)downscaleByFactorOf2UntilLargestSideIsLessThan512AvoidingFractionalSides:(CGSize)originalSize {
    CGSize result = originalSize;

    BOOL largestSideLessThan512Found = NO;
    BOOL fractionalSideFound = NO;
    self.computerVisionImageScaleFactor = 1.0;
    while (!(largestSideLessThan512Found || fractionalSideFound)) {
        if ((int)result.width%2 != 0 || (int)result.height%2 != 0) {
            fractionalSideFound = YES;
        } else {
            result = CGSizeMake(result.width/2.0, result.height/2.0);
            self.computerVisionImageScaleFactor *= 2.0;

            CGFloat largestSide = MAX(result.width, result.height);
            if (largestSide < 512) {
                largestSideLessThan512Found = YES;
            }
        }
    }

    return result;
}

- (NSString *)stringForOSType:(OSType)type {
    switch (type) {
        case kCVPixelFormatType_1Monochrome:                   return @"kCVPixelFormatType_1Monochrome";
        case kCVPixelFormatType_2Indexed:                      return @"kCVPixelFormatType_2Indexed";
        case kCVPixelFormatType_4Indexed:                      return @"kCVPixelFormatType_4Indexed";
        case kCVPixelFormatType_8Indexed:                      return @"kCVPixelFormatType_8Indexed";
        case kCVPixelFormatType_1IndexedGray_WhiteIsZero:      return @"kCVPixelFormatType_1IndexedGray_WhiteIsZero";
        case kCVPixelFormatType_2IndexedGray_WhiteIsZero:      return @"kCVPixelFormatType_2IndexedGray_WhiteIsZero";
        case kCVPixelFormatType_4IndexedGray_WhiteIsZero:      return @"kCVPixelFormatType_4IndexedGray_WhiteIsZero";
        case kCVPixelFormatType_8IndexedGray_WhiteIsZero:      return @"kCVPixelFormatType_8IndexedGray_WhiteIsZero";
        case kCVPixelFormatType_16BE555:                       return @"kCVPixelFormatType_16BE555";
        case kCVPixelFormatType_16LE555:                       return @"kCVPixelFormatType_16LE555";
        case kCVPixelFormatType_16LE5551:                      return @"kCVPixelFormatType_16LE5551";
        case kCVPixelFormatType_16BE565:                       return @"kCVPixelFormatType_16BE565";
        case kCVPixelFormatType_16LE565:                       return @"kCVPixelFormatType_16LE565";
        case kCVPixelFormatType_24RGB:                         return @"kCVPixelFormatType_24RGB";
        case kCVPixelFormatType_24BGR:                         return @"kCVPixelFormatType_24BGR";
        case kCVPixelFormatType_32ARGB:                        return @"kCVPixelFormatType_32ARGB";
        case kCVPixelFormatType_32BGRA:                        return @"kCVPixelFormatType_32BGRA";
        case kCVPixelFormatType_32ABGR:                        return @"kCVPixelFormatType_32ABGR";
        case kCVPixelFormatType_32RGBA:                        return @"kCVPixelFormatType_32RGBA";
        case kCVPixelFormatType_64ARGB:                        return @"kCVPixelFormatType_64ARGB";
        case kCVPixelFormatType_48RGB:                         return @"kCVPixelFormatType_48RGB";
        case kCVPixelFormatType_32AlphaGray:                   return @"kCVPixelFormatType_32AlphaGray";
        case kCVPixelFormatType_16Gray:                        return @"kCVPixelFormatType_16Gray";
        case kCVPixelFormatType_30RGB:                         return @"kCVPixelFormatType_30RGB";
        case kCVPixelFormatType_422YpCbCr8:                    return @"kCVPixelFormatType_422YpCbCr8";
        case kCVPixelFormatType_4444YpCbCrA8:                  return @"kCVPixelFormatType_4444YpCbCrA8";
        case kCVPixelFormatType_4444YpCbCrA8R:                 return @"kCVPixelFormatType_4444YpCbCrA8R";
        case kCVPixelFormatType_4444AYpCbCr8:                  return @"kCVPixelFormatType_4444AYpCbCr8";
        case kCVPixelFormatType_4444AYpCbCr16:                 return @"kCVPixelFormatType_4444AYpCbCr16";
        case kCVPixelFormatType_444YpCbCr8:                    return @"kCVPixelFormatType_444YpCbCr8";
        case kCVPixelFormatType_422YpCbCr16:                   return @"kCVPixelFormatType_422YpCbCr16";
        case kCVPixelFormatType_422YpCbCr10:                   return @"kCVPixelFormatType_422YpCbCr10";
        case kCVPixelFormatType_444YpCbCr10:                   return @"kCVPixelFormatType_444YpCbCr10";
        case kCVPixelFormatType_420YpCbCr8Planar:              return @"kCVPixelFormatType_420YpCbCr8Planar";
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:     return @"kCVPixelFormatType_420YpCbCr8PlanarFullRange";
        case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar:        return @"kCVPixelFormatType_422YpCbCr_4A_8BiPlanar";
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  return @"kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange";
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:   return @"kCVPixelFormatType_420YpCbCr8BiPlanarFullRange";
        case kCVPixelFormatType_422YpCbCr8_yuvs:               return @"kCVPixelFormatType_422YpCbCr8_yuvs";
        case kCVPixelFormatType_422YpCbCr8FullRange:           return @"kCVPixelFormatType_422YpCbCr8FullRange";
        case kCVPixelFormatType_OneComponent8:                 return @"kCVPixelFormatType_OneComponent8";
        case kCVPixelFormatType_TwoComponent8:                 return @"kCVPixelFormatType_TwoComponent8";
        case kCVPixelFormatType_30RGBLEPackedWideGamut:        return @"kCVPixelFormatType_30RGBLEPackedWideGamut";
        case kCVPixelFormatType_OneComponent16Half:            return @"kCVPixelFormatType_OneComponent16Half";
        case kCVPixelFormatType_OneComponent32Float:           return @"kCVPixelFormatType_OneComponent32Float";
        case kCVPixelFormatType_TwoComponent16Half:            return @"kCVPixelFormatType_TwoComponent16Half";
        case kCVPixelFormatType_TwoComponent32Float:           return @"kCVPixelFormatType_TwoComponent32Float";
        case kCVPixelFormatType_64RGBAHalf:                    return @"kCVPixelFormatType_64RGBAHalf";
        case kCVPixelFormatType_128RGBAFloat:                  return @"kCVPixelFormatType_128RGBAFloat";
        case kCVPixelFormatType_14Bayer_GRBG:                  return @"kCVPixelFormatType_14Bayer_GRBG";
        case kCVPixelFormatType_14Bayer_RGGB:                  return @"kCVPixelFormatType_14Bayer_RGGB";
        case kCVPixelFormatType_14Bayer_BGGR:                  return @"kCVPixelFormatType_14Bayer_BGGR";
        case kCVPixelFormatType_14Bayer_GBRG:                  return @"kCVPixelFormatType_14Bayer_GBRG";
        default: return @"UNKNOWN";
    }
}

- (NSString *)trackingState {
    return trackingState([[[self session] currentFrame] camera]);
}

- (void)updateFaceAnchorData:(ARFaceAnchor *)faceAnchor toDictionary:(NSMutableDictionary *)faceAnchorDictionary {
    NSMutableDictionary *geometryDictionary = faceAnchorDictionary[WEB_AR_GEOMETRY_OPTION];
    if (!geometryDictionary) {
        geometryDictionary = [NSMutableDictionary new];
        faceAnchorDictionary[WEB_AR_GEOMETRY_OPTION] = geometryDictionary;
    }
    NSMutableArray* vertices = [NSMutableArray arrayWithCapacity:faceAnchor.geometry.vertexCount];
    for (int i = 0; i < faceAnchor.geometry.vertexCount; i++) {
        [vertices addObject:dictFromVector3(faceAnchor.geometry.vertices[i])];
    }
    geometryDictionary[@"vertices"] = vertices;
    
    NSMutableArray *blendShapesDictionary = faceAnchorDictionary[WEB_AR_BLEND_SHAPES_OPTION];
    [self setBlendShapes:faceAnchor.blendShapes toArray:blendShapesDictionary];
    
    // Remove the rest of the geometry data, since it doesn't change
    geometryDictionary[@"vertexCount"] = nil;
    geometryDictionary[@"textureCoordinateCount"] = nil;
    geometryDictionary[@"textureCoordinates"] = nil;
    geometryDictionary[@"triangleCount"] = nil;
    geometryDictionary[@"triangleIndices"] = nil;
}

@end
