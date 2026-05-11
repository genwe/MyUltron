//
//  MyUltronClient.h
//  MyUltron
//
//  TCP client that connects to MyUltronServer running on an iOS device.
//  Handles the binary packet protocol and dispatches parsed JSON messages
//  to a delegate.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class MyUltronClient;

// MARK: - Delegate

@protocol MyUltronClientDelegate <NSObject>

/// A complete JSON message was received from the server.
- (void)client:(MyUltronClient *)client didReceiveMessage:(NSDictionary *)dict;

@optional
/// TCP connection established and handshake received.
- (void)clientDidConnect:(MyUltronClient *)client;

/// TCP connection lost.
- (void)clientDidDisconnect:(MyUltronClient *)client;

@end

// MARK: - Client

@interface MyUltronClient : NSObject

/// The delegate that will receive parsed messages.
@property (nonatomic, weak, nullable) id<MyUltronClientDelegate> delegate;

/// Whether the socket is currently connected.
@property (nonatomic, readonly) BOOL isConnected;

// ---- Connection ----

/// Connect directly to host:port (e.g. localhost:62345 for simulators).
- (void)connectToHost:(NSString *)host port:(uint16_t)port;

/// Disconnect.
- (void)disconnect;

// ---- Send ----

/// Send a JSON message (wrapped in a binary packet).
- (void)sendMessage:(NSDictionary *)dict;

@end

NS_ASSUME_NONNULL_END
