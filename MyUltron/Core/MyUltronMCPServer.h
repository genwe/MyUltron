//
//  MyUltronMCPServer.h
//  MyUltron
//
//  MCP (Model Context Protocol) server.
//  Supports stdio transport (via -run) and socket transport (via +processRequestData:outputBlock:).
//

#import <Foundation/Foundation.h>

@class MyUltronClient;

NS_ASSUME_NONNULL_BEGIN

/// Block that sends a JSON-RPC response line back to the client.
typedef void (^MCPResponseBlock)(NSDictionary *jsonRpcResponse);

@interface MyUltronMCPServer : NSObject

/// Shared singleton instance (tool registry + device state).
+ (instancetype)sharedInstance;

/// Start the MCP server over stdio. Reads JSON-RPC from stdin, writes to stdout.
/// Blocks the calling thread until stdin closes.
- (void)run;

/// Process a JSON-RPC request (raw data) and invoke outputBlock with each response.
/// Can be called from any transport (stdio, socket, etc.).
+ (void)processRequestData:(NSData *)data outputBlock:(MCPResponseBlock)outputBlock;

/// Set the shared TCP client from the GUI. When set, MCP TCP tools reuse this
/// connection instead of creating their own. Set to nil when disconnected.
@property (nonatomic, weak, nullable) MyUltronClient *sharedClient;

/// Called by ViewController when it receives a message from the iOS device.
/// Forwards to any pending MCP request waiting for a response.
- (void)handleIncomingMessage:(NSDictionary *)message;

/// Called by ViewController when it receives binary data from the iOS device.
- (void)handleIncomingBinary:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
