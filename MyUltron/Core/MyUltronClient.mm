//
//  MyUltronClient.m
//  MyUltron
//
//  NSStream-based TCP client implementation.
//

#import "MyUltronClient.h"
#import "MyUltronPacketBuilder.h"

// Convenience keys (mirror MyUltronServer)
static NSString * const kMsgKeyType    = @"messageType";
static NSString * const kMsgKeyVersion = @"version";
static NSString * const kMsgKeyContent = @"content";

@interface MyUltronClient () <NSStreamDelegate>

@property (nonatomic, strong) NSInputStream  *inputStream;
@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, strong) dispatch_queue_t socketQueue;

@property (nonatomic, assign) MyUltronPacketBuilder builder;
@property (nonatomic, strong) NSMutableData   *readBuffer;
@property (nonatomic, assign) BOOL             isConnected;

@end

@implementation MyUltronClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _readBuffer = [NSMutableData data];
        _socketQueue = dispatch_queue_create("com.myultron.client.socket",
                                             DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_socketQueue,
                                  dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
}

#pragma mark - Connection

- (void)connectToHost:(NSString *)host port:(uint16_t)port {
    [self disconnect];

    dispatch_async(self.socketQueue, ^{
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

        CFReadStreamSetProperty(read,
                                kCFStreamPropertyShouldCloseNativeSocket,
                                kCFBooleanTrue);
        CFWriteStreamSetProperty(write,
                                 kCFStreamPropertyShouldCloseNativeSocket,
                                 kCFBooleanTrue);

        // Use dispatch queue for callbacks — no run loop needed
        CFReadStreamSetDispatchQueue(read, self.socketQueue);
        CFWriteStreamSetDispatchQueue(write, self.socketQueue);

        [self.inputStream  open];
        [self.outputStream open];

        NSLog(@"[MyUltron] Connecting to %@:%u ...", host, port);
    });
}

- (void)disconnect {
    dispatch_sync(self.socketQueue, ^{
        // Unset dispatch queues before close to stop callbacks
        CFReadStreamSetDispatchQueue((__bridge CFReadStreamRef)self.inputStream, NULL);
        CFWriteStreamSetDispatchQueue((__bridge CFWriteStreamRef)self.outputStream, NULL);

        [self.inputStream  close];
        [self.outputStream close];

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
    });
}

#pragma mark - Send

- (void)sendMessage:(NSDictionary *)dict {
    dispatch_async(self.socketQueue, ^{
        if (!self.isConnected) {
            NSLog(@"[MyUltron] Cannot send — not connected");
            return;
        }
        self.builder.buildJsonPacket(dict);
        myultron_packet_t *pkt = self.builder.getPacket();
        if (pkt == NULL) return;

        NSData *data = [NSData dataWithBytes:pkt length:pkt->header.length];
        [self.outputStream write:(const uint8_t *)data.bytes maxLength:data.length];
    });
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
        case NSStreamEventHasBytesAvailable: {
            [self handleIncomingData];
            break;
        }
        case NSStreamEventHasSpaceAvailable:
            // Write buffer has room — we don't queue, so nothing to do.
            break;
        case NSStreamEventErrorOccurred:
        case NSStreamEventEndEncountered: {
            NSLog(@"[MyUltron] Stream error / EOF: %@", aStream.streamError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self disconnect];
            });
            break;
        }
        default:
            break;
    }
}

#pragma mark - Read loop

- (void)handleIncomingData {
    // Read whatever is available into the buffer
    uint8_t buf[4096];
    NSInteger n = [self.inputStream read:buf maxLength:sizeof(buf)];
    if (n <= 0) return;

    [self.readBuffer appendBytes:buf length:n];

    // Try to parse as many packets as possible from the buffer
    while (self.readBuffer.length >= MYULTRON_PACKET_LENGTH_BYTES) {
        // Peek the 4-byte length prefix without consuming
        int32_t totalLen = 0;
        [self.readBuffer getBytes:&totalLen length:sizeof(totalLen)];
        if (totalLen <= 0 || totalLen > 10 * 1024 * 1024) {
            // Corrupt — flush
            NSLog(@"[MyUltron] Corrupt packet length: %d", totalLen);
            [self.readBuffer setLength:0];
            return;
        }

        if (self.readBuffer.length < (NSUInteger)totalLen) {
            // Not enough data yet — wait for more
            return;
        }

        // Extract the complete packet
        NSData *packetData = [self.readBuffer subdataWithRange:NSMakeRange(0, totalLen)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, totalLen)
                                   withBytes:NULL
                                      length:0];

        // Decode
        self.builder.decodePacket(packetData);
        myultron_packet_t *pkt = self.builder.getPacket();
        if (pkt == NULL || pkt->header.packetType != MyUltronPacketTypeJsonMessage) {
            // Non-JSON packet (e.g. Pong) — ignore at this level
            continue;
        }

        size_t payloadLen = pkt->header.length - MYULTRON_PACKET_HEADER_SIZE;
        if (payloadLen == 0) continue;

        NSData *jsonData = [NSData dataWithBytes:pkt->payload length:payloadLen];
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                             options:0
                                                               error:&err];
        if (err || ![dict isKindOfClass:[NSDictionary class]]) continue;

        NSLog(@"[MyUltron] Received: type=%@", dict[kMsgKeyType]);

        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.delegate respondsToSelector:@selector(client:didReceiveMessage:)]) {
                [self.delegate client:self didReceiveMessage:dict];
            }
        });
    }
}

@end
