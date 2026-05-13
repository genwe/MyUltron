//
//  AppListViewController.m
//  MyUltron
//
//  应用列表面板：显示设备上安装的用户应用，含名称、Bundle ID、版本。
//  通过 libimobiledevice 的 installation_proxy 获取数据。
//

#import "AppListViewController.h"
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>

@interface AppListViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSScrollView        *scrollView;
@property (nonatomic, strong) NSTableView         *tableView;
@property (nonatomic, strong) NSTextField         *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;

@end

@implementation AppListViewController

#pragma mark - FeatureViewController overrides

+ (BOOL)requiresConnection { return YES; }
+ (BOOL)requiresApp      { return NO; }

- (instancetype)init {
    return [super initWithFeatureName:@"应用列表"];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.wantsLayer = YES;
    _rows = [NSMutableArray array];
    [self setupUI];
    [self refreshAppList];
}

#pragma mark - UI

- (void)setupUI {
    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO;
    _statusLabel.bordered = NO;
    _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.font = [NSFont systemFontOfSize:12];
    _statusLabel.stringValue = @"正在加载应用列表…";
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_spinner];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.borderType = NSBezelBorder;
    scrollView.hasVerticalScroller = YES;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scrollView];
    _scrollView = scrollView;

    _tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"应用名称";
    nameCol.width = 200;
    nameCol.minWidth = 140;
    nameCol.resizingMask = NSTableColumnUserResizingMask;
    [_tableView addTableColumn:nameCol];

    NSTableColumn *bidCol = [[NSTableColumn alloc] initWithIdentifier:@"bundleID"];
    bidCol.title = @"Bundle ID";
    bidCol.minWidth = 180;
    bidCol.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_tableView addTableColumn:bidCol];

    NSTableColumn *verCol = [[NSTableColumn alloc] initWithIdentifier:@"version"];
    verCol.title = @"版本";
    verCol.width = 80;
    verCol.minWidth = 60;
    verCol.resizingMask = NSTableColumnUserResizingMask;
    [_tableView addTableColumn:verCol];

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

- (void)refreshAppList {
    [_spinner startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self fetchAppList];

        dispatch_async(dispatch_get_main_queue(), ^{
            [_spinner stopAnimation:nil];
            [_tableView reloadData];
            if (_rows.count == 0) {
                _statusLabel.stringValue = @"未获取到应用或设备未连接";
            } else {
                _statusLabel.stringValue = [NSString stringWithFormat:@"共 %lu 个应用", (unsigned long)_rows.count];
            }
        });
    });
}

- (void)fetchAppList {
    [_rows removeAllObjects];

    const char *udid = _deviceUDID.UTF8String;
    if (!udid) {
        NSLog(@"[AppList] No device UDID set");
        return;
    }

    idevice_t device = NULL;
    if (idevice_new_with_options(&device, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
        NSLog(@"[AppList] idevice_new failed");
        dispatch_async(dispatch_get_main_queue(), ^{
            _statusLabel.stringValue = @"无法连接设备";
        });
        return;
    }

    lockdownd_client_t lockdown = NULL;
    if (lockdownd_client_new_with_handshake(device, &lockdown, "MyUltron") != LOCKDOWN_E_SUCCESS) {
        idevice_free(device);
        dispatch_async(dispatch_get_main_queue(), ^{
            _statusLabel.stringValue = @"Lockdown 握手失败";
        });
        return;
    }

    lockdownd_service_descriptor_t svc = NULL;
    instproxy_client_t ip = NULL;
    if (lockdownd_start_service(lockdown, INSTPROXY_SERVICE_NAME, &svc) != LOCKDOWN_E_SUCCESS || !svc) {
        NSLog(@"[AppList] lockdownd_start_service for instproxy failed");
        lockdownd_client_free(lockdown);
        idevice_free(device);
        return;
    }

    if (instproxy_client_new(device, svc, &ip) != INSTPROXY_E_SUCCESS) {
        NSLog(@"[AppList] instproxy_client_new failed");
        lockdownd_service_descriptor_free(svc);
        lockdownd_client_free(lockdown);
        idevice_free(device);
        return;
    }
    lockdownd_service_descriptor_free(svc);

    plist_t opts = instproxy_client_options_new();
    instproxy_client_options_add(opts, "ApplicationType", "User", NULL);

    plist_t result = NULL;
    instproxy_error_t ierr = instproxy_browse(ip, opts, &result);
    if (ierr == INSTPROXY_E_SUCCESS && result) {
        uint32_t n = plist_array_get_size(result);
        NSLog(@"[AppList] App count: %u", n);

        NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
        for (uint32_t i = 0; i < n; i++) {
            plist_t app = plist_array_get_item(result, i);
            plist_t nameNode = plist_dict_get_item(app, "CFBundleDisplayName");
            if (!nameNode) nameNode = plist_dict_get_item(app, "CFBundleName");
            plist_t bidNode = plist_dict_get_item(app, "CFBundleIdentifier");
            if (!bidNode) continue;

            char *nameStr = NULL, *bidStr = NULL, *verStr = NULL;
            plist_get_string_val(nameNode, &nameStr);
            plist_get_string_val(bidNode, &bidStr);

            NSString *displayName = nameStr ? @(nameStr) : (bidStr ? @(bidStr) : @"?");
            NSString *bid = bidStr ? @(bidStr) : @"";

            plist_t verNode = plist_dict_get_item(app, "CFBundleShortVersionString");
            if (!verNode) verNode = plist_dict_get_item(app, "CFBundleVersion");
            if (verNode) plist_get_string_val(verNode, &verStr);
            NSString *version = verStr ? @(verStr) : @"";

            [apps addObject:@{
                @"name":    displayName,
                @"bundleID": bid,
                @"version":  version
            }];

            if (nameStr) free(nameStr);
            if (bidStr)  free(bidStr);
            if (verStr)  free(verStr);
        }

        [apps sortUsingDescriptors:@[
            [NSSortDescriptor sortDescriptorWithKey:@"name"
                                          ascending:YES
                                           selector:@selector(localizedStandardCompare:)]
        ]];
        [_rows addObjectsFromArray:apps];
        plist_free(result);
    }
    plist_free(opts);
    instproxy_client_free(ip);

    lockdownd_client_free(lockdown);
    idevice_free(device);
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
    NSString *colID = tableColumn.identifier;
    if ([colID isEqualToString:@"name"]) {
        cell.textField.stringValue = rowData[@"name"];
        cell.textField.font = [NSFont boldSystemFontOfSize:12];
    } else if ([colID isEqualToString:@"bundleID"]) {
        cell.textField.stringValue = rowData[@"bundleID"];
        cell.textField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    } else {
        cell.textField.stringValue = rowData[@"version"];
        cell.textField.font = [NSFont systemFontOfSize:12];
    }

    CGFloat rowH = tableView.rowHeight;
    cell.textField.frame = NSMakeRect(4, (rowH - 16) / 2, tableColumn.width - 8, 16);
    return cell;
}

#pragma mark - NSTableViewDelegate

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return 28;
}

@end
