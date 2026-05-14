//
//  FeatureViewController.h
//  MyUltron
//
//  Base class for all feature panels. Subclasses override
//  -didReceiveMessage: to handle server responses.
//

#import <Cocoa/Cocoa.h>

@interface FeatureViewController : NSViewController

- (instancetype)initWithFeatureName:(NSString *)featureName;

/// Override to handle messages from the iOS server.
/// Called on the main thread.
- (void)didReceiveMessage:(NSDictionary *)dict;

/// Override to react to connection state changes.
- (void)viewDidConnect;
- (void)viewDidDisconnect;

/// Override to return NO for features that work without a device connection
/// (e.g. Codec). Default is YES.
+ (BOOL)requiresConnection;

/// Override to return NO for features that work without a selected app
/// (e.g. DeviceScreenshot). Default is YES.
+ (BOOL)requiresApp;

/// UDID of the currently selected device (simulator or real).
@property (nonatomic, copy) NSString *deviceUDID;

/// Bundle ID of the currently selected app (set by ViewController).
@property (nonatomic, copy) NSString *appBundleID;

/// YES if the currently selected device is a simulator.
@property (nonatomic, assign) BOOL isSimulator;

@end
