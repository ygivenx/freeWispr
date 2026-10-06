#import "FWMicrophoneEngine.h"
#include <math.h>
#import <CoreAudio/CoreAudio.h>

@implementation FWMicrophoneEngine {
    AVAudioEngine *_engine;
    AVAudioInputNode *_input;
    BOOL _tapInstalled;
    id _configurationObserver;
    AVAudioEngine * (^_engineFactory)(void);
}

- (instancetype)init {
    return [self initWithEngineFactory:^{ return [[AVAudioEngine alloc] init]; }];
}

- (instancetype)initWithEngineFactory:(AVAudioEngine * (^)(void))engineFactory {
    self = [super init];
    if (self) _engineFactory = [engineFactory copy];
    return self;
}

+ (BOOL)isDefaultInputInUse {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr
        || device == kAudioObjectUnknown) return NO;
    UInt32 running = 0;
    size = sizeof(running);
    address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere;
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &running) == noErr && running != 0;
}

- (BOOL)startWithTap:(AVAudioNodeTapBlock)tap error:(NSError **)error {
    [self stop];
    @try {
        // Another app or a USB route change can invalidate a stopped engine.
        _engine = _engineFactory();
        __weak FWMicrophoneEngine *weakSelf = self;
        __weak AVAudioEngine *observedEngine = _engine;
        _configurationObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioEngineConfigurationChangeNotification object:_engine queue:nil
            usingBlock:^(NSNotification *notification) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    FWMicrophoneEngine *owner = weakSelf;
                    if (!owner || !observedEngine || owner->_engine != observedEngine) return;
                    if (owner.onConfigurationChange) owner.onConfigurationChange();
                });
            }];
        _input = _engine.inputNode;
        AVAudioFormat *format = [_input outputFormatForBus:0];
        if (!isfinite(format.sampleRate) || format.sampleRate <= 0 || format.channelCount == 0) {
            if (error) *error = [NSError errorWithDomain:@"FreeWispr.Microphone" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Microphone is unavailable. Check the input device and retry."}];
            [self stop];
            return NO;
        }
        // Let the engine choose the live format instead of forcing a cached one.
        [_input installTapOnBus:0 bufferSize:4096 format:nil block:tap];
        _tapInstalled = YES;
        [_engine prepare];
        if (![_engine startAndReturnError:error]) {
            [self stop];
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"FreeWispr.Microphone" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Microphone configuration changed. Try recording again.",
                       @"exceptionName": exception.name,
                       @"exceptionReason": exception.reason ?: @"Unknown audio engine exception"}];
        [self stop];
        return NO;
    }
}

- (void)stop {
    if (_configurationObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_configurationObserver];
        _configurationObserver = nil;
    }
    @try {
        [_engine stop];
    } @catch (NSException *exception) {
        NSLog(@"FreeWispr microphone stop failed: %@", exception);
    }
    @try {
        if (_tapInstalled) [_input removeTapOnBus:0];
    } @catch (NSException *exception) {
        NSLog(@"FreeWispr microphone tap cleanup failed: %@", exception);
    }
    _tapInstalled = NO;
    _input = nil;
    _engine = nil;
}

- (void)dealloc {
    [self stop];
}
@end
