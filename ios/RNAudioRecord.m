#import "RNAudioRecord.h"

@implementation RNAudioRecord

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(init:(NSDictionary *) options) {
    RCTLogInfo(@"[RNARINIT] Inicializando configurações de gravação");
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


}

RCT_EXPORT_METHOD(start:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    RCTLogInfo(@"[RNARSTART] Iniciando gravação");

    // most audio players set session category to "Playback", record won't work in this mode
    // therefore set session category to "Record" before recording
    if (_recordState.mIsRunning) {
        RCTLogInfo(@"[RNARSTART] Gravação já em andamento, ignorando novo start.");
        reject(@"[RNARSTART]",@" Gravação já em andamento, ignorando novo start.",nil);
        return;
    }
    // Finaliza qualquer gravação antiga mal encerrada
    if (_recordState.mQueue != NULL) {
        AudioQueueDispose(_recordState.mQueue, true);
        _recordState.mQueue = NULL;
        RCTLogInfo(@"[RNARSTART] Fila antiga descartada");
    }

    if (_recordState.mAudioFile != NULL) {
        AudioFileClose(_recordState.mAudioFile);
        _recordState.mAudioFile = NULL;
        RCTLogInfo(@"[RNARSTART] Arquivo antigo fechado ");
    }

    // Configura sessão de áudio
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:&sessionError];
    if (sessionError != nil) {
        NSLog(@"[RNARSTART] Erro ao configurar categoria de áudio: %@", sessionError);
        reject(@"[RNARSTART]",@" Erro ao configurar categoria de áudio:", sessionError);
        return;
    }else{
        NSLog(@"[RNARSTART] Categoria de audio configurada com sucesso: %@", session);
    }
    [session setActive:YES error:&sessionError];
    if (sessionError != nil) {
        NSLog(@"[RNARSTART] Erro ao configurar sessão de áudio: %@", sessionError);
        reject(@"[RNARSTART]",@" Erro ao configurar sessão de áudio", sessionError);
        return;
    }else{
        NSLog(@"[RNARSTART] Sessão de audio configurada com sucesso: %@", session);
    }
    _recordState.mIsRunning = true;
    _recordState.mCurrentPacket = 0;

    // Gera nome de arquivo único
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *fileName = [NSString stringWithFormat:@"audio-%@.wav", uuid];
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    _filePath = [docDir stringByAppendingPathComponent:fileName];
    
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
    OSStatus audioFileStatus = AudioFileCreateWithURL(url, kAudioFileWAVEType, &_recordState.mDataFormat, kAudioFileFlags_EraseFile, &_recordState.mAudioFile);
    CFRelease(url);
    if (audioFileStatus != noErr) {
        NSLog(@"[RNARSTART] Erro ao criar arquivo de áudio: %d", (int)audioFileStatus);
        reject(@"[RNARSTART]",@" Erro ao criar arquivo de áudio:",nil);
        return;
    }else{
        NSLog(@"[RNARSTART] Arquivo de auido criado com sucesso: %d", (int)audioFileStatus);
    }
    OSStatus queueStatus = AudioQueueNewInput(&_recordState.mDataFormat, HandleInputBuffer, &_recordState, NULL, NULL, 0, &_recordState.mQueue);
    if (queueStatus != noErr) {
        NSLog(@"[RNARSTART] Erro ao criar fila de gravação: %d", (int)queueStatus);
        reject(@"[RNARSTART]",@" Erro ao criar fila de gravação:", nil);
        return;
    }else{
        NSLog(@"[RNARSTART] Fila de áuido criada com sucesso: %d", (int)queueStatus);
    }
    for (int i = 0; i < kNumberBuffers; i++) {
        OSStatus allocateBufferStatus = AudioQueueAllocateBuffer(_recordState.mQueue, _recordState.bufferByteSize, &_recordState.mBuffers[i]);
        if (allocateBufferStatus != noErr) {
            NSLog(@"[RNARSTART] Erro ao alocar o buffer %d", (int)allocateBufferStatus);
            reject(@"[RNARSTART]",@" Erro ao alocar o buffer",nil);
            return;
        }
        allocateBufferStatus = AudioQueueEnqueueBuffer(_recordState.mQueue, _recordState.mBuffers[i], 0, NULL);
        if (allocateBufferStatus != noErr) {
            NSLog(@"[RNARSTART] Erro ao enfileirar o buffer %d", (int)allocateBufferStatus);
            reject(@"[RNARSTART]",@" Erro ao enfileirar o buffer",nil);
            return;
        }
    }
    OSStatus audioQueueStartStatus = AudioQueueStart(_recordState.mQueue, NULL);
    if (audioQueueStartStatus != noErr) {
        NSLog(@"[RNARSTART] Erro ao iniciar gravação: %d", (int)audioQueueStartStatus);
        reject(@"[RNARSTART]",@" Erro ao iniciar gravação:",nil);
        return;
    }else{
        NSLog(@"[RNARSTART] Gravação iniciada com sucesso.: %d", (int)audioQueueStartStatus);
    }
    resolve(@"[RNARSTART] Gravação iniciada com sucesso.");
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject) {
    RCTLogInfo(@"[RNARSTOP] Finalizando gravação");
    if (!_recordState.mIsRunning) {
        RCTLogInfo(@"[RNARSTOP] Nenhuma gravação ativa.");
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
    
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setActive:NO error:&sessionError];
    if (sessionError != nil) {
        NSLog(@"[RNARSTOP] Erro ao desativar sessão de áudio: %@", sessionError);
    } else {
        NSLog(@"[RNARSTOP] Sessão de áudio desativada com sucesso");
    }
    _recordState.mQueue = NULL;
    _recordState.mAudioFile = NULL;
    _recordState.mIsRunning = false;
    _recordState.mCurrentPacket = 0;
    unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
    RCTLogInfo(@"[RNARSTOP] Gravação encerrada: %@", _filePath);
    RCTLogInfo(@"[RNARSTOP] Tamanho do arquivo: %llu bytes", fileSize);
    resolve(_filePath);    
}

void HandleInputBuffer(void *inUserData,
                       AudioQueueRef inAQ,
                       AudioQueueBufferRef inBuffer,
                       const AudioTimeStamp *inStartTime,
                       UInt32 inNumPackets,
                       const AudioStreamPacketDescription *inPacketDesc) {
    AQRecordState* pRecordState = (AQRecordState *)inUserData;
    
    if (!pRecordState->mIsRunning) {
        RCTLogInfo(@"[HandleInputBuffer] RETURN NOT RUNNING:");
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
