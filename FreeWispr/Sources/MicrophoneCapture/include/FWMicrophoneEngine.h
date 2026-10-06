#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps AVAudioEngine operations and their Objective-C exception boundary native.
@interface FWMicrophoneEngine : NSObject
@property (nonatomic, copy, nullable) void (^onConfigurationChange)(void);
+ (BOOL)isDefaultInputInUse;
/// Injectable native engine factory for testing exception recovery without hardware.
- (instancetype)initWithEngineFactory:(AVAudioEngine * (^)(void))engineFactory;
- (BOOL)startWithTap:(AVAudioNodeTapBlock)tap
               error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(start(tap:));
- (void)stop;
@end

NS_ASSUME_NONNULL_END
