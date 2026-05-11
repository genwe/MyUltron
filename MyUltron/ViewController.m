#import "ViewController.h"

#import "Features/MessagePushViewController.h"
#import "Features/DeviceScreenshotViewController.h"
#import "Features/SandboxViewController.h"
#import "Features/MMKVViewController.h"
#import "Features/UserDefaultsViewController.h"
#import "Features/DatabaseViewController.h"
#import "Features/NetworkMonitorViewController.h"
#import "Features/LogMonitorViewController.h"
#import "Features/AnalyticsMonitorViewController.h"
#import "Features/IMSessionViewController.h"
#import "Features/RouteValidationViewController.h"
#import "Features/EnvironmentSwitchViewController.h"
#import "Features/CrashLogViewController.h"
#import "Features/HotfixViewController.h"
#import "Features/GrayscaleTaskViewController.h"
#import "Features/CodecViewController.h"
#import "Features/XlogParserViewController.h"
#import "Core/MyUltronClient.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

@interface ViewController () <NSTableViewDataSource, NSTableViewDelegate, MyUltronClientDelegate>
@property (nonatomic, strong) NSArray<NSString *> *featureItems;
@property (nonatomic, strong) NSViewController *currentFeatureVC;

// Connection layer
@property (nonatomic, strong, readwrite) MyUltronClient *client;
@property (nonatomic, strong) NSTask        *iproxyTask;
@property (nonatomic, assign) uint16_t       serverPort;  // 62345 release / 72345 debug
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.deviceButton = [NSButton buttonWithTitle:@"连接设备" target:self action:@selector(showDeviceMenu:)];
    self.deviceButton.frame = NSMakeRect(16, self.view.bounds.size.height - 44, 140, 32);
    self.deviceButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:self.deviceButton];

    self.appButton = [NSButton buttonWithTitle:@"选择App" target:self action:@selector(showAppMenu:)];
    self.appButton.frame = NSMakeRect(164, self.view.bounds.size.height - 44, 140, 32);
    self.appButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:self.appButton];

    self.featureItems = @[
        @"消息推送",@"设备截屏", @"沙盒管理",@"MMKV数据", @"UserDefault数据", @"数据库",
        @"网络监控", @"日志监控", @"埋点监控",
        @"IM会话监控", @"路由校验", @"环境切换",
        @"崩溃日志", @"热修复", @"灰度任务", @"编解码", @"解析xlog"
    ];

    CGFloat listTop = self.view.bounds.size.height - 52;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 20, 200, listTop - 20)];
    scrollView.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable | NSViewMinYMargin;
    scrollView.borderType = NSBezelBorder;
    scrollView.hasVerticalScroller = YES;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    tableView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"feature"];
    column.title = @"功能列表";
    column.width = scrollView.bounds.size.width;
    [tableView addTableColumn:column];
    tableView.headerView = nil;
    tableView.dataSource = self;
    tableView.delegate = self;

    scrollView.documentView = tableView;
    self.scrollView = scrollView;
    self.tableView = tableView;
    [self.view addSubview:scrollView];

    NSRect containerFrame = NSMakeRect(232, 20, self.view.bounds.size.width - 232 - 16, listTop - 20);
    self.containerView = [[NSView alloc] initWithFrame:containerFrame];
    self.containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;
    self.containerView.wantsLayer = YES;
    self.containerView.layer.backgroundColor = [[NSColor colorWithWhite:0.96 alpha:1.0] CGColor];
    self.containerView.layer.borderWidth = 1;
    self.containerView.layer.borderColor = [[NSColor lightGrayColor] CGColor];
    [self.view addSubview:self.containerView];

    // Init TCP client (port defaults to 62345 — the release port on the device)
    self.serverPort = 62345;
    self.client = [[MyUltronClient alloc] init];
    self.client.delegate = self;
}

- (void)showDeviceMenu:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] init];

    // 模拟器
    NSArray<NSDictionary *> *sims = [self bootedSimulators];
    for (NSDictionary *sim in sims) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:sim[@"name"] action:@selector(selectDevice:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = sim;
        [menu addItem:item];
    }

    // 真机
    char **udids = NULL;
    int count = 0;
    if (idevice_get_device_list(&udids, &count) == IDEVICE_E_SUCCESS && count > 0) {
        if (sims.count > 0) [menu addItem:[NSMenuItem separatorItem]];
        for (int i = 0; i < count; i++) {
            NSString *udid = @(udids[i]);
            NSString *name = [self deviceNameForUDID:udids[i]] ?: udid;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectDevice:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = @{@"name": name, @"udid": udid, @"simulator": @NO};
            [menu addItem:item];
        }
        idevice_device_list_free(udids);
    }

    if (menu.numberOfItems == 0) {
        [menu addItemWithTitle:@"未检测到设备" action:nil keyEquivalent:@""];
    }

    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}

- (void)selectDevice:(NSMenuItem *)item {
    NSDictionary *info = item.representedObject;
    self.deviceButton.title = info[@"name"];
    self.selectedUDID = info[@"udid"];
    self.selectedIsSimulator = [info[@"simulator"] boolValue];
    self.appButton.title = @"请选择应用";
}

- (void)showAppMenu:(NSButton *)sender {
    if (!self.selectedUDID) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"请先选择设备";
        [alert runModal];
        return;
    }

    NSMenu *menu = [[NSMenu alloc] init];
    NSArray<NSDictionary *> *apps = self.selectedIsSimulator
        ? [self appsForSimulator:self.selectedUDID]
        : [self appsForDevice:self.selectedUDID];

    for (NSDictionary *app in apps) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:app[@"name"] action:@selector(selectApp:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = app;
        [menu addItem:item];
    }

    if (menu.numberOfItems == 0) {
        [menu addItemWithTitle:@"未找到App" action:nil keyEquivalent:@""];
    }

    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}

- (void)selectApp:(NSMenuItem *)item {
    NSDictionary *app = item.representedObject;
    self.appButton.title = app[@"name"];

    // Keep track of the selected app info for connection
    NSString *bundleID = app[@"bundleID"];

    // Launch the app
    [self launchApp:bundleID onDevice:self.selectedUDID isSimulator:self.selectedIsSimulator];

    // Then connect to MyUltronServer running inside the app
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self connectToDeviceServer];
    });
}

#pragma mark - Device helpers

- (NSArray<NSDictionary *> *)bootedSimulators {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"simctl", @"list", @"devices", @"--json"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:nil]) return @[];
    [task waitUntilExit];

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *devicesByRuntime = json[@"devices"];
    if (![devicesByRuntime isKindOfClass:[NSDictionary class]]) return @[];

    NSMutableArray *result = [NSMutableArray array];
    [devicesByRuntime enumerateKeysAndObjectsUsingBlock:^(NSString *runtime, NSArray *devices, BOOL *stop) {
        if (![runtime containsString:@"iOS"]) return;
        for (NSDictionary *d in devices) {
            if (![d[@"state"] isEqualToString:@"Booted"]) continue;
            NSString *name = d[@"name"];
            NSString *udid = d[@"udid"];
            if (name && udid) {
                [result addObject:@{@"name": name, @"udid": udid, @"simulator": @YES}];
            }
        }
    }];
    return result;
}

- (NSString *)deviceNameForUDID:(const char *)udid {
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) return nil;
    lockdownd_client_t lckd = NULL;
    NSString *name = nil;
    if (lockdownd_client_new_with_handshake(dev, &lckd, "DeviceName") == LOCKDOWN_E_SUCCESS) {
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

#pragma mark - App helpers

- (NSArray<NSDictionary *> *)appsForSimulator:(NSString *)udid {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"simctl", @"listapps", udid];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:nil]) return @[];
    [task waitUntilExit];

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSDictionary *plistDict = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if (![plistDict isKindOfClass:[NSDictionary class]]) return @[];

    NSMutableArray *apps = [NSMutableArray array];
    [plistDict enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, NSDictionary *info, BOOL *stop) {
        NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: bundleID;
        [apps addObject:@{@"name": name, @"bundleID": bundleID}];
    }];
    [apps sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    return apps;
}

- (NSArray<NSDictionary *> *)appsForDevice:(NSString *)udid {
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid.UTF8String, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) return @[];

    lockdownd_client_t lckd = NULL;
    NSMutableArray *apps = [NSMutableArray array];
    if (lockdownd_client_new_with_handshake(dev, &lckd, "AppList") != LOCKDOWN_E_SUCCESS) {
        idevice_free(dev);
        return @[];
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
                    if (!nameNode || !bidNode) continue;
                    char *nameStr = NULL, *bidStr = NULL;
                    plist_get_string_val(nameNode, &nameStr);
                    plist_get_string_val(bidNode, &bidStr);
                    if (nameStr && bidStr) {
                        [apps addObject:@{@"name": @(nameStr), @"bundleID": @(bidStr)}];
                    }
                    free(nameStr); free(bidStr);
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
    [apps sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    return apps;
}

#pragma mark - Launch

- (void)launchApp:(NSString *)bundleID onDevice:(NSString *)udid isSimulator:(BOOL)isSimulator {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    if (isSimulator) {
        task.arguments = @[@"simctl", @"launch", udid, bundleID];
    } else {
        task.arguments = @[@"devicectl", @"device", @"process", @"launch", @"--device", udid, bundleID];
    }
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        NSLog(@"启动失败: %@", err.localizedDescription);
    }
}

#pragma mark - TCP Connection

- (void)connectToDeviceServer {
    [self.client disconnect];
    [self stopIproxy];

    if (self.selectedIsSimulator) {
        // Simulator: iOS app runs on the same host, connect to localhost
        [self.client connectToHost:@"127.0.0.1" port:self.serverPort];
    } else {
        // Real device: start iproxy to forward the port via USB
        [self startIproxyAndConnect];
    }
}

- (void)startIproxyAndConnect {
    NSString *iproxyPath = @"/usr/local/bin/iproxy";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:iproxyPath]) {
        iproxyPath = @"/opt/homebrew/bin/iproxy"; // Apple Silicon Homebrew
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:iproxyPath]) {
        NSLog(@"[MyUltron] iproxy not found — install libimobiledevice");
        [self showToast:@"未找到 iproxy，请安装 libimobiledevice"];
        return;
    }

    uint16_t localPort  = self.serverPort;
    uint16_t remotePort = self.serverPort;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:iproxyPath];
    task.arguments = @[
        [NSString stringWithFormat:@"%u", localPort],
        [NSString stringWithFormat:@"%u", remotePort],
        self.selectedUDID ?: @""
    ];
    task.standardOutput = [NSPipe pipe];
    task.standardError  = [NSPipe pipe];

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        NSLog(@"[MyUltron] iproxy launch failed: %@", err);
        return;
    }

    self.iproxyTask = task;
    NSLog(@"[MyUltron] iproxy started: %u → device %@:%u",
          localPort, self.selectedUDID, remotePort);

    // Give iproxy a moment to bind, then connect
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.client connectToHost:@"127.0.0.1" port:localPort];
    });
}

- (void)stopIproxy {
    if (self.iproxyTask && self.iproxyTask.isRunning) {
        [self.iproxyTask terminate];
        NSLog(@"[MyUltron] iproxy stopped");
    }
    self.iproxyTask = nil;
}

#pragma mark - MyUltronClientDelegate

- (void)clientDidConnect:(MyUltronClient *)client {
    [self showToast:@"已连接到 App"];
}

- (void)clientDidDisconnect:(MyUltronClient *)client {
    [self showToast:@"连接已断开"];
}

- (void)client:(MyUltronClient *)client didReceiveMessage:(NSDictionary *)dict {
    // Forward the received message to the currently active feature view controller,
    // or handle routing here.
    NSString *type = dict[@"messageType"];
    NSLog(@"[MyUltron] ← messageType: %@", type);
}

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.featureItems.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    return self.featureItems[row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.featureItems.count) return;

    if (!self.selectedUDID) {
        [self showToast:@"请选择连接设备"];
        return;
    }
    if ([self.appButton.title isEqualToString:@"请选择应用"]) {
        [self showToast:@"请选择应用"];
        return;
    }

    NSLog(@"[Ultron] 选中功能: %@", self.featureItems[row]);
    [self showFeatureAtIndex:row];
}

- (void)showFeatureAtIndex:(NSInteger)index {
    if (self.currentFeatureVC) {
        [self.currentFeatureVC.view removeFromSuperview];
        [self.currentFeatureVC removeFromParentViewController];
        self.currentFeatureVC = nil;
    }

    NSArray *classes = @[
        [MessagePushViewController class],
        [DeviceScreenshotViewController class],
        [SandboxViewController class],
        [MMKVViewController class],
        [UserDefaultsViewController class],
        [DatabaseViewController class],
        [NetworkMonitorViewController class],
        [LogMonitorViewController class],
        [AnalyticsMonitorViewController class],
        [IMSessionViewController class],
        [RouteValidationViewController class],
        [EnvironmentSwitchViewController class],
        [CrashLogViewController class],
        [HotfixViewController class],
        [GrayscaleTaskViewController class],
        [CodecViewController class],
        [XlogParserViewController class]
    ];

    Class cls = classes[index];
    NSViewController *vc = [[cls alloc] init];
    [self addChildViewController:vc];
    vc.view.frame = self.containerView.bounds;
    vc.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.containerView addSubview:vc.view];
    self.currentFeatureVC = vc;
}

#pragma mark - Toast

- (void)showToast:(NSString *)message {
    NSTextField *toast = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 180, 28)];
    toast.stringValue = message;
    toast.editable = NO;
    toast.bordered = NO;
    toast.selectable = NO;
    toast.alignment = NSTextAlignmentCenter;
    toast.textColor = [NSColor whiteColor];
    toast.backgroundColor = [NSColor colorWithWhite:0 alpha:0.75];
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = 6;
    toast.layer.masksToBounds = YES;
    toast.font = [NSFont systemFontOfSize:13];

    NSRect bounds = self.scrollView.bounds;
    toast.frame = NSMakeRect((bounds.size.width - 180) / 2, bounds.size.height - 40, 180, 28);
    toast.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    toast.alphaValue = 0;
    [self.scrollView addSubview:toast];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        toast.animator.alphaValue = 1.0;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.5;
                toast.animator.alphaValue = 0;
            } completionHandler:^{
                [toast removeFromSuperview];
            }];
        });
    }];
}

@end
