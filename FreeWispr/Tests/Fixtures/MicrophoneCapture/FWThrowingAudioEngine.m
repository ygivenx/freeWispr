#import "FWThrowingAudioEngine.h"

@implementation FWThrowingAudioEngine
- (AVAudioInputNode *)inputNode {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
        reason:@"Simulated microphone configuration change" userInfo:nil];
}
@end
