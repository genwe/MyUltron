//
//  MyUltronMCPSocketServer.h
//  MyUltron
//
//  MCP server over TCP socket (localhost).
//  Accepts connections on a local port, each connection gets
//  JSON-RPC 2.0 line protocol, identical to the stdio transport.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MyUltronMCPSocketServer : NSObject

/// Start the TCP server on localhost.
/// Returns YES and sets the port on success.
- (BOOL)startWithPort:(uint16_t)port error:(NSString **)error;

/// Stop the server and disconnect all clients.
- (void)stop;

/// Whether the server is currently running.
@property (nonatomic, readonly) BOOL isRunning;

/// The port the server is listening on (0 if not running).
@property (nonatomic, readonly) uint16_t port;

@end

NS_ASSUME_NONNULL_END
