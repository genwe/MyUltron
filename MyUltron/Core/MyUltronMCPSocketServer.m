//
//  MyUltronMCPSocketServer.m
//  MyUltron
//
//  MCP server over TCP socket (localhost only).
//  Accepts connections, reads JSON-RPC lines, dispatches to shared MCP logic.
//

#import "MyUltronMCPSocketServer.h"
#import "MyUltronMCPServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface MyUltronMCPSocketServer ()
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) NSMutableSet<NSFileHandle *> *clientHandles;
@property (nonatomic, assign) uint16_t actualPort;
@property (nonatomic, assign) BOOL running;
@end

@implementation MyUltronMCPSocketServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenSocket = -1;
        _clientHandles = [NSMutableSet set];
    }
    return self;
}

- (BOOL)isRunning { return _running; }
- (uint16_t)port { return _actualPort; }

- (BOOL)startWithPort:(uint16_t)port error:(NSString **)error {
    if (_running) return YES;

    // Clean up any leftover socket from a previous run
    if (_listenSocket >= 0) { close(_listenSocket); _listenSocket = -1; }

    // Create socket
    _listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenSocket < 0) {
        if (error) *error = @"Failed to create socket";
        return NO;
    }

    // Allow address reuse
    int opt = 1;
    setsockopt(_listenSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Bind to localhost
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);

    if (bind(_listenSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_listenSocket); _listenSocket = -1;
        if (error) *error = [NSString stringWithFormat:@"Failed to bind port %u", port];
        return NO;
    }

    // Get actual port
    socklen_t len = sizeof(addr);
    getsockname(_listenSocket, (struct sockaddr *)&addr, &len);
    _actualPort = ntohs(addr.sin_port);

    if (listen(_listenSocket, 5) < 0) {
        close(_listenSocket); _listenSocket = -1;
        if (error) *error = @"Failed to listen";
        return NO;
    }

    // Dispatch source for accepting connections
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_listenSocket, 0,
                                            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        [weakSelf acceptConnection];
    });
    dispatch_source_set_cancel_handler(_acceptSource, ^{
        int sock = weakSelf.listenSocket;
        if (sock >= 0) { close(sock); }
    });
    dispatch_resume(_acceptSource);

    _running = YES;
    NSLog(@"[MCP Socket] Server started on localhost:%u", _actualPort);
    return YES;
}

- (void)stop {
    if (!_running) return;

    NSLog(@"[MCP Socket] Stopping server...");
    _running = NO;

    // Close socket synchronously first (prevents bind error on restart)
    int sock = _listenSocket;
    _listenSocket = -1;
    if (sock >= 0) close(sock);

    // Cancel accept source (cancel handler will no-op since socket already closed)
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }

    // Close all client handles
    for (NSFileHandle *fh in [_clientHandles copy]) {
        [fh closeFile];
    }
    [_clientHandles removeAllObjects];

    NSLog(@"[MCP Socket] Server stopped");
}

- (void)acceptConnection {
    struct sockaddr_in clientAddr;
    socklen_t clientLen = sizeof(clientAddr);
    int clientFd = accept(_listenSocket, (struct sockaddr *)&clientAddr, &clientLen);

    if (clientFd < 0 || !_running) {
        if (clientFd >= 0) close(clientFd);
        return;
    }

    NSString *clientIP = @(inet_ntoa(clientAddr.sin_addr));
    NSLog(@"[MCP Socket] Client connected from %@:%u", clientIP, ntohs(clientAddr.sin_port));

    NSFileHandle *fh = [[NSFileHandle alloc] initWithFileDescriptor:clientFd closeOnDealloc:YES];
    @synchronized (_clientHandles) {
        [_clientHandles addObject:fh];
    }

    // Handle this client on a background queue
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self handleClient:fh];
    });
}

- (void)handleClient:(NSFileHandle *)fh {
    NSMutableData *buffer = [NSMutableData data];

    while (_running) {
        @autoreleasepool {
            NSData *chunk = [fh availableData];
            if (!chunk || chunk.length == 0) break;  // client disconnected

            [buffer appendData:chunk];

            // Process complete lines
            while (YES) {
                NSRange nl = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                         options:0
                                           range:NSMakeRange(0, buffer.length)];
                if (nl.location == NSNotFound) break;

                NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, nl.location)];
                [buffer replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];

                // Process the request and write response back
                [MyUltronMCPServer processRequestData:lineData outputBlock:^(NSDictionary *response) {
                    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                    if (json) {
                        NSMutableData *line = [json mutableCopy];
                        [line appendData:[NSData dataWithBytes:"\n" length:1]];
                        @try {
                            [fh writeData:line];
                        } @catch (NSException *e) {
                            // Client disconnected
                        }
                    }
                }];
            }
        }
    }

    [fh closeFile];
    @synchronized (_clientHandles) {
        [_clientHandles removeObject:fh];
    }
    NSLog(@"[MCP Socket] Client disconnected");
}

- (void)dealloc {
    [self stop];
}

@end
