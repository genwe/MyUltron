//
//  MyUltronMCPBridge.m
//  MyUltron
//

#import "MyUltronMCPBridge.h"
#import "MyUltronClient.h"

static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

@interface MyUltronMCPBridge () <MyUltronClientDelegate>
@property (nonatomic, strong) MyUltronClient *client;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MCPBridgeCompletion> *pendingRequests;
@property (nonatomic, assign) NSUInteger requestCounter;
@end

@implementation MyUltronMCPBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _client = [[MyUltronClient alloc] init];
        _client.delegate = self;
        _pendingRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isConnected {
    return self.client.isConnected;
}

#pragma mark - Connection

- (BOOL)connectToDevice:(NSString *)udid
              bundleID:(NSString *)bundleID
             simulator:(BOOL)isSimulator
                 error:(NSString **)error
{
    // Launch the app first
    if (bundleID.length > 0) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        if (isSimulator) {
            task.arguments = @[@"simctl", @"launch", udid, bundleID];
        } else {
            task.arguments = @[@"devicectl", @"device", @"process", @"launch", @"--device", udid, bundleID];
        }
        task.standardOutput = [NSPipe pipe];
        task.standardError = [NSPipe pipe];
        [task launchAndReturnError:nil];
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            if (error) *error = [NSString stringWithFormat:@"Failed to launch app (exit %d)", task.terminationStatus];
            return NO;
        }
        // Wait for the app to start
        [NSThread sleepForTimeInterval:2.0];
    }

    // Connect TCP
    if (isSimulator) {
        [self.client connectToHost:@"127.0.0.1" fromPort:62345 toPort:62445];
    } else {
        [self.client connectToDeviceUDID:udid fromPort:62345 toPort:62445];
    }

    // Wait for connection (poll with timeout)
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (!self.client.isConnected && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    if (!self.client.isConnected) {
        if (error) *error = @"TCP connection timed out. Make sure the iOS app is running MyUltronServer.";
        return NO;
    }

    return YES;
}

- (void)disconnect {
    [self.client disconnect];
    [self.pendingRequests removeAllObjects];
}

#pragma mark - Request/Response

- (void)sendRequest:(NSString *)messageType
            content:(NSDictionary *)content
            timeout:(NSTimeInterval)timeout
      expectBinary:(BOOL)expectBinary
        completion:(MCPBridgeCompletion)completion
{
    if (!self.client.isConnected) {
        completion(nil, nil, @"Not connected to device");
        return;
    }

    NSString *reqId = [NSString stringWithFormat:@"mcp_%lu", (unsigned long)++self.requestCounter];
    self.pendingRequests[reqId] = completion;

    NSDictionary *msg = @{
        kMsgVersion: @"1.0",
        kMsgType: messageType,
        kMsgContent: ([content mutableCopy] ?: @{}),
    };

    [self.client sendMessage:msg];

    // Timeout
    if (timeout > 0 && !expectBinary) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MCPBridgeCompletion cb = self.pendingRequests[reqId];
            if (cb) {
                [self.pendingRequests removeObjectForKey:reqId];
                cb(nil, nil, @"Request timed out");
            }
        });
    }
}

#pragma mark - MyUltronClientDelegate

- (void)clientDidConnect:(MyUltronClient *)client {
    // Handled by connectToDevice polling
}

- (void)clientDidDisconnect:(MyUltronClient *)client {
    // Fail all pending requests
    for (NSString *key in self.pendingRequests.allKeys) {
        MCPBridgeCompletion cb = self.pendingRequests[key];
        if (cb) cb(nil, nil, @"Device disconnected");
    }
    [self.pendingRequests removeAllObjects];
}

- (void)client:(MyUltronClient *)client didReceiveMessage:(NSDictionary *)dict {
    // Match any pending request by messageType
    NSString *msgType = dict[kMsgType];
    if (!msgType) return;

    // Find first matching pending request
    for (NSString *key in self.pendingRequests.allKeys) {
        MCPBridgeCompletion cb = self.pendingRequests[key];
        if (cb) {
            [self.pendingRequests removeObjectForKey:key];
            NSDictionary *content = [dict[kMsgContent] isKindOfClass:[NSDictionary class]] ? dict[kMsgContent] : nil;
            cb(content, nil, nil);
            return;
        }
    }
}

- (void)client:(MyUltronClient *)client didReceiveBinaryData:(NSData *)data {
    // Binary data goes to the first pending request expecting it
    for (NSString *key in self.pendingRequests.allKeys) {
        MCPBridgeCompletion cb = self.pendingRequests[key];
        if (cb) {
            [self.pendingRequests removeObjectForKey:key];
            cb(@{@"success": @YES}, data, nil);
            return;
        }
    }
}

@end
