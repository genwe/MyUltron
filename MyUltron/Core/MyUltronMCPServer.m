//
//  MyUltronMCPServer.m
//  MyUltron
//
//  MCP (Model Context Protocol) server over stdio.
//  Exposes iOS debugging tools to AI assistants like Claude Code.
//

#import "MyUltronMCPServer.h"
#import "MyUltronMCPBridge.h"
#import "MyUltronClient.h"
#import <CommonCrypto/CommonDigest.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

#define MCP_LOG(...) // NSLog(__VA_ARGS__)  // uncomment for debug

// MARK: - Tool Registry

typedef NSDictionary *_Nullable (^MCPToolHandler)(NSDictionary *arguments, NSString *_Nullable *_error);

// Shared registry (lazy-initialized)
static NSDictionary<NSString *, NSDictionary *> *_sharedSchemas = nil;
static NSDictionary<NSString *, MCPToolHandler> *_sharedHandlers = nil;
static dispatch_once_t _registryOnce;

@interface MyUltronMCPServer ()
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *toolSchemas;
@property (nonatomic, strong) NSDictionary<NSString *, MCPToolHandler> *toolHandlers;
@property (nonatomic, strong) NSFileHandle *stdIn;
@property (nonatomic, strong) NSFileHandle *stdOut;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, strong) MyUltronMCPBridge *bridge;
@property (nonatomic, copy)   NSString *connectedUDID;
@property (nonatomic, copy)   NSString *connectedBundleID;
@property (nonatomic, assign) BOOL connectedIsSimulator;
@end

@implementation MyUltronMCPServer

static MyUltronMCPServer *_sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[MyUltronMCPServer alloc] initForToolRegistry];
    });
    return _sharedInstance;
}

/// Internal init for the shared tool registry instance (no stdin/stdout)
- (instancetype)initForToolRegistry {
    self = [super init];
    return self;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stdIn = [NSFileHandle fileHandleWithStandardInput];
        _stdOut = [NSFileHandle fileHandleWithStandardOutput];
        _readBuffer = [NSMutableData data];
        [MyUltronMCPServer ensureToolRegistry];
    }
    return self;
}

#pragma mark - Shared Tool Registry

+ (void)ensureToolRegistry {
    dispatch_once(&_registryOnce, ^{
        MyUltronMCPServer *server = [MyUltronMCPServer sharedInstance];
        [server registerAllTools];
        _sharedSchemas = server.toolSchemas;
        _sharedHandlers = server.toolHandlers;
    });
}

+ (NSDictionary<NSString *, NSDictionary *> *)toolSchemas { return _sharedSchemas; }
+ (NSDictionary<NSString *, MCPToolHandler> *)toolHandlers { return _sharedHandlers; }

#pragma mark - Class Method: Process Request (shared by stdio + socket)

+ (void)processRequestData:(NSData *)data outputBlock:(MCPResponseBlock)outputBlock {
    [self ensureToolRegistry];  // ensure shared schemas/handlers are initialized
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!obj || ![obj isKindOfClass:[NSDictionary class]]) {
        [self sendJSONRPCError:nil code:-32700 message:@"Parse error" output:outputBlock];
        return;
    }

    NSDictionary *req = (NSDictionary *)obj;
    NSString *method = [req[@"method"] isKindOfClass:[NSString class]] ? req[@"method"] : nil;
    id reqId = req[@"id"];
    NSDictionary *params = [req[@"params"] isKindOfClass:[NSDictionary class]] ? req[@"params"] : @{};

    if (!method) {
        [self sendJSONRPCError:reqId code:-32600 message:@"Invalid Request: missing method" output:outputBlock];
        return;
    }

    if ([method isEqualToString:@"initialize"]) {
        [self sendJSONRPCResult:reqId result:@{
            @"protocolVersion": @"2024-11-05",
            @"capabilities": @{@"tools": @{}},
            @"serverInfo": @{@"name": @"MyUltron", @"version": @"0.1.13"},
        } output:outputBlock];
    } else if ([method isEqualToString:@"ping"]) {
        [self sendJSONRPCResult:reqId result:@{} output:outputBlock];
    } else if ([method isEqualToString:@"tools/list"]) {
        [self sendJSONRPCResult:reqId result:@{@"tools": _sharedSchemas ? [_sharedSchemas.allValues copy] : @[]} output:outputBlock];
    } else if ([method isEqualToString:@"tools/call"]) {
        NSString *toolName = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;
        NSDictionary *args = [params[@"arguments"] isKindOfClass:[NSDictionary class]] ? params[@"arguments"] : @{};
        if (!toolName) {
            [self sendJSONRPCError:reqId code:-32602 message:@"Invalid params: missing name" output:outputBlock];
            return;
        }
        MCPToolHandler handler = _sharedHandlers[toolName];
        if (!handler) {
            [self sendJSONRPCError:reqId code:-32602 message:[NSString stringWithFormat:@"Unknown tool: %@", toolName] output:outputBlock];
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *toolError = nil;
            NSDictionary *result = handler(args, &toolError);
            if (toolError) {
                [self sendJSONRPCResult:reqId result:@{
                    @"content": @[@{@"type": @"text", @"text": [NSString stringWithFormat:@"Error: %@", toolError]}],
                    @"isError": @YES,
                } output:outputBlock];
            } else if (!result) {
                [self sendJSONRPCResult:reqId result:@{
                    @"content": @[@{@"type": @"text", @"text": @"Tool returned no result"}],
                    @"isError": @YES,
                } output:outputBlock];
            } else {
                NSError *jsonErr = nil;
                NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&jsonErr];
                NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : [NSString stringWithFormat:@"(serialization error: %@)", jsonErr.localizedDescription];
                [self sendJSONRPCResult:reqId result:@{
                    @"content": @[@{@"type": @"text", @"text": text}],
                } output:outputBlock];
            }
        });
    } else {
        [self sendJSONRPCError:reqId code:-32601 message:[NSString stringWithFormat:@"Method not found: %@", method] output:outputBlock];
    }
}

#pragma mark - JSON-RPC Output Helpers

+ (void)sendJSONRPCResult:(id)reqId result:(NSDictionary *)result output:(MCPResponseBlock)output {
    if (!reqId) return;
    output(@{@"jsonrpc": @"2.0", @"id": reqId, @"result": result ?: @{}});
}

+ (void)sendJSONRPCError:(id)reqId code:(int)code message:(NSString *)msg output:(MCPResponseBlock)output {
    if (!reqId) return;
    output(@{@"jsonrpc": @"2.0", @"id": reqId, @"error": @{@"code": @(code), @"message": msg ?: @"Unknown error"}});
}

#pragma mark - Instance: stdio Transport

- (void)run {
    MCP_LOG(@"[MCPServer] Starting MCP server on stdin/stdout");

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(stdinReadComplete:)
                                                 name:NSFileHandleReadCompletionNotification
                                               object:_stdIn];
    [_stdIn readInBackgroundAndNotify];

    // Keep the run loop alive
    while (YES) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate distantFuture]];
        }
    }
}

- (void)stdinReadComplete:(NSNotification *)notification {
    NSData *data = notification.userInfo[NSFileHandleNotificationDataItem];
    if (!data || data.length == 0) {
        MCP_LOG(@"[MCPServer] stdin closed, exiting");
        exit(0);
    }

    [_readBuffer appendData:data];

    while (YES) {
        NSRange newline = [_readBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                           options:0
                                             range:NSMakeRange(0, _readBuffer.length)];
        if (newline.location == NSNotFound) break;

        NSData *lineData = [_readBuffer subdataWithRange:NSMakeRange(0, newline.location)];
        [_readBuffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];

        __weak typeof(self) weakSelf = self;
        [MyUltronMCPServer processRequestData:lineData outputBlock:^(NSDictionary *response) {
            [weakSelf sendToStdout:response];
        }];
    }

    [_stdIn readInBackgroundAndNotify];
}

- (void)sendToStdout:(NSDictionary *)dict {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return;
    NSMutableData *line = [data mutableCopy];
    [line appendData:[NSData dataWithBytes:"\n" length:1]];
    [_stdOut writeData:line];
}

#pragma mark - Shared Tool Registry (class methods)

- (void)registerAllTools {
    // Tools are registered as { name: { schema dict } } and { name: handler block }
    // Schemas follow MCP tool inputSchema format (JSON Schema)

    NSMutableDictionary *schemas = [NSMutableDictionary dictionary];
    NSMutableDictionary *handlers = [NSMutableDictionary dictionary];

    // ---- Tier 3: Local Codec Tools ----

    [self addTool:@"url_encode"
          description:@"URL-encode a string"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"text": @{@"type": @"string", @"description": @"The string to URL-encode"},
                   },
                   @"required": @[@"text"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: text (string)";
            return nil;
        }
        return @{@"result": [self urlEncode:text]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"url_decode"
          description:@"URL-decode a string"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"text": @{@"type": @"string", @"description": @"The URL-encoded string to decode"},
                   },
                   @"required": @[@"text"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: text (string)";
            return nil;
        }
        return @{@"result": [self urlDecode:text]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"base64_encode"
          description:@"Base64-encode a string"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"text": @{@"type": @"string", @"description": @"The string to Base64-encode"},
                   },
                   @"required": @[@"text"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: text (string)";
            return nil;
        }
        return @{@"result": [self base64Encode:text]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"base64_decode"
          description:@"Base64-decode a string"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"text": @{@"type": @"string", @"description": @"The Base64-encoded string to decode"},
                   },
                   @"required": @[@"text"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: text (string)";
            return nil;
        }
        return @{@"result": [self base64Decode:text]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"md5_hash"
          description:@"Compute the MD5 hash of a string"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"text": @{@"type": @"string", @"description": @"The string to hash"},
                   },
                   @"required": @[@"text"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: text (string)";
            return nil;
        }
        return @{@"result": [self md5:text]};
    }
            toSchemas:schemas handlers:handlers];

    // ---- Tier 1: Device Tools (stub — implemented in Phase 2) ----

    [self addTool:@"list_devices"
          description:@"List connected iOS devices and booted simulators"
               schema:@{
                   @"type": @"object",
                   @"properties": @{},
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSArray *devices = [self scanDevices];
        return @{@"devices": devices};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"device_info"
          description:@"Get detailed information about a connected iOS device"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"udid": @{@"type": @"string", @"description": @"Device UDID (optional, auto-detects first device if omitted)"},
                   },
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *udid = [args[@"udid"] isKindOfClass:[NSString class]] ? args[@"udid"] : nil;
        return [self getDeviceInfo:udid error:error];
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"list_apps"
          description:@"List installed apps on a connected iOS device"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"udid": @{@"type": @"string", @"description": @"Device UDID (optional, auto-detects first device if omitted)"},
                   },
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *udid = [args[@"udid"] isKindOfClass:[NSString class]] ? args[@"udid"] : nil;
        return [self listApps:udid error:error];
    }
            toSchemas:schemas handlers:handlers];

    // ---- Tier 2: TCP Tools (requires app running with MyUltronServer) ----

    [self addTool:@"take_screenshot"
          description:@"Take a screenshot of the connected iOS app and save as PNG"
               schema:@{@"type": @"object", @"properties": @{}}
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSData *png = [self tcpExpectBinary:@"screenshot" content:@{} error:error];
        if (!png) return nil;
        NSString *dir = [@"~/Desktop" stringByExpandingTildeInPath];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
        NSString *filename = [NSString stringWithFormat:@"screenshot_%@.png", [fmt stringFromDate:[NSDate date]]];
        NSString *path = [dir stringByAppendingPathComponent:filename];
        [png writeToFile:path atomically:YES];
        return @{@"path": path, @"size": @(png.length)};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"list_sandbox_dir"
          description:@"List files and directories in the iOS app sandbox"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"path": @{@"type": @"string", @"description": @"Directory path (default: '/')"},
                   },
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *path = [args[@"path"] isKindOfClass:[NSString class]] ? args[@"path"] : @"/";
        NSDictionary *resp = [self tcpRequest:@"sandboxList" content:@{@"path": path} error:error];
        if (!resp) return nil;
        return @{@"path": resp[@"path"] ?: path, @"entries": resp[@"entries"] ?: @[]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"read_sandbox_file"
          description:@"Read a file from the iOS app sandbox (returns content as text or base64 for binary)"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"path": @{@"type": @"string", @"description": @"Full path to the file in the sandbox"},
                   },
                   @"required": @[@"path"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *path = args[@"path"];
        if (![path isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: path";
            return nil;
        }
        NSData *data = [self tcpExpectBinary:@"sandboxDownload" content:@{@"path": path} error:error];
        if (!data) return nil;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text) return @{@"path": path, @"content": text, @"encoding": @"utf8"};
        return @{@"path": path, @"base64": [data base64EncodedStringWithOptions:0], @"encoding": @"base64"};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"delete_sandbox_file"
          description:@"Delete a file or directory from the iOS app sandbox"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"path": @{@"type": @"string", @"description": @"Full path to delete"},
                   },
                   @"required": @[@"path"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *path = args[@"path"];
        if (![path isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: path";
            return nil;
        }
        NSDictionary *resp = [self tcpRequest:@"sandboxDelete" content:@{@"path": path} error:error];
        if (!resp) return nil;
        return resp;
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"list_user_defaults"
          description:@"List all keys in NSUserDefaults on the iOS device"
               schema:@{@"type": @"object", @"properties": @{}}
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSDictionary *resp = [self tcpRequest:@"userDefaultsList" content:@{} error:error];
        if (!resp) return nil;
        return @{@"keys": resp[@"keys"] ?: @[]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"get_user_default"
          description:@"Get a specific key from NSUserDefaults on the iOS device"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"key": @{@"type": @"string", @"description": @"The UserDefaults key to read"},
                   },
                   @"required": @[@"key"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *key = args[@"key"];
        if (![key isKindOfClass:[NSString class]]) {
            if (error) *error = @"Missing required parameter: key";
            return nil;
        }
        NSDictionary *resp = [self tcpRequest:@"userDefaultsList" content:@{} error:error];
        if (!resp) return nil;
        for (NSDictionary *entry in resp[@"keys"]) {
            if ([entry[@"key"] isEqualToString:key]) return entry;
        }
        return @{@"key": key, @"found": @NO};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"set_user_default"
          description:@"Set a value in NSUserDefaults on the iOS device"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"key": @{@"type": @"string", @"description": @"The UserDefaults key"},
                       @"value": @{@"type": @"string", @"description": @"The value to set"},
                       @"type": @{@"type": @"string", @"description": @"Value type: String, Number, Boolean, or Date"},
                   },
                   @"required": @[@"key", @"value"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSString *type = [args[@"type"] isKindOfClass:[NSString class]] ? args[@"type"] : @"String";
        NSDictionary *resp = [self tcpRequest:@"userDefaultsSet"
                                      content:@{@"key": args[@"key"], @"value": args[@"value"], @"type": type}
                                        error:error];
        return resp ?: @{@"success": @YES};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"delete_user_default"
          description:@"Delete a key from NSUserDefaults on the iOS device"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"key": @{@"type": @"string", @"description": @"The key to delete"},
                   },
                   @"required": @[@"key"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSDictionary *resp = [self tcpRequest:@"userDefaultsDelete"
                                      content:@{@"key": args[@"key"]}
                                        error:error];
        return resp ?: @{@"success": @YES};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"list_sqlite_dbs"
          description:@"List all SQLite databases in the iOS app sandbox"
               schema:@{@"type": @"object", @"properties": @{}}
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSDictionary *resp = [self tcpRequest:@"sqliteListDBs" content:@{} error:error];
        if (!resp) return nil;
        return @{@"databases": resp[@"databases"] ?: @[]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"list_sqlite_tables"
          description:@"List all tables in a specific SQLite database"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"database": @{@"type": @"string", @"description": @"Database file name"},
                   },
                   @"required": @[@"database"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSDictionary *resp = [self tcpRequest:@"sqliteGetTables"
                                      content:@{@"database": args[@"database"] ?: @""}
                                        error:error];
        if (!resp) return nil;
        return @{@"database": args[@"database"] ?: @"", @"tables": resp[@"tables"] ?: @[]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"query_sqlite"
          description:@"Execute a SELECT query on a SQLite database on the iOS device"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"database": @{@"type": @"string", @"description": @"Database file name"},
                       @"table": @{@"type": @"string", @"description": @"Table name to query"},
                   },
                   @"required": @[@"database", @"table"],
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSDictionary *resp = [self tcpRequest:@"sqliteQuery"
                                      content:@{@"database": args[@"database"] ?: @"", @"table": args[@"table"] ?: @""}
                                        error:error];
        if (!resp) return nil;
        return @{@"columns": resp[@"columns"] ?: @[], @"rows": resp[@"rows"] ?: @[]};
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"send_push"
          description:@"Send a simulated remote push notification to the iOS app"
               schema:@{
                   @"type": @"object",
                   @"properties": @{
                       @"title": @{@"type": @"string", @"description": @"Push notification title"},
                       @"body": @{@"type": @"string", @"description": @"Push notification body"},
                       @"badge": @{@"type": @"integer", @"description": @"Badge number"},
                   },
               }
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        NSMutableDictionary *aps = [NSMutableDictionary dictionary];
        NSMutableDictionary *alert = [NSMutableDictionary dictionary];
        if (args[@"title"]) alert[@"title"] = args[@"title"];
        if (args[@"body"]) alert[@"body"] = args[@"body"];
        if (alert.count > 0) aps[@"alert"] = alert;
        if (args[@"badge"]) aps[@"badge"] = args[@"badge"];
        aps[@"sound"] = @"default";

        NSDictionary *resp = [self tcpRequest:@"messagePush"
                                      content:@{@"aps": aps}
                                        error:error];
        if (!resp) return nil;
        return resp;
    }
            toSchemas:schemas handlers:handlers];

    [self addTool:@"list_network_requests"
          description:@"List recent network requests captured from the iOS app"
               schema:@{@"type": @"object", @"properties": @{}}
             handler:^NSDictionary *(NSDictionary *args, NSString **error) {
        // Network monitoring is push-based; returns the latest cached entries if available
        NSDictionary *resp = [self tcpRequest:@"networkMonitor"
                                      content:@{@"action": @"list"}
                                        error:error];
        if (!resp) return nil;
        return resp;
    }
            toSchemas:schemas handlers:handlers];

    self.toolSchemas = schemas;
    self.toolHandlers = handlers;
}

- (void)addTool:(NSString *)name
    description:(NSString *)desc
         schema:(NSDictionary *)inputSchema
        handler:(MCPToolHandler)handler
      toSchemas:(NSMutableDictionary *)schemas
       handlers:(NSMutableDictionary *)handlers
{
    schemas[name] = @{
        @"name": name,
        @"description": desc,
        @"inputSchema": inputSchema,
    };
    handlers[name] = handler;
}

#pragma mark - Tier 3: Local Codec

- (NSString *)urlEncode:(NSString *)s {
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSMutableCharacterSet *strict = [allowed mutableCopy];
    [strict removeCharactersInString:@"&=$+?/"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:strict];
}

- (NSString *)urlDecode:(NSString *)s {
    return [s stringByRemovingPercentEncoding] ?: @"";
}

- (NSString *)base64Encode:(NSString *)s {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    return [data base64EncodedStringWithOptions:0];
}

- (NSString *)base64Decode:(NSString *)s {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:s options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[Invalid Base64]";
}

- (NSString *)md5:(NSString *)s {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

#pragma mark - Tier 1: Device Scanning (Phase 2 stub — minimal implementation)

- (NSArray<NSDictionary *> *)scanDevices {
    NSMutableArray *result = [NSMutableArray array];

    // Booted simulators (file-system scan, no XPC needed)
    NSString *devRoot = [@"~/Library/Developer/CoreSimulator/Devices" stringByExpandingTildeInPath];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:devRoot error:nil];
    for (NSString *entry in entries) {
        if (entry.length != 36 || [entry characterAtIndex:8] != '-') continue;
        NSString *plistPath = [devRoot stringByAppendingPathComponent:[entry stringByAppendingPathComponent:@"device.plist"]];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if ([plist[@"state"] integerValue] == 3) {  // 3 = Booted
            [result addObject:@{@"name": plist[@"name"] ?: entry, @"udid": entry, @"isSimulator": @YES}];
        }
    }

    // Real devices via libimobiledevice
    char **udids = NULL;
    int count = 0;
    if (idevice_get_device_list(&udids, &count) == IDEVICE_E_SUCCESS && count > 0) {
        for (int i = 0; i < count; i++) {
            NSString *udid = @(udids[i]);
            NSString *name = [self lockdownDeviceName:udids[i]] ?: udid;
            [result addObject:@{@"name": name, @"udid": udid, @"isSimulator": @NO}];
        }
        idevice_device_list_free(udids);
    }

    return result;
}

- (NSString *)lockdownDeviceName:(const char *)udid {
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) return nil;
    lockdownd_client_t lckd = NULL;
    NSString *name = nil;
    if (lockdownd_client_new_with_handshake(dev, &lckd, "MyUltronMCP") == LOCKDOWN_E_SUCCESS) {
        plist_t val = NULL;
        if (lockdownd_get_value(lckd, NULL, "DeviceName", &val) == LOCKDOWN_E_SUCCESS && val) {
            char *str = NULL;
            plist_get_string_val(val, &str);
            if (str) { name = @(str); free(str); }
            plist_free(val);
        }
        lockdownd_client_free(lckd);
    }
    idevice_free(dev);
    return name;
}

- (NSDictionary *)getDeviceInfo:(NSString *)udid error:(NSString **)error {
    // Auto-detect first device if no UDID specified
    if (!udid) {
        NSArray *devices = [self scanDevices];
        if (devices.count == 0) {
            if (error) *error = @"No devices found. Connect a device via USB or start a simulator.";
            return nil;
        }
        udid = devices.firstObject[@"udid"];
    }

    // Determine if simulator
    BOOL isSim = (udid.length == 36 && [udid characterAtIndex:8] == '-');
    if (isSim) {
        // Simulator: parse device.plist
        NSString *plistPath = [[NSString stringWithFormat:@"~/Library/Developer/CoreSimulator/Devices/%@/device.plist", udid]
                               stringByExpandingTildeInPath];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) {
            if (error) *error = @"Simulator device.plist not found";
            return nil;
        }
        return @{
            @"udid": udid,
            @"deviceName": plist[@"name"] ?: udid,
            @"productType": plist[@"deviceType"] ?: @"Simulator",
            @"osVersion": [NSString stringWithFormat:@"%@ (%@)", plist[@"runtime"] ?: @"?", plist[@"buildVersion"] ?: @"?"],
            @"isSimulator": @YES,
        };
    }

    // Real device: use lockdown
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid.UTF8String, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"Cannot connect to device: %@", udid];
        return nil;
    }

    lockdownd_client_t lckd = NULL;
    if (lockdownd_client_new_with_handshake(dev, &lckd, "MyUltronMCP") != LOCKDOWN_E_SUCCESS) {
        idevice_free(dev);
        if (error) *error = @"Lockdown handshake failed";
        return nil;
    }

    plist_t allValues = NULL;
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:udid forKey:@"udid"];

    if (lockdownd_get_value(lckd, NULL, NULL, &allValues) == LOCKDOWN_E_SUCCESS && allValues) {
        NSArray *keys = @[@"DeviceName", @"ProductType", @"DeviceClass",
                          @"ProductVersion", @"BuildVersion",
                          @"SerialNumber", @"WiFiAddress"];
        for (NSString *key in keys) {
            plist_t node = plist_dict_get_item(allValues, key.UTF8String);
            if (node) {
                char *str = NULL;
                plist_get_string_val(node, &str);
                if (str) { info[key] = @(str); free(str); }
            }
        }
        plist_free(allValues);
    }
    info[@"isSimulator"] = @NO;

    lockdownd_client_free(lckd);
    idevice_free(dev);
    return info;
}

- (NSDictionary *)listApps:(NSString *)udid error:(NSString **)error {
    if (!udid) {
        NSArray *devices = [self scanDevices];
        if (devices.count == 0) {
            if (error) *error = @"No devices found";
            return nil;
        }
        udid = devices.firstObject[@"udid"];
    }

    BOOL isSim = (udid.length == 36 && [udid characterAtIndex:8] == '-');
    NSMutableArray *apps = [NSMutableArray array];

    if (isSim) {
        NSString *simctl = [self simctlPath];
        if (!simctl) simctl = @"/usr/bin/xcrun simctl";
        NSTask *task = [[NSTask alloc] init];
        if ([simctl hasSuffix:@"simctl"]) {
            task.executableURL = [NSURL fileURLWithPath:simctl];
            task.arguments = @[@"listapps", udid];
        } else {
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
            task.arguments = @[@"simctl", @"listapps", udid];
        }
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSPipe pipe];
        [task launchAndReturnError:nil];
        [task waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            [dict enumerateKeysAndObjectsUsingBlock:^(NSString *bid, NSDictionary *info, BOOL *s) {
                if ([bid hasPrefix:@"com.apple."]) return;
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bid;
                [apps addObject:@{@"name": name, @"bundleID": bid}];
            }];
        }
    } else {
        idevice_t dev = NULL;
        if (idevice_new_with_options(&dev, udid.UTF8String, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
            if (error) *error = @"Cannot connect to device";
            return nil;
        }
        lockdownd_client_t lckd = NULL;
        if (lockdownd_client_new_with_handshake(dev, &lckd, "MyUltronMCP") != LOCKDOWN_E_SUCCESS) {
            idevice_free(dev);
            if (error) *error = @"Lockdown handshake failed";
            return nil;
        }
        lockdownd_service_descriptor_t svc = NULL;
        instproxy_client_t ip = NULL;
        if (lockdownd_start_service(lckd, INSTPROXY_SERVICE_NAME, &svc) == LOCKDOWN_E_SUCCESS && svc) {
            if (instproxy_client_new(dev, svc, &ip) == INSTPROXY_E_SUCCESS) {
                plist_t opts = instproxy_client_options_new();
                instproxy_client_options_add(opts, "ApplicationType", "User", NULL);
                plist_t result = NULL;
                if (instproxy_browse(ip, opts, &result) == INSTPROXY_E_SUCCESS && result) {
                    uint32_t n = plist_array_get_size(result);
                    for (uint32_t i = 0; i < n; i++) {
                        plist_t app = plist_array_get_item(result, i);
                        plist_t nameNode = plist_dict_get_item(app, "CFBundleDisplayName");
                        if (!nameNode) nameNode = plist_dict_get_item(app, "CFBundleName");
                        plist_t bidNode = plist_dict_get_item(app, "CFBundleIdentifier");
                        char *nStr = NULL, *bStr = NULL;
                        if (nameNode) plist_get_string_val(nameNode, &nStr);
                        if (bidNode) plist_get_string_val(bidNode, &bStr);
                        if (nStr && bStr && ![@(bStr) hasPrefix:@"com.apple."]) {
                            [apps addObject:@{@"name": @(nStr), @"bundleID": @(bStr)}];
                        }
                        free(nStr); free(bStr);
                    }
                    plist_free(result);
                }
                plist_free(opts);
                instproxy_client_free(ip);
            }
            lockdownd_service_descriptor_free(svc);
        }
        lockdownd_client_free(lckd);
        idevice_free(dev);
    }

    [apps sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    return @{@"apps": apps};
}

- (NSString *)simctlPath {
    NSArray *candidates = @[
        @"/Applications/Xcode.app/Contents/Developer/usr/bin/simctl",
        @"/Applications/Xcode-beta.app/Contents/Developer/usr/bin/simctl",
        @"/Library/Developer/CommandLineTools/usr/bin/simctl",
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

#pragma mark - Request Tracking (shared client mode)

- (NSMutableDictionary<NSString *, id> *)pendingRequests {
    static NSMutableDictionary *dict;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary dictionary]; });
    return dict;
}

- (void)handleIncomingMessage:(NSDictionary *)message {
    // Only match requests expecting JSON (forBinary = NO)
    NSDictionary *pending = [self.pendingRequests copy];
    for (NSString *key in pending) {
        NSDictionary *entry = pending[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        if ([entry[@"forBinary"] boolValue]) continue;  // skip binary-expected
        dispatch_semaphore_t sem = entry[@"sem"];
        if (sem) {
            NSMutableDictionary *m = [entry mutableCopy];
            m[@"response"] = message;
            self.pendingRequests[key] = m;
            dispatch_semaphore_signal(sem);
            return;
        }
    }
}

- (void)handleIncomingBinary:(NSData *)data {
    // Only match requests expecting binary (forBinary = YES)
    NSDictionary *pending = [self.pendingRequests copy];
    for (NSString *key in pending) {
        NSDictionary *entry = pending[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        if (![entry[@"forBinary"] boolValue]) continue;  // skip JSON-expected
        dispatch_semaphore_t sem = entry[@"sem"];
        if (sem) {
            NSMutableDictionary *m = [entry mutableCopy];
            m[@"binary"] = data;
            self.pendingRequests[key] = m;
            dispatch_semaphore_signal(sem);
            return;
        }
    }
}

#pragma mark - TCP Helpers

- (BOOL)ensureConnected:(NSString **)error {
    if (self.sharedClient && self.sharedClient.isConnected) return YES;
    if (error) *error = @"Not connected. In the MyUltron app, select a device and an app first.";
    return NO;
}

- (NSDictionary *)tcpRequest:(NSString *)type content:(NSDictionary *)content error:(NSString **)error {
    if (![self ensureConnected:error]) return nil;

    NSString *reqId = [NSString stringWithFormat:@"mcp_%lu", (unsigned long)random()];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    self.pendingRequests[reqId] = @{@"sem": sem, @"type": type, @"forBinary": @NO};

    [self.sharedClient sendMessage:@{
        @"version": @"1.0",
        @"messageType": type,
        @"content": content,
    }];

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        [self.pendingRequests removeObjectForKey:reqId];
        if (error) *error = @"Request timed out. Is the iOS app running?";
        return nil;
    }

    NSDictionary *entry = self.pendingRequests[reqId];
    [self.pendingRequests removeObjectForKey:reqId];
    NSDictionary *response = entry[@"response"];
    return response ? response[@"content"] : nil;
}

- (NSData *)tcpExpectBinary:(NSString *)type content:(NSDictionary *)content error:(NSString **)error {
    if (![self ensureConnected:error]) return nil;

    NSString *reqId = [NSString stringWithFormat:@"mcp_%lu", (unsigned long)random()];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    self.pendingRequests[reqId] = @{@"sem": sem, @"type": type, @"forBinary": @YES};

    [self.sharedClient sendMessage:@{
        @"version": @"1.0",
        @"messageType": type,
        @"content": content,
    }];

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, deadline) != 0) {
        [self.pendingRequests removeObjectForKey:reqId];
        if (error) *error = @"Request timed out. Is the iOS app running?";
        return nil;
    }

    NSDictionary *entry = self.pendingRequests[reqId];
    [self.pendingRequests removeObjectForKey:reqId];
    return entry[@"binary"];
}

@end
