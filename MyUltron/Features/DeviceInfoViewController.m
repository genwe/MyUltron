//
//  DeviceInfoViewController.m
//  MyUltron
//
//  设备信息面板：显示设备名称、UDID、型号、系统版本、应用列表。
//  通过 libimobiledevice 获取设备数据，无需 TCP 连接。
//

#import "DeviceInfoViewController.h"
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
#import "MyUltronTheme.h"

@interface DeviceInfoViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSScrollView   *scrollView;
@property (nonatomic, strong) NSTableView    *tableView;
@property (nonatomic, strong) NSTextField    *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;

// Data
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;

@end

@implementation DeviceInfoViewController

#pragma mark - FeatureViewController overrides

+ (BOOL)requiresConnection { return YES; }
+ (BOOL)requiresApp      { return NO; }

- (instancetype)init {
    return [super initWithFeatureName:NSLocalizedString(@"设备信息", nil)];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    _rows = [NSMutableArray array];
    [self setupUI];
    [self refreshDeviceInfo];
}

#pragma mark - UI

- (void)setupUI {
    // Status label
    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO;
    _statusLabel.bordered = NO;
    _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor = [MyUltronTheme statusColor];
    _statusLabel.font = [MyUltronTheme statusFont];
    _statusLabel.stringValue = NSLocalizedString(@"正在加载设备信息…", nil);
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    // Spinner
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_spinner];

    // Table
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.borderType = NSBezelBorder;
    scrollView.hasVerticalScroller = YES;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scrollView];
    _scrollView = scrollView;

    _tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.headerView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;

    NSTableColumn *labelCol = [[NSTableColumn alloc] initWithIdentifier:@"label"];
    labelCol.title = NSLocalizedString(@"属性", nil);
    labelCol.width = 160;
    labelCol.minWidth = 120;
    labelCol.resizingMask = NSTableColumnUserResizingMask;
    [_tableView addTableColumn:labelCol];

    NSTableColumn *valueCol = [[NSTableColumn alloc] initWithIdentifier:@"value"];
    valueCol.title = NSLocalizedString(@"值", nil);
    valueCol.minWidth = 200;
    valueCol.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_tableView addTableColumn:valueCol];

    scrollView.documentView = _tableView;

    [NSLayoutConstraint activateConstraints:@[
        [_statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_statusLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
        [_spinner.leadingAnchor constraintEqualToAnchor:_statusLabel.trailingAnchor constant:6],
        [_spinner.centerYAnchor constraintEqualToAnchor:_statusLabel.centerYAnchor],

        [_scrollView.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:10],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8],
    ]];
}

#pragma mark - Data

- (void)refreshDeviceInfo {
    [_spinner startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self fetchDeviceData];

        dispatch_async(dispatch_get_main_queue(), ^{
            [_spinner stopAnimation:nil];
            [_tableView reloadData];
            if (_rows.count == 0) {
                _statusLabel.stringValue = NSLocalizedString(@"未连接设备或无法获取设备信息", nil);
            } else {
                _statusLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"共 %lu 条记录", nil), (unsigned long)_rows.count];
            }
        });
    });
}

- (void)fetchDeviceData {
    [_rows removeAllObjects];

    NSString *udid = self.deviceUDID;
    if (!udid) { NSLog(@"[DeviceInfo] No device UDID set"); return; }

    if (self.isSimulator) {
        [self fetchSimulatorInfo:udid];
        // 无论 xcrun 是否成功，至少显示基本 UDID
        if (_rows.count == 0) {
            [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(NSLocalizedString(@"设备号 (UDID)", nil), nil), nil), @"value": udid}];
            [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(@"设备类型", nil), nil), @"value": NSLocalizedString(@"iOS 模拟器", nil)}];
        }
        return;
    }

    // Real device path: libimobiledevice
    const char *cudid = udid.UTF8String;
    NSLog(@"[DeviceInfo] Fetching info for real device: %s", cudid);

    idevice_t device = NULL;
    idevice_error_t ret = idevice_new_with_options(&device, cudid, IDEVICE_LOOKUP_USBMUX);
    if (ret != IDEVICE_E_SUCCESS) {
        NSLog(@"[DeviceInfo] idevice_new failed: %d", ret);
        dispatch_async(dispatch_get_main_queue(), ^{
            _statusLabel.stringValue = NSLocalizedString(@"无法连接设备", nil);
        });
        return;
    }

    lockdownd_client_t lockdown = NULL;
    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(device, &lockdown, "MyUltron");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        NSLog(@"[DeviceInfo] lockdown handshake failed: %d", lerr);
        idevice_free(device);
        dispatch_async(dispatch_get_main_queue(), ^{
            _statusLabel.stringValue = NSLocalizedString(@"Lockdown 握手失败，请确认设备已信任此电脑", nil);
        });
        return;
    }

    // ---- Dump all root-domain lockdown values for debugging ----
    plist_t allValues = NULL;
    lerr = lockdownd_get_value(lockdown, NULL, NULL, &allValues);
    if (lerr == LOCKDOWN_E_SUCCESS && allValues) {
        char *xml = NULL;
        uint32_t xmlLen = 0;
        plist_to_xml(allValues, &xml, &xmlLen);
        if (xml) {
            NSLog(@"[DeviceInfo] Lockdown all values:\n%s", xml);
            free(xml);
        } else {
            NSLog(@"[DeviceInfo] Lockdown all values dump failed (plist_to_xml)");
        }
    } else {
        NSLog(@"[DeviceInfo] lockdownd_get_value(NULL, NULL) failed: %d", lerr);
    }

    // ---- 获取设备基本信息 (read from allValues dict directly) ----
    [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(NSLocalizedString(@"设备号 (UDID)", nil), nil), nil), @"value": self.deviceUDID ?: @""}];

    [_rows addObject:@{
        @"label": NSLocalizedString(NSLocalizedString(@"设备名称", nil), nil),
        @"value": [self plistDictString:allValues key:"DeviceName"] ?: @"—"
    }];

    [_rows addObject:@{
        @"label": NSLocalizedString(NSLocalizedString(@"设备型号", nil), nil),
        @"value": [self plistDictString:allValues key:"ProductType"] ?: @"—"
    }];

    // Try DeviceClass as fallback for model
    NSString *deviceClass = [self plistDictString:allValues key:"DeviceClass"];
    if (deviceClass) {
        [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(@"设备类型", nil), nil), @"value": deviceClass}];
    }

    // ProductVersion + BuildVersion
    {
        NSString *verStr = [self plistDictString:allValues key:"ProductVersion"];
        NSString *buildStr = [self plistDictString:allValues key:"BuildVersion"];
        NSString *osInfo = [NSString stringWithFormat:@"iOS %@%@",
                            verStr ?: @"?", buildStr ? [NSString stringWithFormat:@" (%@)", buildStr] : @""];
        [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(@"操作系统与版本", nil), nil), @"value": osInfo}];
    }

    // Additional useful info
    NSString *serialNum = [self plistDictString:allValues key:"SerialNumber"];
    if (serialNum) {
        [_rows addObject:@{@"label": NSLocalizedString(@"序列号", nil), @"value": serialNum}];
    }

    NSString *wifiAddr = [self plistDictString:allValues key:"WiFiAddress"];
    if (wifiAddr) {
        [_rows addObject:@{@"label": NSLocalizedString(@"WiFi 地址", nil), @"value": wifiAddr}];
    }

    if (allValues) plist_free(allValues);

    lockdownd_client_free(lockdown);
    idevice_free(device);
}

- (void)fetchSimulatorInfo:(NSString *)udid {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"simctl", @"list", @"devices", @"--json"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    NSError *launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        NSLog(@"[DeviceInfo] xcrun launch failed: %@", launchError);
        return;
    }

    // 最多等 3 秒，防止卡死
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [task waitUntilExit];
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        [task terminate];
        NSLog(@"[DeviceInfo] xcrun timed out");
        return;
    }

    if (task.terminationStatus != 0) {
        NSLog(@"[DeviceInfo] xcrun exited with status: %d", task.terminationStatus);
        return;
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    NSError *jsonErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (jsonErr) {
        NSLog(@"[DeviceInfo] xcrun JSON parse error: %@", jsonErr);
        return;
    }
    NSDictionary *runtimes = json[@"devices"];
    if (![runtimes isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[DeviceInfo] xcrun output missing 'devices' key");
        return;
    }

    NSLog(@"[DeviceInfo] Searching for simulator UDID: %@", udid);
    NSDictionary *foundDevice = nil;
    NSString *foundRuntime = nil;
    for (NSString *runtimeKey in runtimes) {
        if (![runtimeKey containsString:@"iOS"]) continue;
        NSArray *devices = runtimes[runtimeKey];
        if (![devices isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *d in devices) {
            if ([d[@"udid"] isEqualToString:udid]) {
                foundDevice = d;
                foundRuntime = runtimeKey;
                break;
            }
        }
        if (foundDevice) break;
    }

    if (!foundDevice) {
        NSLog(@"[DeviceInfo] Simulator UDID not found in xcrun output");
        return;
    }

    NSLog(@"[DeviceInfo] Found simulator: %@", foundDevice[@"name"]);

    [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(NSLocalizedString(@"设备号 (UDID)", nil), nil), nil), @"value": udid}];
    [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(@"设备名称", nil), nil), @"value": foundDevice[@"name"] ?: @"—"}];
    [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(@"设备型号", nil), nil), @"value": foundDevice[@"deviceTypeIdentifier"] ?: @"—"}];

    // Parse runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0" → "iOS 18.0"
    NSString *osVer = NSLocalizedString(@"模拟器", nil);
    if (foundRuntime) {
        NSArray *parts = [foundRuntime componentsSeparatedByString:@"."];
        NSString *last = parts.lastObject;
        if ([last containsString:@"-"]) {
            osVer = [[last stringByReplacingOccurrencesOfString:@"-" withString:@" "] stringByReplacingOccurrencesOfString:@"iOS" withString:@"iOS "];
        }
    }
    [_rows addObject:@{@"label": NSLocalizedString(NSLocalizedString(@"操作系统与版本", nil), nil), @"value": osVer}];

    NSString *state = foundDevice[@"state"];
    if (state) {
        [_rows addObject:@{@"label": NSLocalizedString(@"状态", nil), @"value": state}];
    }
}

/// Read a string value from a plist dict, returns nil if missing or wrong type.
- (nullable NSString *)plistDictString:(plist_t)dict key:(const char *)key {
    if (!dict) return nil;
    plist_t node = plist_dict_get_item(dict, key);
    if (!node) return nil;
    char *str = NULL;
    plist_get_string_val(node, &str);
    if (str) {
        NSString *result = @(str);
        free(str);
        return result;
    }
    return nil;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_rows.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row
{
    NSString *ident = [tableColumn.identifier stringByAppendingString:@"Cell"];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;

        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO;
        tf.bordered = NO;
        tf.drawsBackground = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;
    }

    NSDictionary *rowData = _rows[row];
    BOOL isLabel = [tableColumn.identifier isEqualToString:@"label"];
    cell.textField.stringValue = isLabel ? rowData[@"label"] : rowData[@"value"];

    // Bold for label column
    cell.textField.font = isLabel
        ? [MyUltronTheme tableBoldFont]
        : [MyUltronTheme monospacedFont];

    // Constrain cell text field
    CGFloat rowHeight = tableView.rowHeight;
    cell.textField.frame = NSMakeRect(6, (rowHeight - 16) / 2,
                                       tableColumn.width - 12, 16);

    return cell;
}

#pragma mark - NSTableViewDelegate

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return [MyUltronTheme tableRowHeight];
}

@end
