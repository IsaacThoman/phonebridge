#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <WebRTC/RTCPeerConnectionFactory.h>

NS_ASSUME_NONNULL_BEGIN

typedef OSStatus (^PBRTCGetPlayoutDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *outputData);

typedef OSStatus (^PBRTCRenderRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *inputData,
    void *_Nullable renderContext);

typedef OSStatus (^PBRTCDeliverRecordedDataBlock)(
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    const AudioBufferList *_Nullable inputData,
    void *_Nullable renderContext,
    PBRTCRenderRecordedDataBlock _Nullable renderBlock);

@protocol RTCAudioDeviceDelegate <NSObject>
@property(readonly, nonnull) PBRTCDeliverRecordedDataBlock deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) PBRTCGetPlayoutDataBlock getPlayoutData;
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

@protocol RTCAudioDevice <NSObject>
@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;
@property(readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate;
- (BOOL)terminateDevice;
@property(readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property(readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@property(readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property(readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
@end

typedef void (^PBRTCPlayoutHandler)(
    NSData *pcm16,
    double sampleRate,
    NSInteger channelCount,
    UInt32 frameCount);

@interface PBRTCAudioDevice : NSObject <RTCAudioDevice>
@property(nonatomic, copy, nullable) PBRTCPlayoutHandler playoutHandler;
- (void)enqueueRecordedPCM16:(NSData *)pcm16;
@end

FOUNDATION_EXPORT RTCPeerConnectionFactory *
PBRTCCreatePeerConnectionFactory(PBRTCAudioDevice *audioDevice);

NS_ASSUME_NONNULL_END
