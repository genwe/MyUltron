//
//  MyUltronMCPBridge.h
//  MyUltron
//
//  Bridges MCP tool calls to the iOS device via MyUltronClient TCP connection.
//  Handles device connection, app launching, request/response correlation,
//  and binary data transfer.
//

#import <Foundation/Foundation.h>
@class MyUltronClient;

NS_ASSUME_NONNULL_BEGIN

/// Completion callback for TCP requests.
/// response: the parsed JSON response dictionary
/// binaryData: non-nil if the response was binary (e.g. screenshot PNG)
/// error: non-nil if the request failed
typedef void (^MCPBridgeCompletion)(NSDictionary *_Nullable response,
                                    NSData    *_Nullable binaryData,
                                    NSString  *_Nullable error);

@interface MyUltronMCPBridge : NSObject

/// Connect to an iOS device and launch the app for TCP communication.
/// Returns YES if connection succeeded, NO with error string otherwise.
- (BOOL)connectToDevice:(NSString *)udid
              bundleID:(NSString *)bundleID
             simulator:(BOOL)isSimulator
                 error:(NSString **)error;

/// Disconnect from the device.
- (void)disconnect;

/// Whether the bridge is currently connected via TCP.
@property (nonatomic, readonly) BOOL isConnected;

/// Send a JSON request and wait for the response.
/// - messageType: the messageType string (e.g. "sandboxList", "screenshot")
/// - content: the content dictionary
/// - timeout: seconds to wait before failing
/// - expectBinary: if YES, resolve on binary data arrival (for screenshot/download)
/// - completion: called with response or error
- (void)sendRequest:(NSString *)messageType
            content:(NSDictionary *)content
            timeout:(NSTimeInterval)timeout
      expectBinary:(BOOL)expectBinary
        completion:(MCPBridgeCompletion)completion;

@end

NS_ASSUME_NONNULL_END
