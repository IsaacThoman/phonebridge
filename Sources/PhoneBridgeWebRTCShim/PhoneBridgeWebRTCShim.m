#import "PhoneBridgeWebRTCShim.h"

static const double PBSampleRate = 48000.0;
static const NSInteger PBChannelCount = 2;
static const UInt32 PBFramesPerTick = 480;
static const NSTimeInterval PBTickDuration = 0.01;

@interface PBRTCAudioDevice ()
@property(nonatomic, strong, nullable) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t audioQueue;
@property(nonatomic, strong, nullable) dispatch_source_t timer;
@property(nonatomic, strong) NSMutableData *recordedPCM;
@property(nonatomic) BOOL initialized;
@property(nonatomic) BOOL playoutInitialized;
@property(nonatomic) BOOL playing;
@property(nonatomic) BOOL recordingInitialized;
@property(nonatomic) BOOL recording;
@end

@implementation PBRTCAudioDevice

- (instancetype)init {
  self = [super init];
  if (self) {
    _audioQueue = dispatch_queue_create("phonebridge.webrtc.audio", DISPATCH_QUEUE_SERIAL);
    _recordedPCM = [NSMutableData data];
  }
  return self;
}

- (double)deviceInputSampleRate { return PBSampleRate; }
- (NSTimeInterval)inputIOBufferDuration { return PBTickDuration; }
- (NSInteger)inputNumberOfChannels { return PBChannelCount; }
- (NSTimeInterval)inputLatency { return PBTickDuration; }
- (double)deviceOutputSampleRate { return PBSampleRate; }
- (NSTimeInterval)outputIOBufferDuration { return PBTickDuration; }
- (NSInteger)outputNumberOfChannels { return PBChannelCount; }
- (NSTimeInterval)outputLatency { return PBTickDuration; }
- (BOOL)isInitialized { return _initialized; }
- (BOOL)isPlayoutInitialized { return _playoutInitialized; }
- (BOOL)isPlaying { return _playing; }
- (BOOL)isRecordingInitialized { return _recordingInitialized; }
- (BOOL)isRecording { return _recording; }

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
  _delegate = delegate;
  _initialized = YES;
  return YES;
}

- (BOOL)terminateDevice {
  dispatch_sync(_audioQueue, ^{
    [self stopTimerIfIdleForced:YES];
    self.recording = NO;
    self.playing = NO;
    self.recordingInitialized = NO;
    self.playoutInitialized = NO;
    [self.recordedPCM setLength:0];
  });
  _delegate = nil;
  _initialized = NO;
  return YES;
}

- (BOOL)initializePlayout {
  _playoutInitialized = YES;
  return YES;
}

- (BOOL)startPlayout {
  dispatch_async(_audioQueue, ^{
    self.playing = YES;
    [self ensureTimer];
  });
  return YES;
}

- (BOOL)stopPlayout {
  dispatch_async(_audioQueue, ^{
    self.playing = NO;
    [self stopTimerIfIdleForced:NO];
  });
  return YES;
}

- (BOOL)initializeRecording {
  _recordingInitialized = YES;
  return YES;
}

- (BOOL)startRecording {
  dispatch_async(_audioQueue, ^{
    self.recording = YES;
    [self ensureTimer];
  });
  return YES;
}

- (BOOL)stopRecording {
  dispatch_async(_audioQueue, ^{
    self.recording = NO;
    [self stopTimerIfIdleForced:NO];
  });
  return YES;
}

- (void)enqueueRecordedPCM16:(NSData *)pcm16 {
  if (pcm16.length == 0) return;
  dispatch_async(_audioQueue, ^{
    [self.recordedPCM appendData:pcm16];
    NSUInteger maximumBytes = (NSUInteger)(PBSampleRate * PBChannelCount * sizeof(int16_t) * 2);
    if (self.recordedPCM.length > maximumBytes) {
      NSUInteger excess = self.recordedPCM.length - maximumBytes;
      [self.recordedPCM replaceBytesInRange:NSMakeRange(0, excess) withBytes:NULL length:0];
    }
  });
}

- (void)ensureTimer {
  if (_timer != nil) return;
  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _audioQueue);
  uint64_t interval = (uint64_t)(PBTickDuration * NSEC_PER_SEC);
  dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_timer, ^{
    [weakSelf processAudioTick];
  });
  dispatch_resume(_timer);
}

- (void)stopTimerIfIdleForced:(BOOL)forced {
  if (_timer == nil || (!forced && (_playing || _recording))) return;
  dispatch_source_cancel(_timer);
  _timer = nil;
}

- (void)processAudioTick {
  const NSUInteger byteCount = PBFramesPerTick * PBChannelCount * sizeof(int16_t);
  if (_recording && _delegate != nil) {
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    NSUInteger available = MIN(byteCount, _recordedPCM.length);
    if (available > 0) {
      [_recordedPCM getBytes:data.mutableBytes length:available];
      [_recordedPCM replaceBytesInRange:NSMakeRange(0, available) withBytes:NULL length:0];
    }
    AudioBufferList input = {0};
    input.mNumberBuffers = 1;
    input.mBuffers[0].mNumberChannels = PBChannelCount;
    input.mBuffers[0].mDataByteSize = (UInt32)byteCount;
    input.mBuffers[0].mData = data.mutableBytes;
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};
    _delegate.deliverRecordedData(
        &flags, &timestamp, 0, PBFramesPerTick, &input, NULL, nil);
  }

  if (_playing && _delegate != nil) {
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    AudioBufferList output = {0};
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = PBChannelCount;
    output.mBuffers[0].mDataByteSize = (UInt32)byteCount;
    output.mBuffers[0].mData = data.mutableBytes;
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};
    OSStatus status =
        _delegate.getPlayoutData(&flags, &timestamp, 0, PBFramesPerTick, &output);
    if (status == noErr && _playoutHandler != nil) {
      _playoutHandler(data, PBSampleRate, PBChannelCount, PBFramesPerTick);
    }
  }
}

@end

RTCPeerConnectionFactory *
PBRTCCreatePeerConnectionFactory(PBRTCAudioDevice *audioDevice) {
  return [[RTCPeerConnectionFactory alloc]
      initWithEncoderFactory:nil
             decoderFactory:nil
                audioDevice:audioDevice];
}
