//
//  MyUltronClient.mm
//  MyUltron
//
//  NSStream-based TCP client.  Stream events are scheduled on the main
//  run loop; write operations are safe to call from any thread.
//

#import "MyUltronClient.h"
#import "MyUltronPacketBuilder.h"

static NSString * const kMsgKeyType    = @"messageType";
static NSString * const kMsgKeyVersion = @"version";
static NSString * const kMsgKeyContent = @"content";

@interface MyUltronClient () <NSStreamDelegate>

@property (nonatomic, strong) NSInputStream  *inputStream;
@property (nonatomic, strong) NSOutputStream *outputStream;

@property (nonatomic, assign) MyUltronPacketBuilder *builder;
@property (nonatomic, strong) NSMutableData   *readBuffer;
@property (nonatomic, assign) BOOL             isConnected;

@end

@implementation MyUltronClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _builder    = new MyUltronPacketBuilder();
        _readBuffer = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
    if (_builder) {
        delete _builder;
        _builder = NULL;
    }
}

#pragma mark - Connection

- (void)connectToHost:(NSString *)host port:(uint16_t)port {
    [self disconnect];

    CFReadStreamRef  read  = NULL;
    CFWriteStreamRef write = NULL;

    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                       (__bridge CFStringRef)host,
                                       port,
                                       &read,
                                       &write);
    if (!read || !write) {
        NSLog(@"[MyUltron] Failed to create streams for %@:%u", host, port);
        return;
    }

    self.inputStream  = CFBridgingRelease(read);
    self.outputStream = CFBridgingRelease(write);

    self.inputStream.delegate  = self;
    self.outputStream.delegate = self;

    CFReadStreamSetProperty(read, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(write, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);

    [self.inputStream  scheduleInRunLoop:[NSRunLoop mainRunLoop]
                                 forMode:NSDefaultRunLoopMode];
    [self.outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop]
                                 forMode:NSDefaultRunLoopMode];

    [self.inputStream  open];
    [self.outputStream open];

    NSLog(@"[MyUltron] Connecting to %@:%u ...", host, port);
}

- (void)disconnect {
    NSInputStream  *inStream  = self.inputStream;
    NSOutputStream *outStream = self.outputStream;

    if (inStream) {
        [inStream close];
        [inStream setDelegate:nil];
        [inStream removeFromRunLoop:[NSRunLoop mainRunLoop]
                            forMode:NSDefaultRunLoopMode];
    }
    if (outStream) {
        [outStream close];
        [outStream setDelegate:nil];
        [outStream removeFromRunLoop:[NSRunLoop mainRunLoop]
                            forMode:NSDefaultRunLoopMode];
    }

    self.inputStream  = nil;
    self.outputStream = nil;

    if (self.isConnected) {
        self.isConnected = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(clientDidDisconnect:)]) {
                [self.delegate clientDidDisconnect:self];
            }
        });
    }
}

#pragma mark - Send

- (void)sendMessage:(NSDictionary *)dict {
    if (!self.isConnected) {
        NSLog(@"[MyUltron] Cannot send — not connected");
        return;
    }
    _builder->buildJsonPacket(dict);
    myultron_packet_t *pkt = _builder->getPacket();
    if (pkt == NULL) return;

    NSData *data = [NSData dataWithBytes:pkt length:pkt->header.length];
    NSInteger written = [self.outputStream write:(const uint8_t *)data.bytes
                                       maxLength:data.length];
    if (written < 0) {
        NSLog(@"[MyUltron] Write error: %@", self.outputStream.streamError);
    } else {
        NSLog(@"[MyUltron] Sent %ld bytes", (long)written);
    }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            if (aStream == self.outputStream &&
                self.inputStream.streamStatus == NSStreamStatusOpen) {
                self.isConnected = YES;
                NSLog(@"[MyUltron] Connected to server");
                if ([self.delegate respondsToSelector:@selector(clientDidConnect:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate clientDidConnect:self];
                    });
                }
            }
            break;
        }
        case NSStreamEventHasBytesAvailable:
            [self handleIncomingData];
            break;
        case NSStreamEventHasSpaceAvailable:
            break;
        case NSStreamEventErrorOccurred:
        case NSStreamEventEndEncountered: {
            NSLog(@"[MyUltron] Stream error / EOF: %@", aStream.streamError);
            [self disconnect];
            break;
        }
        default:
            break;
    }
}

#pragma mark - Read loop

- (void)handleIncomingData {
    uint8_t buf[4096];
    NSInteger n = [self.inputStream read:buf maxLength:sizeof(buf)];
    if (n <= 0) return;

    [self.readBuffer appendBytes:buf length:n];

    while (self.readBuffer.length >= MYULTRON_PACKET_LENGTH_BYTES) {
        int32_t totalLen = 0;
        [self.readBuffer getBytes:&totalLen length:sizeof(totalLen)];
        if (totalLen <= 0 || totalLen > 10 * 1024 * 1024) {
            [self.readBuffer setLength:0];
            return;
        }
        if (self.readBuffer.length < (NSUInteger)totalLen) return;

        NSData *packetData = [self.readBuffer subdataWithRange:NSMakeRange(0, totalLen)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, totalLen) withBytes:NULL length:0];

        _builder->decodePacket(packetData);
        myultron_packet_t *pkt = _builder->getPacket();
        if (pkt == NULL) continue;

        size_t payloadLen = pkt->header.length - MYULTRON_PACKET_HEADER_SIZE;
        if (payloadLen == 0) continue;

        if (pkt->header.packetType == MyUltronPacketTypeJsonMessage) {
            NSData *jsonData = [NSData dataWithBytes:pkt->payload length:payloadLen];
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
            if (![dict isKindOfClass:[NSDictionary class]]) continue;

            NSLog(@"[MyUltron] Received: type=%@", dict[kMsgKeyType]);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(client:didReceiveMessage:)]) {
                    [self.delegate client:self didReceiveMessage:dict];
                }
            });
        } else if (pkt->header.packetType == MyUltronPacketTypeBinaryMessage) {
            NSData *binaryData = [NSData dataWithBytes:pkt->payload length:payloadLen];
            NSLog(@"[MyUltron] Received binary: %lu bytes", (unsigned long)binaryData.length);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(client:didReceiveBinaryData:)]) {
                    [self.delegate client:self didReceiveBinaryData:binaryData];
                }
            });
        }
    }
}

@end
