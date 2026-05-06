#import "ViewController.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

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
    self.appButton.title = @"选择App";
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

@end
