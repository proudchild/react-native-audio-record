#import "RNAudioRecord.h"

@implementation RNAudioRecord

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(init:(NSDictionary *) options) {
    RCTLogInfo(@"[INIT] Inicializando configurações de gravação");

    _recordState.mDataFormat.mSampleRate        = options[@"sampleRate"] == nil ? 44100 : [options[@"sampleRate"] doubleValue];
    _recordState.mDataFormat.mBitsPerChannel    = options[@"bitsPerSample"] == nil ? 16 : [options[@"bitsPerSample"] unsignedIntValue];
    _recordState.mDataFormat.mChannelsPerFrame  = options[@"channels"] == nil ? 1 : [options[@"channels"] unsignedIntValue];
    _recordState.mDataFormat.mBytesPerPacket    = (_recordState.mDataFormat.mBitsPerChannel / 8) * _recordState.mDataFormat.mChannelsPerFrame;
    _recordState.mDataFormat.mBytesPerFrame     = _recordState.mDataFormat.mBytesPerPacket;
    _recordState.mDataFormat.mFramesPerPacket   = 1;
    _recordState.mDataFormat.mReserved          = 0;
    _recordState.mDataFormat.mFormatID          = kAudioFormatLinearPCM;
    _recordState.mDataFormat.mFormatFlags       = _recordState.mDataFormat.mBitsPerChannel == 8 ? kLinearPCMFormatFlagIsPacked : (kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked);

    _recordState.bufferByteSize = 2048;
    _recordState.mSelf = self;

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *fileName = [NSString stringWithFormat:@"audio-%@.wav", uuid];
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    _filePath = [docDir stringByAppendingPathComponent:fileName];

    RCTLogInfo(@"[INIT] Arquivo será salvo em %@", _filePath);
}

RCT_EXPORT_METHOD(start) {
    RCTLogInfo(@"[START] Iniciando gravação");

    if (_recordState.mIsRunning) {
        RCTLogInfo(@"[START] Gravação já em andamento, ignorando novo start.");
        return;
    }

    if (_recordState.mQueue != NULL) {
        AudioQueueDispose(_recordState.mQueue, true);
        _recordState.mQueue = NULL;
        RCTLogInfo(@"[START] Fila antiga descartada");
    }

    if (_recordState.mAudioFile != NULL) {
        AudioFileClose(_recordState.mAudioFile);
        _recordState.mAudioFile = NULL;
        RCTLogInfo(@"[START] Arquivo antigo fechado");
    }

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:&sessionError];
    [session setActive:YES error:&sessionError];
    if (sessionError != nil) {
        NSLog(@"[START] Erro ao configurar sessão de áudio: %@", sessionError);
    }

    _recordState.mIsRunning = true;
    _recordState.mCurrentPacket = 0;

    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
    OSStatus audioFileStatus = AudioFileCreateWithURL(url, kAudioFileWAVEType, &_recordState.mDataFormat, kAudioFileFlags_EraseFile, &_recordState.mAudioFile);
    CFRelease(url);

    if (audioFileStatus != noErr) {
        NSLog(@"[START] Erro ao criar arquivo de áudio: %d", (int)audioFileStatus);
        return;
    }

    OSStatus queueStatus = AudioQueueNewInput(&_recordState.mDataFormat, HandleInputBuffer, &_recordState, NULL, NULL, 0, &_recordState.mQueue);
    if (queueStatus != noErr) {
        NSLog(@"[START] Erro ao criar fila de gravação: %d", (int)queueStatus);
        return;
    }

    for (int i = 0; i < kNumberBuffers; i++) {
        AudioQueueAllocateBuffer(_recordState.mQueue, _recordState.bufferByteSize, &_recordState.mBuffers[i]);
        AudioQueueEnqueueBuffer(_recordState.mQueue, _recordState.mBuffers[i], 0, NULL);
    }

    AudioQueueStart(_recordState.mQueue, NULL);

    RCTLogInfo(@"[START] Gravação iniciada com sucesso.");
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    RCTLogInfo(@"[STOP] Finalizando gravação");

    if (!_recordState.mIsRunning) {
        RCTLogInfo(@"[STOP] Nenhuma gravação ativa.");
        resolve(_filePath ?: @"");
        return;
    }

    _recordState.mIsRunning = false;

    if (_recordState.mQueue != NULL) {
        AudioQueueStop(_recordState.mQueue, true);
        AudioQueueDispose(_recordState.mQueue, true);
        _recordState.mQueue = NULL;
    }

    if (_recordState.mAudioFile != NULL) {
        AudioFileClose(_recordState.mAudioFile);
        _recordState.mAudioFile = NULL;
    }

    RCTLogInfo(@"[STOP] Gravação encerrada: %@", _filePath);
    unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
    RCTLogInfo(@"[STOP] Tamanho do arquivo: %llu bytes", fileSize);

    resolve(_filePath);

    memset(&_recordState, 0, sizeof(_recordState));
    _recordState.mSelf = self;
}

void HandleInputBuffer(void *inUserData,
                       AudioQueueRef inAQ,
                       AudioQueueBufferRef inBuffer,
                       const AudioTimeStamp *inStartTime,
                       UInt32 inNumPackets,
                       const AudioStreamPacketDescription *inPacketDesc) {
    AQRecordState* pRecordState = (AQRecordState *)inUserData;

    if (!pRecordState->mIsRunning) {
        return;
    }

    if (AudioFileWritePackets(pRecordState->mAudioFile,
                              false,
                              inBuffer->mAudioDataByteSize,
                              inPacketDesc,
                              pRecordState->mCurrentPacket,
                              &inNumPackets,
                              inBuffer->mAudioData
                              ) == noErr) {
        pRecordState->mCurrentPacket += inNumPackets;
    }

    short *samples = (short *) inBuffer->mAudioData;
    long nsamples = inBuffer->mAudioDataByteSize;
    NSData *data = [NSData dataWithBytes:samples length:nsamples];
    NSString *str = [data base64EncodedStringWithOptions:0];
    [pRecordState->mSelf sendEventWithName:@"data" body:str];

    AudioQueueEnqueueBuffer(pRecordState->mQueue, inBuffer, 0, NULL);
}

- (NSArray<NSString *> *)supportedEvents {
    return @[@"data"];
}

- (void)dealloc {
    RCTLogInfo(@"[DEALLOC] Limpando fila de áudio");
    if (_recordState.mQueue != NULL) {
        AudioQueueDispose(_recordState.mQueue, true);
        _recordState.mQueue = NULL;
    }
    if (_recordState.mAudioFile != NULL) {
        AudioFileClose(_recordState.mAudioFile);
        _recordState.mAudioFile = NULL;
    }
}

@end