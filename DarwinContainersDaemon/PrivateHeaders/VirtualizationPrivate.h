//
//  VirtualizationPrivate.h
//  VirtualBuddy
//
//  Created by Guilherme Rambo on 07/04/22.
//

@import Virtualization;

NS_ASSUME_NONNULL_BEGIN

@interface _VZFramebuffer: NSObject

- (void)takeScreenshotWithCompletionHandler:(void(^)(NSImage *__nullable screenshot, NSError *__nullable error))completion;

@end

@interface _VZGraphicsDevice: NSObject

- (NSInteger)type;
- (NSArray <_VZFramebuffer *> *)framebuffers;

@end

@interface _VZMultiTouchDeviceConfiguration: NSObject <NSCopying>
@end

@interface _VZAppleTouchScreenConfiguration: _VZMultiTouchDeviceConfiguration
@end

@interface _VZUSBTouchScreenConfiguration: _VZMultiTouchDeviceConfiguration
@end

__attribute__((weak_import))
@interface _VZVirtualMachineStartOptions: NSObject <NSSecureCoding>

@property (assign) BOOL forceDFU;
@property (assign) BOOL stopInIBootStage1;
@property (assign) BOOL stopInIBootStage2;
@property (assign) BOOL bootMacOSRecovery;

@end

#if defined(MAC_OS_VERSION_13_0)
@interface VZVirtualMachineStartOptions (Private)

@property (assign) BOOL _forceDFU;
@property (assign) BOOL _stopInIBootStage1;
@property (assign) BOOL _stopInIBootStage2;

@end
#endif

@interface VZMacAuxiliaryStorage (Private)

- (NSDictionary <NSString *, id> *)_allNVRAMVariablesWithError:(NSError **)outError;
- (NSDictionary <NSString *, id> *)_allNVRAMVariablesInPartition:(NSUInteger)partition error:(NSError **)outError;
- (id __nullable)_valueForNVRAMVariableNamed:(NSString *)name error:(NSError **)arg2;
- (BOOL)_removeNVRAMVariableNamed:(NSString *)name error:(NSError **)arg2;
- (BOOL)_setValue:(id)arg1 forNVRAMVariableNamed:(NSString *)name error:(NSError **)arg3;

@end

@interface VZVirtualMachineConfiguration (Private)

@property (strong, setter=_setMultiTouchDevices:) NSArray <_VZMultiTouchDeviceConfiguration *> *_multiTouchDevices;

@end

@interface VZVirtualMachine (Private)

#if !defined(MAC_OS_VERSION_13_0) || MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_VERSION_13_0
- (void)_startWithOptions:(_VZVirtualMachineStartOptions *__nullable)options
        completionHandler:(void (^__nonnull)(NSError * _Nullable errorOrNil))completionHandler;
#endif

- (id)_USBDevices;
- (id)_keyboards;
- (id)_pointingDevices;
- (BOOL)_canAttachUSBDevices;
- (BOOL)_canDetachUSBDevices;
- (BOOL)_canAttachUSBDevice:(id)arg1;
- (BOOL)_canDetachUSBDevice:(id)arg1;
- (BOOL)_attachUSBDevice:(id)arg1 error:(void *)arg2;
- (BOOL)_detachUSBDevice:(id)arg1 error:(void *)arg2;
- (void)_getUSBControllerLocationIDWithCompletionHandler:(void(^)(id val))arg1;

@property (nonatomic, readonly) NSArray <_VZGraphicsDevice *> *_graphicsDevices;

@end

@interface VZMacPlatformConfiguration (Private)

@property (nonatomic, assign, setter=_setProductionModeEnabled:) BOOL _isProductionModeEnabled;

- (id __nullable)_platform;

@end

@interface VZVirtualMachineView (Private)

- (void)_setDelegate:(id)delegate;

@end

@interface _VZKeyboard : NSObject

- (void)sendKeyEvents:(NSArray<id> *)events;

@end

typedef NS_ENUM(long long, VZKeyEventType) {
    VZKeyEventTypeDown,
    VZKeyEventTypeUp
};

@interface _VZKeyEvent : NSObject

- (instancetype)initWithType:(VZKeyEventType)type keyCode:(unsigned short)keyCode;

@end

@interface _VZScreenCoordinatePointingDevice : NSObject

- (void)sendPointerEvents:(NSArray<id> *)events;

@end

@interface _VZScreenCoordinatePointerEvent : NSObject

- (instancetype)initWithLocation:(CGPoint)location pressedButtons:(unsigned short)pressedButtons;

@end

NS_ASSUME_NONNULL_END
