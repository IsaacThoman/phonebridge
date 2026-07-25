#import "PhoneBridgeWebRTCShim.h"
#import <dlfcn.h>
#import <objc/message.h>

static const double PBSampleRate = 48000.0;
static const NSInteger PBChannelCount = 2;
static const UInt32 PBFramesPerTick = 480;
static const NSTimeInterval PBTickDuration = 0.01;
static const NSTimeInterval PBMaximumRecordedBufferDuration = 0.2;

void PBResolveFaceTimeAudioAvailability(
    NSString *destination,
    NSTimeInterval timeout,
    PBFaceTimeAvailabilityHandler completion) {
  static void *idsHandle;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    idsHandle = dlopen(
      "/System/Library/PrivateFrameworks/IDS.framework/IDS",
      RTLD_NOW | RTLD_LOCAL
    );
  });

  dispatch_queue_t queue =
    dispatch_queue_create("phonebridge.ids.facetime-availability", DISPATCH_QUEUE_SERIAL);
  if (idsHandle == NULL) {
    dispatch_async(queue, ^{ completion(0); });
    return;
  }

  Class queryClass = NSClassFromString(@"IDSIDQueryController");
  SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
  SEL querySelector = NSSelectorFromString(
    @"requestIDStatusForDestination:service:listenerID:queue:completionBlock:"
  );
  if (queryClass == Nil || ![queryClass respondsToSelector:sharedSelector]) {
    dispatch_async(queue, ^{ completion(0); });
    return;
  }

  id controller = ((id (*)(id, SEL))objc_msgSend)(queryClass, sharedSelector);
  if (controller == nil || ![controller respondsToSelector:querySelector]) {
    dispatch_async(queue, ^{ completion(0); });
    return;
  }

  __block BOOL finished = NO;
  void (^finish)(NSInteger) = ^(NSInteger status) {
    dispatch_async(queue, ^{
      if (finished) return;
      finished = YES;
      completion(status);
    });
  };
  void (^statusHandler)(NSInteger) = ^(NSInteger status) {
    finish(status);
  };

  BOOL accepted = ((BOOL (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
    controller,
    querySelector,
    destination,
    @"com.apple.private.alloy.facetime.audio",
    @"com.isaacthoman.phonebridge",
    queue,
    statusHandler
  );
  if (!accepted) {
    finish(0);
    return;
  }

  dispatch_after(
    dispatch_time(
      DISPATCH_TIME_NOW,
      (int64_t)(MAX(timeout, 0.1) * (double)NSEC_PER_SEC)
    ),
    queue,
    ^{ finish(0); }
  );
}

@interface PBRTCAudioDevice ()
@property(nonatomic, strong, nullable) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t recordingQueue;
@property(nonatomic, strong) dispatch_queue_t playoutQueue;
@property(nonatomic, strong, nullable) dispatch_source_t recordingTimer;
@property(nonatomic, strong, nullable) dispatch_source_t playoutTimer;
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
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _recordingQueue =
        dispatch_queue_create("phonebridge.webrtc.recording", attributes);
    _playoutQueue =
        dispatch_queue_create("phonebridge.webrtc.playout", attributes);
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
  dispatch_sync(_recordingQueue, ^{
    [self stopRecordingTimer];
    self.recording = NO;
    self.recordingInitialized = NO;
    [self.recordedPCM setLength:0];
  });
  dispatch_sync(_playoutQueue, ^{
    [self stopPlayoutTimer];
    self.playing = NO;
    self.playoutInitialized = NO;
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
  dispatch_async(_playoutQueue, ^{
    self.playing = YES;
    [self ensurePlayoutTimer];
  });
  return YES;
}

- (BOOL)stopPlayout {
  dispatch_async(_playoutQueue, ^{
    self.playing = NO;
    [self stopPlayoutTimer];
  });
  return YES;
}

- (BOOL)initializeRecording {
  _recordingInitialized = YES;
  return YES;
}

- (BOOL)startRecording {
  dispatch_async(_recordingQueue, ^{
    self.recording = YES;
    [self ensureRecordingTimer];
  });
  return YES;
}

- (BOOL)stopRecording {
  dispatch_async(_recordingQueue, ^{
    self.recording = NO;
    [self stopRecordingTimer];
  });
  return YES;
}

- (void)enqueueRecordedPCM16:(NSData *)pcm16 {
  if (pcm16.length == 0) return;
  dispatch_async(_recordingQueue, ^{
    [self.recordedPCM appendData:pcm16];
    NSUInteger maximumBytes = (NSUInteger)(
        PBSampleRate * PBChannelCount * sizeof(int16_t) * PBMaximumRecordedBufferDuration);
    if (self.recordedPCM.length > maximumBytes) {
      NSUInteger excess = self.recordedPCM.length - maximumBytes;
      excess -= excess % (PBChannelCount * sizeof(int16_t));
      [self.recordedPCM replaceBytesInRange:NSMakeRange(0, excess) withBytes:NULL length:0];
    }
  });
}

- (void)ensureRecordingTimer {
  if (_recordingTimer != nil) return;
  _recordingTimer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _recordingQueue);
  uint64_t interval = (uint64_t)(PBTickDuration * NSEC_PER_SEC);
  dispatch_source_set_timer(
      _recordingTimer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, 0);
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_recordingTimer, ^{
    [weakSelf processRecordingTick];
  });
  dispatch_resume(_recordingTimer);
}

- (void)ensurePlayoutTimer {
  if (_playoutTimer != nil) return;
  _playoutTimer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _playoutQueue);
  uint64_t interval = (uint64_t)(PBTickDuration * NSEC_PER_SEC);
  dispatch_source_set_timer(
      _playoutTimer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, 0);
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_playoutTimer, ^{
    [weakSelf processPlayoutTick];
  });
  dispatch_resume(_playoutTimer);
}

- (void)stopRecordingTimer {
  if (_recordingTimer == nil) return;
  dispatch_source_cancel(_recordingTimer);
  _recordingTimer = nil;
}

- (void)stopPlayoutTimer {
  if (_playoutTimer == nil) return;
  dispatch_source_cancel(_playoutTimer);
  _playoutTimer = nil;
}

- (void)processRecordingTick {
  const NSUInteger byteCount = PBFramesPerTick * PBChannelCount * sizeof(int16_t);
  if (_recording && _delegate != nil) {
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    NSUInteger available = MIN(byteCount, _recordedPCM.length);
    if (available > 0) {
      [_recordedPCM getBytes:data.mutableBytes length:available];
      [_recordedPCM replaceBytesInRange:NSMakeRange(0, available) withBytes:NULL length:0];
    }
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp timestamp = {0};
    _delegate.deliverRecordedData(
        &flags,
        &timestamp,
        0,
        PBFramesPerTick,
        NULL,
        NULL,
        ^OSStatus(
            AudioUnitRenderActionFlags *renderFlags,
            const AudioTimeStamp *renderTimestamp,
            NSInteger inputBusNumber,
            UInt32 frameCount,
            AudioBufferList *inputData,
            void *renderContext) {
          if (inputData == NULL || inputData->mNumberBuffers != 1) return -1;
          AudioBuffer *buffer = &inputData->mBuffers[0];
          NSUInteger requestedBytes =
              frameCount * PBChannelCount * sizeof(int16_t);
          if (buffer->mData == NULL || buffer->mDataByteSize < requestedBytes) {
            return -1;
          }
          memcpy(buffer->mData, data.bytes, MIN(requestedBytes, data.length));
          if (data.length < requestedBytes) {
            memset(
                (uint8_t *)buffer->mData + data.length,
                0,
                requestedBytes - data.length);
          }
          buffer->mNumberChannels = PBChannelCount;
          buffer->mDataByteSize = (UInt32)requestedBytes;
          return noErr;
        });
  }
}

- (void)processPlayoutTick {
  const NSUInteger byteCount = PBFramesPerTick * PBChannelCount * sizeof(int16_t);
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
