#import "ViewController.h"
#import "AppDelegate.h"

#import "Features/MessagePushViewController.h"
#import "Features/DeviceScreenshotViewController.h"
#import "Features/DeviceInfoViewController.h"
#import "Features/AppListViewController.h"
#import "Features/SandboxViewController.h"
#import "Features/MMKVViewController.h"
#import "Features/UserDefaultsViewController.h"
#import "Features/SqliteViewController.h"
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
#import "Features/FeatureViewController.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/afc.h>
#include <plist/plist.h>

// MARK: - DragForwardingView (forwards NSDraggingDestination to ViewController)

@interface DragForwardingView : NSView
@property (nonatomic, weak) ViewController *dragDelegate;
@end

@implementation DragForwardingView

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if ([self.dragDelegate respondsToSelector:@selector(draggingEntered:)]) {
        return [self.dragDelegate draggingEntered:sender];
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if ([self.dragDelegate respondsToSelector:@selector(draggingUpdated:)]) {
        return [self.dragDelegate draggingUpdated:sender];
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    if ([self.dragDelegate respondsToSelector:@selector(draggingExited:)]) {
        [self.dragDelegate draggingExited:sender];
    }
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    if ([self.dragDelegate respondsToSelector:@selector(prepareForDragOperation:)]) {
        return [self.dragDelegate prepareForDragOperation:sender];
    }
    return NO;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if ([self.dragDelegate respondsToSelector:@selector(performDragOperation:)]) {
        return [self.dragDelegate performDragOperation:sender];
    }
    return NO;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    if ([self.dragDelegate respondsToSelector:@selector(concludeDragOperation:)]) {
        [self.dragDelegate concludeDragOperation:sender];
    }
}

@end

// MARK: - ViewController

static NSString * const kPrefFeatureConfig = @"MyUltronFeatureConfig";

@interface ViewController () <NSTableViewDataSource, NSTableViewDelegate, MyUltronClientDelegate>
@property (nonatomic, strong) NSMutableArray<NSString *> *featureItems;
@property (nonatomic, strong) NSMutableArray<Class>     *featureClasses;
@property (nonatomic, strong) FeatureViewController *currentFeatureVC;

// Settings
@property (nonatomic, strong) NSButton *settingsButton;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *featureConfig;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *settingsEditConfig;
@property (nonatomic, weak)   NSView *settingsContentView;

// Connection layer
@property (nonatomic, strong, readwrite) MyUltronClient *client;
@property (nonatomic, assign) uint16_t       serverPort;  // 62345
@property (nonatomic, copy)   NSString       *selectedAppBundleID;

// Private helper methods (defined later but called from dispatch blocks above)
- (NSArray<NSDictionary *> *)bootedSimulators;
- (NSArray<NSDictionary *> *)bootedSimulatorsFromFileSystem;
- (NSString *)deviceNameForUDID:(const char *)udid;
- (NSArray<NSDictionary *> *)appsForSimulator:(NSString *)udid;
- (NSArray<NSDictionary *> *)appsForDevice:(NSString *)udid;
- (void)launchApp:(NSString *)bundleID onDevice:(NSString *)udid isSimulator:(BOOL)isSimulator;
- (void)connectToDeviceServer;
- (void)showFeatureAtIndex:(NSInteger)index;
- (void)showToast:(NSString *)message;
@end

@implementation ViewController

- (void)loadView {
    DragForwardingView *view = [[DragForwardingView alloc] initWithFrame:NSMakeRect(0, 0, 900, 650)];
    view.dragDelegate = self;
    self.view = view;
}

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

    // Settings gear button (top-right)
    self.settingsButton = [NSButton buttonWithTitle:@"⚙" target:self action:@selector(openFeatureSettings:)];
    self.settingsButton.bezelStyle = NSBezelStyleRounded;
    self.settingsButton.frame = NSMakeRect(self.view.bounds.size.width - 42,
                                            self.view.bounds.size.height - 40, 32, 28);
    self.settingsButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.settingsButton.font = [NSFont systemFontOfSize:18];
    [self.view addSubview:self.settingsButton];

    // Init feature config & rebuild sidebar
    [self loadFeatureConfig];

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
    tableView.usesAlternatingRowBackgroundColors = YES;

    scrollView.documentView = tableView;
    self.scrollView = scrollView;
    self.tableView = tableView;
    [self.view addSubview:scrollView];

    NSRect containerFrame = NSMakeRect(232, 20, self.view.bounds.size.width - 232 - 16, listTop - 20);
    self.containerView = [[NSView alloc] initWithFrame:containerFrame];
    self.containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;
    self.containerView.wantsLayer = YES;
    self.containerView.layer.borderWidth = 1;
    [self updateLayerColors];
    [self.view addSubview:self.containerView];

    // Register drag-and-drop for .app / .ipa files
    [self.view registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    // Init TCP client (port from Preferences, default 62345)
    self.serverPort = [AppDelegate serverPort];
    self.client = [[MyUltronClient alloc] init];
    self.client.delegate = self;

    // 监听外观变化，自动更新 layer 颜色
    [self.view addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:NULL];
}

- (void)dealloc {
    [self.view removeObserver:self forKeyPath:@"effectiveAppearance"];
}

- (void)updateLayerColors {
    self.containerView.layer.backgroundColor = [[NSColor controlBackgroundColor] CGColor];
    self.containerView.layer.borderColor     = [[NSColor separatorColor] CGColor];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"effectiveAppearance"]) {
        [self updateLayerColors];
    }
}

#pragma mark - Feature Config

- (NSArray<NSDictionary *> *)defaultFeatureConfig {
    return @[
        @{@"name": @"设备信息",      @"class": [DeviceInfoViewController class]},
        @{@"name": @"应用列表",      @"class": [AppListViewController class]},
        @{@"name": @"设备截屏",      @"class": [DeviceScreenshotViewController class]},
        @{@"name": @"沙盒管理",      @"class": [SandboxViewController class]},
        @{@"name": @"MMKV数据",      @"class": [MMKVViewController class]},
        @{@"name": @"UserDefault数据",@"class": [UserDefaultsViewController class]},
        @{@"name": @"SQLite浏览器",   @"class": [SqliteViewController class]},
        @{@"name": @"编解码",        @"class": [CodecViewController class]},
        @{@"name": @"消息推送",      @"class": [MessagePushViewController class]},
        @{@"name": @"网络监控",      @"class": [NetworkMonitorViewController class]},
        @{@"name": @"日志监控",      @"class": [LogMonitorViewController class]},
        @{@"name": @"埋点监控",      @"class": [AnalyticsMonitorViewController class]},
        @{@"name": @"IM会话监控",    @"class": [IMSessionViewController class]},
        @{@"name": @"路由校验",      @"class": [RouteValidationViewController class]},
        @{@"name": @"环境切换",      @"class": [EnvironmentSwitchViewController class]},
        @{@"name": @"崩溃日志",      @"class": [CrashLogViewController class]},
        @{@"name": @"热修复",        @"class": [HotfixViewController class]},
        @{@"name": @"灰度任务",      @"class": [GrayscaleTaskViewController class]},
        @{@"name": @"解析日志文件",   @"class": [XlogParserViewController class]},
    ];
}

- (void)loadFeatureConfig {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kPrefFeatureConfig];
    _featureConfig = [NSMutableArray array];
    BOOL loaded = NO;
    if (saved && [saved isKindOfClass:[NSArray class]] && saved.count > 0) {
        for (id item in saved) {
            if (![item isKindOfClass:[NSDictionary class]]) { loaded = NO; break; }
            NSDictionary *d = (NSDictionary *)item;
            NSMutableDictionary *md = [NSMutableDictionary dictionary];
            
            // Validate name
            id nameVal = d[@"name"];
            if (![nameVal isKindOfClass:[NSString class]]) { loaded = NO; break; }
            md[@"name"] = nameVal;
            
            // Validate class
            id classVal = d[@"class"];
            Class cls = nil;
            if ([classVal isKindOfClass:[NSString class]]) {
                cls = NSClassFromString(classVal);
            } else if (classVal) {
                cls = classVal; // Legacy Class object
            }
            if (!cls) { loaded = NO; break; }
            md[@"class"] = cls;
            
            // Validate visible
            id visVal = d[@"visible"];
            md[@"visible"] = [visVal isKindOfClass:[NSNumber class]] ? visVal : @YES;
            
            [_featureConfig addObject:md];
            loaded = YES;
        }
    }
    if (!loaded) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPrefFeatureConfig];
        [_featureConfig removeAllObjects];
        for (NSDictionary *d in [self defaultFeatureConfig]) {
            [_featureConfig addObject:[NSMutableDictionary dictionaryWithDictionary:d]];
            _featureConfig.lastObject[@"visible"] = @YES;
        }
    }
    [self rebuildFeatureArrays];
}

- (void)saveFeatureConfig {
    // Convert class objects to strings for plist serialization
    NSMutableArray *serializable = [NSMutableArray arrayWithCapacity:_featureConfig.count];
    for (NSDictionary *d in _featureConfig) {
        NSMutableDictionary *sd = [NSMutableDictionary dictionary];
        // Validate and copy only plist-safe values
        id nameVal = d[@"name"];
        if ([nameVal isKindOfClass:[NSString class]]) sd[@"name"] = nameVal;
        else continue; // skip corrupted entries

        id classVal = d[@"class"];
        if (classVal) {
            sd[@"class"] = NSStringFromClass(classVal);
        } else continue;

        id visVal = d[@"visible"];
        sd[@"visible"] = [visVal isKindOfClass:[NSNumber class]] ? visVal : @YES;

        [serializable addObject:sd];
    }
    if (serializable.count > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:serializable forKey:kPrefFeatureConfig];
    }
    [self rebuildFeatureArrays];
    [self.tableView reloadData];
}

- (void)rebuildFeatureArrays {
    _featureItems = [NSMutableArray array];
    _featureClasses = [NSMutableArray array];
    for (NSDictionary *d in _featureConfig) {
        if ([d[@"visible"] boolValue]) {
            [_featureItems addObject:d[@"name"]];
            [_featureClasses addObject:d[@"class"]];
        }
    }
}

- (void)showDeviceMenu:(NSButton *)sender {
    // 防止重入
    if (!self.deviceButton.enabled) return;

    NSString *origTitle = self.deviceButton.title;
    self.deviceButton.title = @"扫描中…";
    self.deviceButton.enabled = NO;

    NSLog(@"[MyUltron] Device scan started…");

    // 超时保护：8 秒
    __block BOOL menuShown = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (menuShown) return;
        menuShown = YES;
        self.deviceButton.title = origTitle;
        self.deviceButton.enabled = YES;
        NSLog(@"[MyUltron] Device scan TIMEOUT — showing fallback menu");
        NSMenu *menu = [[NSMenu alloc] init];
        [menu addItemWithTitle:@"设备扫描超时，请重试" action:nil keyEquivalent:@""];
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 模拟器和真机并行扫描
        __block NSArray<NSDictionary *> *sims = nil;
        __block NSMutableArray<NSDictionary *> *realDevices = [NSMutableArray array];

        dispatch_group_t group = dispatch_group_create();

        dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSLog(@"[MyUltron] Scanning simulators…");
            sims = [self bootedSimulators];
            NSLog(@"[MyUltron] Found %lu booted simulator(s)", (unsigned long)sims.count);
        });

        dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSLog(@"[MyUltron] Scanning real devices…");
            char **udids = NULL;
            int count = 0;
            if (idevice_get_device_list(&udids, &count) == IDEVICE_E_SUCCESS && count > 0) {
                NSLog(@"[MyUltron] Found %d real device(s), fetching names…", count);
                for (int i = 0; i < count; i++) {
                    NSString *udid = @(udids[i]);
                    NSLog(@"[MyUltron]   → fetching name for %@…", udid);
                    NSString *name = [self deviceNameForUDID:udids[i]] ?: udid;
                    NSLog(@"[MyUltron]   → %@ = %@", udid, name);
                    [realDevices addObject:@{@"name": name, @"udid": udid, @"simulator": @NO}];
                }
                idevice_device_list_free(udids);
            } else {
                NSLog(@"[MyUltron] No real devices found");
            }
        });

        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        // 回到主线程构建菜单
        dispatch_async(dispatch_get_main_queue(), ^{
            if (menuShown) return;  // 超时已弹出，丢弃过期结果
            menuShown = YES;
            self.deviceButton.title = origTitle;
            self.deviceButton.enabled = YES;

            NSMenu *menu = [[NSMenu alloc] init];

            for (NSDictionary *sim in sims) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:sim[@"name"] action:@selector(selectDevice:) keyEquivalent:@""];
                item.target = self;
                item.representedObject = sim;
                [menu addItem:item];
            }

            if (realDevices.count > 0) {
                if (sims.count > 0) [menu addItem:[NSMenuItem separatorItem]];
                for (NSDictionary *dev in realDevices) {
                    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:dev[@"name"] action:@selector(selectDevice:) keyEquivalent:@""];
                    item.target = self;
                    item.representedObject = dev;
                    [menu addItem:item];
                }
            }

            if (menu.numberOfItems == 0) {
                [menu addItemWithTitle:@"未检测到设备" action:nil keyEquivalent:@""];
            }

            [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
        });
    });
}

- (void)selectDevice:(NSMenuItem *)item {
    NSDictionary *info = item.representedObject;
    self.deviceButton.title = info[@"name"];
    self.selectedUDID = info[@"udid"];
    self.selectedIsSimulator = [info[@"simulator"] boolValue];
    self.appButton.title = @"请选择应用";
    self.selectedAppBundleID = nil;
}

- (void)showAppMenu:(NSButton *)sender {
    if (!self.selectedUDID) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"请先选择设备";
        [alert runModal];
        return;
    }

    // 防止重入
    if (!self.appButton.enabled) return;

    NSString *origTitle = self.appButton.title;
    self.appButton.title = @"加载中…";
    self.appButton.enabled = NO;

    NSLog(@"[MyUltron] App scan started for %@…", self.selectedIsSimulator ? @"simulator" : @"device");

    // 超时保护：15 秒（真机 app 枚举需要 lockdown + instproxy_browse，比设备枚举更慢）
    __block BOOL menuShown = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (menuShown) return;
        menuShown = YES;
        self.appButton.title = origTitle;
        self.appButton.enabled = YES;
        NSLog(@"[MyUltron] App scan TIMEOUT");
        NSMenu *menu = [[NSMenu alloc] init];
        [menu addItemWithTitle:@"应用扫描超时，请重试" action:nil keyEquivalent:@""];
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSDictionary *> *apps = self.selectedIsSimulator
            ? [self appsForSimulator:self.selectedUDID]
            : [self appsForDevice:self.selectedUDID];
        NSLog(@"[MyUltron] Found %lu app(s)", (unsigned long)apps.count);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (menuShown) return;
            menuShown = YES;
            self.appButton.title = origTitle;
            self.appButton.enabled = YES;

            NSMenu *menu = [[NSMenu alloc] init];
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
        });
    });
}

- (void)selectApp:(NSMenuItem *)item {
    NSDictionary *app = item.representedObject;
    self.appButton.title = app[@"name"];

    // Keep track of the selected app info for connection
    NSString *bundleID = app[@"bundleID"];

    // Store for injecting into features created later
    self.selectedAppBundleID = bundleID;

    // Launch the app
    [self launchApp:bundleID onDevice:self.selectedUDID isSimulator:self.selectedIsSimulator];

    // Then connect to MyUltronServer running inside the app
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self connectToDeviceServer];
    });
}

#pragma mark - Device helpers

/// 直接定位 simctl 路径（绕过 xcrun，在新 macOS 上 xcrun 的 XPC 初始化可能阻塞）
+ (nullable NSString *)simctlPath {
    // 每次检查（不缓存），确保更新代码后立即生效
    NSArray *candidates = @[
        @"/Applications/Xcode.app/Contents/Developer/usr/bin/simctl",
        @"/Applications/Xcode-beta.app/Contents/Developer/usr/bin/simctl",
        @"/Library/Developer/CommandLineTools/usr/bin/simctl",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            NSLog(@"[MyUltron] simctlPath: found at %@", path);
            return path;
        }
    }
    NSLog(@"[MyUltron] simctlPath: not found at known paths, will fall back to xcrun");
    return nil;
}

/// simctl 超时后的回退方案：直接读取 CoreSimulator 文件系统中的 device.plist
/// 不依赖任何 XPC 服务，纯文件 I/O
- (NSArray<NSDictionary *> *)bootedSimulatorsFromFileSystem {
    NSString *devicesRoot = [@"~/Library/Developer/CoreSimulator/Devices" stringByExpandingTildeInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:devicesRoot error:nil];
    if (!entries) return @[];

    NSMutableArray *result = [NSMutableArray array];
    for (NSString *entry in entries) {
        // 跳过非 UUID 目录名（如 .DS_Store, device_set.plist）
        if (entry.length != 36 || [entry characterAtIndex:8] != '-') continue;

        NSString *plistPath = [devicesRoot stringByAppendingPathComponent:[entry stringByAppendingPathComponent:@"device.plist"]];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) continue;

        // CoreSimulator device.plist state: 0=Creating, 1=Shutdown, 3=Booted
        if ([plist[@"state"] integerValue] == 3) {
            NSString *name = plist[@"name"] ?: entry;
            [result addObject:@{@"name": name, @"udid": entry, @"simulator": @YES}];
        }
    }
    NSLog(@"[MyUltron] bootedSimulatorsFromFileSystem: found %lu booted", (unsigned long)result.count);
    return result;
}

- (NSArray<NSDictionary *> *)bootedSimulators {
    // simctl/xcrun 在新 macOS 上因 XPC 问题阻塞 5s+，直接走文件系统扫描
    return [self bootedSimulatorsFromFileSystem];
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
    NSString *simctl = [ViewController simctlPath];
    if (!simctl) simctl = @"/usr/bin/xcrun simctl";

    NSTask *task = [[NSTask alloc] init];
    if ([simctl hasSuffix:@"simctl"]) {
        task.executableURL = [NSURL fileURLWithPath:simctl];
        task.arguments = @[@"listapps", udid];
        // 直接调用 simctl 需要设置 DEVELOPER_DIR
        task.environment = @{@"DEVELOPER_DIR": [simctl stringByDeletingLastPathComponent].stringByDeletingLastPathComponent.stringByDeletingLastPathComponent};
    } else {
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        task.arguments = @[@"simctl", @"listapps", udid];
    }
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    if (![task launchAndReturnError:nil]) {
        NSLog(@"[MyUltron] appsForSimulator: failed to launch xcrun");
        return @[];
    }

    // 与 bootedSimulators 同样的超时保护
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (task.isRunning) {
            NSLog(@"[MyUltron] appsForSimulator: xcrun timed out, terminating");
            [task terminate];
        }
    });

    [task waitUntilExit];

    if (task.terminationReason == NSTaskTerminationReasonUncaughtSignal) {
        NSLog(@"[MyUltron] appsForSimulator: xcrun killed by timeout");
        return @[];
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSDictionary *plistDict = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if (![plistDict isKindOfClass:[NSDictionary class]]) return @[];

    NSMutableArray *apps = [NSMutableArray array];
    [plistDict enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, NSDictionary *info, BOOL *stop) {
        // Filter: skip Apple system apps and App Store apps
        if ([bundleID hasPrefix:@"com.apple."]) return;

        NSString *appType = info[@"ApplicationType"];
        if ([appType isEqualToString:@"System"]) return;

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
                        NSString *bid = @(bidStr);
                        // Skip Apple system apps
                        if ([bid hasPrefix:@"com.apple."]) {
                            free(nameStr); free(bidStr);
                            continue;
                        }
                        [apps addObject:@{@"name": @(nameStr), @"bundleID": bid}];
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

    self.serverPort = [AppDelegate serverPort];

    if (self.selectedIsSimulator) {
        [self.client connectToHost:@"127.0.0.1" port:self.serverPort];
    } else {
        [self.client connectToDeviceUDID:self.selectedUDID port:self.serverPort];
    }
}

#pragma mark - MyUltronClientDelegate

- (void)clientDidConnect:(MyUltronClient *)client {
    [self showToast:@"已连接到 App"];
    if ([self.currentFeatureVC respondsToSelector:@selector(viewDidConnect)]) {
        [self.currentFeatureVC viewDidConnect];
    }
}

- (void)clientDidDisconnect:(MyUltronClient *)client {
    [self showToast:@"连接已断开"];
    if ([self.currentFeatureVC respondsToSelector:@selector(viewDidDisconnect)]) {
        [self.currentFeatureVC viewDidDisconnect];
    }
}

- (void)client:(MyUltronClient *)client didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[@"messageType"];
    NSLog(@"[MyUltron] ← messageType: %@", type);

    if ([self.currentFeatureVC respondsToSelector:@selector(didReceiveMessage:)]) {
        [self.currentFeatureVC didReceiveMessage:dict];
    }
}

- (void)client:(MyUltronClient *)client didReceiveBinaryData:(NSData *)data {
    if ([self.currentFeatureVC respondsToSelector:@selector(didReceiveBinaryData:)]) {
        [self.currentFeatureVC performSelector:@selector(didReceiveBinaryData:)
                                    withObject:data];
    }
}

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return self.featureItems.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    // Sidebar only (settings table uses cell-based)
    NSTableCellView *cell = [tv makeViewWithIdentifier:@"featureCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"featureCell";
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO; tf.bordered = NO; tf.drawsBackground = NO;
        tf.font = [NSFont systemFontOfSize:13];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;
    }
    cell.textField.stringValue = self.featureItems[row];
    CGFloat rowH = tv.rowHeight;
    cell.textField.frame = NSMakeRect(8, (rowH - 16) / 2, col.width - 16, 16);
    return cell;
}

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row { return 24; }

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.featureItems.count) return;

    NSArray *classes = [self featureClasses];
    Class cls = classes[row];
    if ([cls requiresConnection] && !self.selectedUDID) {
        [self showToast:@"请选择连接设备"];
        return;
    }
    if ([cls requiresApp] && [self.appButton.title isEqualToString:@"请选择应用"]) {
        [self showToast:@"请选择应用"];
        return;
    }

    NSLog(@"[Ultron] 选中功能: %@", self.featureItems[row]);
    [self showFeatureAtIndex:row];
}

#pragma mark - Settings Dialog

- (void)openFeatureSettings:(NSButton *)sender {
    NSMutableArray<NSMutableDictionary *> *editConfig = [NSMutableArray array];
    for (NSDictionary *d in _featureConfig) {
        [editConfig addObject:[NSMutableDictionary dictionaryWithDictionary:d]];
    }

    CGFloat rowH = 26;
    NSUInteger n = editConfig.count;
    CGFloat contentH = n * rowH;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 310, 380)];
    sv.borderType = NSBezelBorder; sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;

    NSView *contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 290, contentH)];

    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *d = editConfig[i];
        CGFloat y = contentH - (i + 1) * rowH;

        // Toggle
        NSButton *cb = [[NSButton alloc] initWithFrame:NSMakeRect(4, y + 5, 16, 16)];
        [cb setButtonType:NSButtonTypeSwitch];
        cb.title = @"";
        cb.state = [d[@"visible"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        cb.tag = i;
        cb.target = self;
        cb.action = @selector(settingsCheckToggled:);
        [contentView addSubview:cb];

        // Name
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(24, y + 3, 200, 20)];
        label.stringValue = d[@"name"];
        label.editable = NO; label.bordered = NO; label.drawsBackground = NO;
        label.font = [NSFont systemFontOfSize:13];
        [contentView addSubview:label];

        // Move up
        NSButton *up = [NSButton buttonWithTitle:@"▲" target:self action:@selector(settingsMoveUp:)];
        up.frame = NSMakeRect(230, y + 3, 24, 18);
        up.bezelStyle = NSBezelStyleSmallSquare; up.font = [NSFont systemFontOfSize:9]; up.tag = i;
        [contentView addSubview:up];

        // Move down
        NSButton *dn = [NSButton buttonWithTitle:@"▼" target:self action:@selector(settingsMoveDown:)];
        dn.frame = NSMakeRect(256, y + 3, 24, 18);
        dn.bezelStyle = NSBezelStyleSmallSquare; dn.font = [NSFont systemFontOfSize:9]; dn.tag = i;
        [contentView addSubview:dn];
    }

    sv.documentView = contentView;
    [contentView scrollPoint:NSMakePoint(0, contentH)];

    _settingsContentView = contentView;
    _settingsEditConfig = editConfig;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"功能列表设置";
    alert.informativeText = @"☑ 勾选控制侧边栏可见";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    alert.accessoryView = sv;

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) { _settingsEditConfig = nil; return; }
        _featureConfig = editConfig;
        _settingsEditConfig = nil;
        [self saveFeatureConfig];
    }];
}

- (void)settingsCheckToggled:(NSButton *)cb {
    if (!_settingsEditConfig) return;
    NSInteger i = cb.tag;
    if (i < 0 || i >= (NSInteger)_settingsEditConfig.count) return;
    _settingsEditConfig[i][@"visible"] = @(cb.state == NSControlStateValueOn);
}

- (void)settingsMoveUp:(NSButton *)btn {
    if (!_settingsEditConfig) return;
    NSInteger i = btn.tag;
    if (i <= 0 || i >= (NSInteger)_settingsEditConfig.count) return;
    [_settingsEditConfig exchangeObjectAtIndex:i withObjectAtIndex:i - 1];
    [self rebuildSettingsContent];
}

- (void)settingsMoveDown:(NSButton *)btn {
    if (!_settingsEditConfig) return;
    NSInteger i = btn.tag;
    if (i < 0 || i >= (NSInteger)_settingsEditConfig.count - 1) return;
    [_settingsEditConfig exchangeObjectAtIndex:i withObjectAtIndex:i + 1];
    [self rebuildSettingsContent];
}

- (void)rebuildSettingsContent {
    if (!_settingsContentView || !_settingsEditConfig) return;
    NSView *cv = _settingsContentView;
    NSUInteger n = _settingsEditConfig.count;
    CGFloat rowH = 26;
    CGFloat contentH = n * rowH;
    cv.frame = NSMakeRect(0, 0, 290, contentH);

    for (NSView *v in cv.subviews.copy) { [v removeFromSuperview]; }

    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *d = _settingsEditConfig[i];
        CGFloat y = contentH - (i + 1) * rowH;

        NSButton *cb = [[NSButton alloc] initWithFrame:NSMakeRect(4, y + 5, 16, 16)];
        [cb setButtonType:NSButtonTypeSwitch]; cb.title = @"";
        cb.state = [d[@"visible"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        cb.tag = i; cb.target = self; cb.action = @selector(settingsCheckToggled:);
        [cv addSubview:cb];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(24, y + 3, 200, 20)];
        label.stringValue = d[@"name"]; label.editable = NO; label.bordered = NO; label.drawsBackground = NO;
        label.font = [NSFont systemFontOfSize:13];
        [cv addSubview:label];

        NSButton *up = [NSButton buttonWithTitle:@"▲" target:self action:@selector(settingsMoveUp:)];
        up.frame = NSMakeRect(230, y + 3, 24, 18); up.bezelStyle = NSBezelStyleSmallSquare;
        up.font = [NSFont systemFontOfSize:9]; up.tag = i; [cv addSubview:up];

        NSButton *dn = [NSButton buttonWithTitle:@"▼" target:self action:@selector(settingsMoveDown:)];
        dn.frame = NSMakeRect(256, y + 3, 24, 18); dn.bezelStyle = NSBezelStyleSmallSquare;
        dn.font = [NSFont systemFontOfSize:9]; dn.tag = i; [cv addSubview:dn];
    }
}

- (void)showFeatureAtIndex:(NSInteger)index {
    if (self.currentFeatureVC) {
        [self.currentFeatureVC.view removeFromSuperview];
        [self.currentFeatureVC removeFromParentViewController];
        self.currentFeatureVC = nil;
    }

    NSArray *classes = [self featureClasses];
    Class cls = classes[index];
    FeatureViewController *vc = [[cls alloc] init];
    vc.deviceUDID = self.selectedUDID;
    vc.isSimulator = self.selectedIsSimulator;
    vc.appBundleID = self.selectedAppBundleID;
    [self addChildViewController:vc];
    vc.view.frame = self.containerView.bounds;
    vc.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.containerView addSubview:vc.view];
    self.currentFeatureVC = vc;
}

#pragma mark - Toast

- (void)showToast:(NSString *)message {
    // Container view for rounded background
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 36)];
    container.wantsLayer = YES;
    container.layer.backgroundColor = [[NSColor windowBackgroundColor] CGColor];
    container.layer.cornerRadius = 8;
    container.layer.masksToBounds = YES;

    // Centered label inside the container
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 7, 196, 22)];
    label.stringValue = message;
    label.editable = NO;
    label.bordered = NO;
    label.selectable = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor labelColor];
    label.font = [NSFont systemFontOfSize:14];
    [container addSubview:label];

    NSRect bounds = self.view.bounds;
    container.frame = NSMakeRect((bounds.size.width - 220) / 2,
                                 (bounds.size.height - 36) / 2,
                                 220, 36);
    container.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin |
                                  NSViewMinYMargin | NSViewMaxYMargin;
    container.alphaValue = 0;
    [self.view addSubview:container];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        container.animator.alphaValue = 1.0;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.5;
                container.animator.alphaValue = 0;
            } completionHandler:^{
                [container removeFromSuperview];
            }];
        });
    }];
}

#pragma mark - Drag & Drop (NSDraggingDestination)

- (BOOL)isInstallableFileAtURL:(NSURL *)url {
    NSString *ext = [url pathExtension].lowercaseString;
    if ([ext isEqualToString:@"app"] || [ext isEqualToString:@"ipa"]) {
        return YES;
    }
    // .app bundle might be passed as directory without extension in the URL
    NSString *path = url.path;
    if ([path.pathExtension.lowercaseString isEqualToString:@"app"]) {
        return YES;
    }
    return NO;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray<NSURL *> *urls = [pboard readObjectsForClasses:@[[NSURL class]]
                                                   options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if ([self isInstallableFileAtURL:url]) {
            [self setDragHighlight:YES];
            return NSDragOperationCopy;
        }
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray<NSURL *> *urls = [pboard readObjectsForClasses:@[[NSURL class]]
                                                   options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if ([self isInstallableFileAtURL:url]) {
            return NSDragOperationCopy;
        }
    }
    [self setDragHighlight:NO];
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    [self setDragHighlight:NO];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    [self setDragHighlight:NO];

    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray<NSURL *> *urls = [pboard readObjectsForClasses:@[[NSURL class]]
                                                   options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if ([self isInstallableFileAtURL:url]) {
            [self installAppAtPath:url.path];
            return YES;
        }
    }
    return NO;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    [self setDragHighlight:NO];
}

#pragma mark - App Installation

- (void)installAppAtPath:(NSString *)path {
    if (!self.selectedUDID) {
        [self showToast:@"请先选择设备后再拖拽安装"];
        return;
    }

    NSString *fileName = path.lastPathComponent;
    NSLog(@"[MyUltron] Installing: %@ → device: %@", fileName, self.selectedUDID);

    [self showToast:[NSString stringWithFormat:@"正在安装 %@ ...", fileName]];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = NO;
        NSString *errorMsg = nil;

        if (self.selectedIsSimulator) {
            success = [self installToSimulator:path error:&errorMsg];
        } else {
            success = [self installToDevice:path error:&errorMsg];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self showToast:[NSString stringWithFormat:@"%@ 安装成功", fileName]];
                NSLog(@"[Install] SUCCESS: %@ on device %@", fileName, self.selectedUDID);
            } else {
                [self showToast:[NSString stringWithFormat:@"安装失败: %@", errorMsg ?: @"未知错误"]];
                NSLog(@"[Install] FAILED: %@ — %@ (device: %@)", fileName, errorMsg, self.selectedUDID);
            }
        });
    });
}

- (BOOL)installToSimulator:(NSString *)path error:(NSString **)error {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"simctl", @"install", self.selectedUDID, path];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        if (error) *error = err.localizedDescription;
        return NO;
    }
    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSData *errData = [[task.standardError fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        if (error) *error = errStr ?: @"simctl install failed";
        return NO;
    }
    return YES;
}

- (BOOL)installToDevice:(NSString *)localPath error:(NSString **)error {
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:localPath isDirectory:&isDirectory]) {
        if (error) *error = @"文件不存在";
        return NO;
    }

    // 1. Connect to device
    idevice_t device = NULL;
    if (idevice_new_with_options(&device, self.selectedUDID.UTF8String, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
        if (error) *error = @"无法连接设备";
        return NO;
    }

    // 2. Lockdown handshake
    lockdownd_client_t lockdown = NULL;
    if (lockdownd_client_new_with_handshake(device, &lockdown, "MyUltron") != LOCKDOWN_E_SUCCESS) {
        idevice_free(device);
        if (error) *error = @"lockdown handshake 失败";
        return NO;
    }

    // 3. Upload file via AFC
    NSString *remotePath = nil;
    if (![self afcUpload:localPath isDirectory:isDirectory device:device lockdown:lockdown remotePath:&remotePath error:error]) {
        NSLog(@"[Install] AFC upload failed: %@", error ? *error : @"unknown");
        lockdownd_client_free(lockdown);
        idevice_free(device);
        return NO;
    }
    NSLog(@"[Install] AFC upload complete → %@", remotePath);

    // 4. Install via installation_proxy
    BOOL success = [self instproxyInstall:remotePath isDirectory:isDirectory device:device lockdown:lockdown error:error];

    // 5. Cleanup remote staging file (best-effort)
    [self afcRemoveRemotePath:remotePath device:device lockdown:lockdown];

    lockdownd_client_free(lockdown);
    idevice_free(device);
    return success;
}

#pragma mark - AFC Upload Helpers

- (BOOL)afcUpload:(NSString *)localPath
      isDirectory:(BOOL)isDirectory
           device:(idevice_t)device
         lockdown:(lockdownd_client_t)lockdown
       remotePath:(NSString **)outRemotePath
            error:(NSString **)error
{
    lockdownd_service_descriptor_t svc = NULL;
    afc_client_t afc = NULL;

    if (lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &svc) != LOCKDOWN_E_SUCCESS || !svc) {
        if (error) *error = @"无法启动 AFC 服务";
        return NO;
    }

    if (afc_client_new(device, svc, &afc) != AFC_E_SUCCESS) {
        lockdownd_service_descriptor_free(svc);
        if (error) *error = @"无法创建 AFC 客户端";
        return NO;
    }
    lockdownd_service_descriptor_free(svc);

    NSString *fileName = localPath.lastPathComponent;
    NSString *remotePath = [@"/PublicStaging" stringByAppendingPathComponent:fileName];
    *outRemotePath = remotePath;

    BOOL success = NO;
    if (isDirectory) {
        success = [self afcUploadDirectory:localPath toRemotePath:remotePath afc:afc error:error];
    } else {
        success = [self afcUploadFile:localPath toRemotePath:remotePath afc:afc error:error];
    }

    afc_client_free(afc);
    return success;
}

- (BOOL)afcUploadFile:(NSString *)localPath
         toRemotePath:(NSString *)remotePath
                  afc:(afc_client_t)afc
                error:(NSString **)error
{
    NSData *fileData = [NSData dataWithContentsOfFile:localPath];
    if (!fileData) {
        if (error) *error = @"无法读取本地文件";
        return NO;
    }

    uint64_t handle = 0;
    if (afc_file_open(afc, remotePath.UTF8String, AFC_FOPEN_WRONLY, &handle) != AFC_E_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"无法在设备上创建文件: %@", remotePath.lastPathComponent];
        return NO;
    }

    const char *bytes = (const char *)fileData.bytes;
    NSUInteger total = fileData.length;
    NSUInteger offset = 0;

    while (offset < total) {
        uint32_t chunk = (uint32_t)MIN(total - offset, (NSUInteger)(256 * 1024));
        uint32_t written = 0;
        if (afc_file_write(afc, handle, bytes + offset, chunk, &written) != AFC_E_SUCCESS || written == 0) {
            afc_file_close(afc, handle);
            if (error) *error = @"写入设备文件失败";
            return NO;
        }
        offset += written;
    }

    afc_file_close(afc, handle);
    return YES;
}

- (BOOL)afcUploadDirectory:(NSString *)localDir
              toRemotePath:(NSString *)remotePath
                       afc:(afc_client_t)afc
                     error:(NSString **)error
{
    // Create the .app directory on device
    if (afc_make_directory(afc, remotePath.UTF8String) != AFC_E_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"无法创建设备目录: %@", remotePath.lastPathComponent];
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:localDir error:nil];
    if (!contents) {
        if (error) *error = @"无法读取 .app 目录内容";
        return NO;
    }

    for (NSString *item in contents) {
        NSString *localItem = [localDir stringByAppendingPathComponent:item];
        NSString *remoteItem = [remotePath stringByAppendingPathComponent:item];

        BOOL isDir = NO;
        [fm fileExistsAtPath:localItem isDirectory:&isDir];

        if (isDir) {
            if (![self afcUploadDirectory:localItem toRemotePath:remoteItem afc:afc error:error]) {
                return NO;
            }
        } else {
            if (![self afcUploadFile:localItem toRemotePath:remoteItem afc:afc error:error]) {
                return NO;
            }
        }
    }

    return YES;
}

- (void)afcRemoveRemotePath:(NSString *)remotePath
                     device:(idevice_t)device
                   lockdown:(lockdownd_client_t)lockdown
{
    if (!remotePath) return;

    lockdownd_service_descriptor_t svc = NULL;
    afc_client_t afc = NULL;

    if (lockdownd_start_service(lockdown, AFC_SERVICE_NAME, &svc) != LOCKDOWN_E_SUCCESS || !svc) return;
    if (afc_client_new(device, svc, &afc) != AFC_E_SUCCESS) {
        lockdownd_service_descriptor_free(svc);
        return;
    }
    lockdownd_service_descriptor_free(svc);

    afc_remove_path_and_contents(afc, remotePath.UTF8String);
    afc_client_free(afc);
}

#pragma mark - instproxy Install Helper

typedef struct { BOOL done; NSString * __strong errMsg; } InstallCtx;

- (void)setDragHighlight:(BOOL)highlight {
    if (highlight) {
        self.containerView.layer.borderWidth = 3;
        self.containerView.layer.borderColor = [[NSColor systemBlueColor] CGColor];
    } else {
        self.containerView.layer.borderWidth = 1;
        self.containerView.layer.borderColor = [[NSColor separatorColor] CGColor];
    }
}

static void instproxy_status_callback(plist_t command, plist_t status, void *user_data) {
    if (!status) return;
    InstallCtx *ctx = (InstallCtx *)user_data;

    plist_t completeNode = plist_dict_get_item(status, "Status");
    if (completeNode) {
        char *s = NULL; plist_get_string_val(completeNode, &s);
        if (s) {
            if (strcmp(s, "Complete") == 0) ctx->done = YES;
            free(s);
        }
    }
    plist_t errNode = plist_dict_get_item(status, "Error");
    if (errNode) {
        char *e = NULL; plist_get_string_val(errNode, &e);
        if (e) { ctx->errMsg = @(e); free(e); }
    }
}

- (BOOL)instproxyInstall:(NSString *)remotePath
             isDirectory:(BOOL)isDirectory
                  device:(idevice_t)device
                lockdown:(lockdownd_client_t)lockdown
                   error:(NSString **)error
{
    lockdownd_service_descriptor_t svc = NULL;
    instproxy_client_t ip = NULL;

    if (lockdownd_start_service(lockdown, INSTPROXY_SERVICE_NAME, &svc) != LOCKDOWN_E_SUCCESS || !svc) {
        if (error) *error = @"无法启动 installation_proxy 服务";
        return NO;
    }

    if (instproxy_client_new(device, svc, &ip) != INSTPROXY_E_SUCCESS) {
        lockdownd_service_descriptor_free(svc);
        if (error) *error = @"无法创建 installation_proxy 客户端";
        return NO;
    }
    lockdownd_service_descriptor_free(svc);

    plist_t opts = NULL;
    if (isDirectory) {
        opts = instproxy_client_options_new();
        instproxy_client_options_add(opts, "PackageType", "Developer", NULL);
    }

    // Use status callback to properly track install completion
    InstallCtx ctx = { NO, nil };
    instproxy_error_t ret = instproxy_install(ip, remotePath.UTF8String, opts,
                                               instproxy_status_callback, &ctx);
    if (ret != INSTPROXY_E_SUCCESS) {
        if (error) *error = [NSString stringWithFormat:@"安装请求失败 (code %d)", ret];
        if (opts) instproxy_client_options_free(opts);
        instproxy_client_free(ip);
        return NO;
    }

    // Poll until install completes or times out (60s max)
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while (!ctx.done && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }

    BOOL success = ctx.done && !ctx.errMsg;
    if (!success && error) {
        *error = ctx.errMsg ?: @"安装超时或失败";
    }
    if (opts) instproxy_client_options_free(opts);
    instproxy_client_free(ip);
    return success;
}

@end