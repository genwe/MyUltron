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

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

@interface ViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSArray<NSString *> *featureItems;
@property (nonatomic, strong) NSViewController *currentFeatureVC;
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
    [self launchApp:app[@"bundleID"] onDevice:self.selectedUDID isSimulator:self.selectedIsSimulator];
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
