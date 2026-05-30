//
//  NetworkMonitorViewController.m
//  MyUltron
//
//  网络监控 + Mock 数据功能。
//

#import "NetworkMonitorViewController.h"
#import "../ViewController.h"
#import "../Core/MyUltronClient.h"
@import SQLite3;

static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

@interface NetworkMonitorViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTableView       *tableView;
@property (nonatomic, strong) NSScrollView      *scrollView;
@property (nonatomic, strong) NSButton          *toggleButton;
@property (nonatomic, strong) NSButton          *clearButton;
@property (nonatomic, strong) NSButton          *mockListButton;
@property (nonatomic, strong) NSTextField       *statusLabel;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *entries;
@property (nonatomic, assign) BOOL               isMonitoring;

// Detail
@property (nonatomic, strong) NSTextField        *detailLabel;
@property (nonatomic, strong) NSSegmentedControl  *detailSegment;
@property (nonatomic, strong) NSScrollView       *detailScrollView;
@property (nonatomic, strong) NSTextView         *detailTextView;
@property (nonatomic, strong) NSDictionary        *selectedEntry;

// Mock
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *mockRules;

// Mock edit sheet
@property (nonatomic, strong) NSWindow           *mockEditSheet;
@property (nonatomic, strong) NSTextField        *mockEditNameField;
@property (nonatomic, strong) NSTextField        *mockEditURLField;
@property (nonatomic, strong) NSTextField        *mockEditStatusField;
@property (nonatomic, strong) NSTextView         *mockEditBodyView;

// Mock list popover
@property (nonatomic, strong) NSPopover          *mockPopover;
@property (nonatomic, strong) NSTableView        *mockListTable;

// SQLite
@property (nonatomic, assign) sqlite3            *mockDB;

@end

@implementation NetworkMonitorViewController {
    NSInteger _detailCategory;
}

#pragma mark - Init

+ (BOOL)requiresApp { return YES; }

- (instancetype)init {
    self = [super initWithFeatureName:NSLocalizedString(@"网络监控", nil)];
    if (self) {
        _entries = [NSMutableArray array];
        _mockRules = [NSMutableArray array];
        _isMonitoring = YES;
        [self initMockDB];
    }
    return self;
}

- (void)dealloc {
    if (_mockDB) sqlite3_close(_mockDB);
}

#pragma mark - SQLite Mock DB

- (void)initMockDB {
    NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [appSupport stringByAppendingPathComponent:@"MyUltron"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dbPath = [dir stringByAppendingPathComponent:@"network_mock.db"];

    if (sqlite3_open(dbPath.UTF8String, &_mockDB) != SQLITE_OK) {
        NSLog(@"[Mock] Failed to open DB: %s", sqlite3_errmsg(_mockDB));
        return;
    }

    // 先检查当前 schema 是否已有 name 列（迁移只需执行一次）
    int hasNameCol = 0;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_mockDB, "SELECT name FROM mock_rules LIMIT 0", -1, &stmt, NULL) == SQLITE_OK) {
        hasNameCol = 1;
    }
    if (stmt) sqlite3_finalize(stmt);

    if (!hasNameCol) {
        // 迁移旧 schema（url UNIQUE → name UNIQUE + url TEXT）
        sqlite3_exec(_mockDB, "CREATE TABLE IF NOT EXISTS mock_rules_new ("
                     "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                     "name TEXT UNIQUE, url TEXT,"
                     "statusCode INTEGER DEFAULT 200,"
                     "responseHeaders TEXT DEFAULT '{}',"
                     "responseBody TEXT DEFAULT '',"
                     "enabled INTEGER DEFAULT 1)", NULL, NULL, NULL);
        sqlite3_exec(_mockDB, "INSERT OR IGNORE INTO mock_rules_new (name, url, statusCode, responseHeaders, responseBody, enabled) "
                     "SELECT url, url, statusCode, responseHeaders, responseBody, enabled FROM mock_rules", NULL, NULL, NULL);
        sqlite3_exec(_mockDB, "DROP TABLE IF EXISTS mock_rules", NULL, NULL, NULL);
        sqlite3_exec(_mockDB, "ALTER TABLE mock_rules_new RENAME TO mock_rules", NULL, NULL, NULL);
    }

    [self loadMockRulesFromDB];
}

- (void)loadMockRulesFromDB {
    [_mockRules removeAllObjects];
    const char *sql = "SELECT name, url, statusCode, responseHeaders, responseBody, enabled FROM mock_rules ORDER BY name";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_mockDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"name"] = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)] ?: @"";
            d[@"url"]  = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 1)] ?: @"";
            d[@"statusCode"] = @(sqlite3_column_int(stmt, 2));
            const char *h = (const char *)sqlite3_column_text(stmt, 3);
            d[@"responseHeaders"] = h ? [NSString stringWithUTF8String:h] : @"{}";
            const char *b = (const char *)sqlite3_column_text(stmt, 4);
            d[@"responseBody"] = b ? [NSString stringWithUTF8String:b] : @"";
            d[@"enabled"] = @(sqlite3_column_int(stmt, 5));
            [_mockRules addObject:d];
        }
        sqlite3_finalize(stmt);
    }
}

- (void)saveMockRuleToDB:(NSDictionary *)rule {
    const char *sql = "INSERT OR REPLACE INTO mock_rules (name, url, statusCode, responseHeaders, responseBody, enabled) VALUES (?,?,?,?,?,?)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_mockDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [rule[@"name"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [rule[@"url"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt,  3, [rule[@"statusCode"] intValue]);
        sqlite3_bind_text(stmt, 4, [rule[@"responseHeaders"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 5, [rule[@"responseBody"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt,  6, [rule[@"enabled"] boolValue] ? 1 : 0);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

- (void)deleteMockRuleFromDB:(NSString *)name {
    sqlite3_exec(_mockDB, [[NSString stringWithFormat:@"DELETE FROM mock_rules WHERE name='%@'",
                            [name stringByReplacingOccurrencesOfString:@"'" withString:@"''"]] UTF8String], NULL, NULL, NULL);
}

- (void)syncMockRulesToDevice {
    NSMutableArray *rules = [NSMutableArray array];
    for (NSDictionary *rule in _mockRules) {
        if ([rule[@"enabled"] boolValue]) {
            [rules addObject:@{
                @"name": rule[@"name"] ?: @"",
                @"url": rule[@"url"] ?: @"",
                @"statusCode": rule[@"statusCode"] ?: @200,
                @"responseHeaders": rule[@"responseHeaders"] ?: @"{}",
                @"responseBody": rule[@"responseBody"] ?: @"",
            }];
        }
    }
    [self sendMessage:@"networkMock" content:@{@"action": @"sync", @"rules": rules}];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    self.view.wantsLayer = YES;
    [self setupUI];
    [self updateStatusForConnection];
}

- (void)viewDidConnect {
    [super viewDidConnect];
    [self updateStatusForConnection];
    [self syncMockRulesToDevice];
}

- (void)viewDidDisconnect {
    [super viewDidDisconnect];
    [self updateStatusForConnection];
}

#pragma mark - Connection

- (MyUltronClient *)client {
    return ((ViewController *)self.parentViewController).client;
}

- (void)updateStatusForConnection {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.client.isConnected) {
            self.statusLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"已连接 | %lu 请求 | %lu Mock", nil),
                                            (unsigned long)self.entries.count, (unsigned long)self.mockRules.count];
            self.toggleButton.enabled = YES;
            self.clearButton.enabled = YES;
            self.mockListButton.enabled = YES;
        } else {
            self.statusLabel.stringValue = NSLocalizedString(@"未连接", nil);
            self.toggleButton.enabled = NO;
            self.clearButton.enabled = NO;
            self.mockListButton.enabled = NO;
        }
    });
}

#pragma mark - UI

- (void)setupUI {
    _toggleButton = [NSButton buttonWithTitle:NSLocalizedString(NSLocalizedString(@"⏸ 停止", nil), nil) target:self action:@selector(toggleMonitor:)];
    _toggleButton.bezelStyle = NSBezelStyleRounded;
    _toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toggleButton];

    _clearButton = [NSButton buttonWithTitle:NSLocalizedString(@"清空", nil) target:self action:@selector(clearEntries:)];
    _clearButton.bezelStyle = NSBezelStyleRounded;
    _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_clearButton];

    _mockListButton = [NSButton buttonWithTitle:NSLocalizedString(@"Mock 规则", nil) target:self action:@selector(showMockListWindow:)];
    _mockListButton.bezelStyle = NSBezelStyleRounded;
    _mockListButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_mockListButton];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO; _statusLabel.bordered = NO; _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.stringValue = NSLocalizedString(@"正在检测连接…", nil);
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    // ---- 请求列表 ----
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.borderType = NSBezelBorder;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self; _tableView.delegate = self;
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.menu = [self createContextMenu];

    NSArray *cols = @[
        @{@"id": @"method",   @"title": @"Method",  @"width": @60},
        @{@"id": @"url",      @"title": @"URL",     @"width": @280},
        @{@"id": @"status",   @"title": @"Status",  @"width": @55},
        @{@"id": @"duration", @"title": @"Duration", @"width": @70},
        @{@"id": @"size",     @"title": @"Size",    @"width": @70},
    ];
    for (NSDictionary *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[@"id"]];
        col.title = c[@"title"]; col.width = [c[@"width"] doubleValue];
        [_tableView addTableColumn:col];
    }
    _scrollView.documentView = _tableView;
    [self.view addSubview:_scrollView];

    // ---- 详情 ----
    _detailLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _detailLabel.stringValue = NSLocalizedString(@"请求详情：", nil);
    _detailLabel.editable = NO; _detailLabel.bordered = NO; _detailLabel.selectable = NO;
    _detailLabel.backgroundColor = [NSColor clearColor];
    _detailLabel.font = [NSFont boldSystemFontOfSize:11];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_detailLabel];

    _detailSegment = [NSSegmentedControl segmentedControlWithLabels:@[NSLocalizedString(@"请求头", nil),NSLocalizedString(@"请求体", nil),NSLocalizedString(@"响应头", nil),NSLocalizedString(@"响应体", nil)]
                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                             target:self action:@selector(detailCategoryChanged:)];
    _detailSegment.selectedSegment = 0;
    _detailSegment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_detailSegment];

    _detailScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _detailScrollView.borderType = NSBezelBorder;
    _detailScrollView.hasVerticalScroller = YES;
    _detailScrollView.translatesAutoresizingMaskIntoConstraints = NO;

    _detailTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _detailTextView.editable = NO;
    _detailTextView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    _detailTextView.backgroundColor = [NSColor textBackgroundColor];
    _detailTextView.textColor = [NSColor textColor];
    _detailScrollView.documentView = _detailTextView;
    [self.view addSubview:_detailScrollView];

    // ---- Layout ----
    [NSLayoutConstraint activateConstraints:@[
        [_toggleButton.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
        [_toggleButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_clearButton.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_clearButton.leadingAnchor constraintEqualToAnchor:_toggleButton.trailingAnchor constant:8],
        [_mockListButton.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_mockListButton.leadingAnchor constraintEqualToAnchor:_clearButton.trailingAnchor constant:8],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [_scrollView.topAnchor constraintEqualToAnchor:_toggleButton.bottomAnchor constant:10],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_scrollView.heightAnchor constraintEqualToConstant:220],

        [_detailLabel.topAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:8],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailSegment.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:4],
        [_detailSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [_detailScrollView.topAnchor constraintEqualToAnchor:_detailSegment.bottomAnchor constant:4],
        [_detailScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_detailScrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
    ]];
}

- (NSMenu *)createContextMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Mock This URL" action:@selector(mockSelectedRequest:) keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return menu;
}

#pragma mark - Mock: 规则列表弹窗

- (void)showMockListWindow:(id)sender {
    if (!_mockPopover) {
        NSViewController *vc = [[NSViewController alloc] init];
        NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 280)];

        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 520, 280)];
        sv.borderType = NSBezelBorder; sv.hasVerticalScroller = YES;
        sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        _mockListTable = [[NSTableView alloc] initWithFrame:sv.bounds];
        _mockListTable.dataSource = self; _mockListTable.delegate = self;
        _mockListTable.usesAlternatingRowBackgroundColors = YES;

        NSArray *mockCols = @[
            @{@"id": @"ml_name",    @"title": NSLocalizedString(@"名称", nil),    @"width": @130},
            @{@"id": @"ml_url",     @"title": @"URL",     @"width": @240},
            @{@"id": @"ml_status",  @"title": @"Status",  @"width": @55},
            @{@"id": @"ml_on",      @"title": @"On",      @"width": @35},
        ];
        for (NSDictionary *c in mockCols) {
            NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[@"id"]];
            col.title = c[@"title"]; col.width = [c[@"width"] doubleValue];
            [_mockListTable addTableColumn:col];
        }

        NSMenu *mockMenu = [[NSMenu alloc] init];
        NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"查看/修改", nil) action:@selector(editMockFromListWindow:) keyEquivalent:@""];
        editItem.target = self; [mockMenu addItem:editItem];
        NSMenuItem *delItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"删除", nil) action:@selector(deleteMockFromListWindow:) keyEquivalent:@""];
        delItem.target = self; [mockMenu addItem:delItem];
        _mockListTable.menu = mockMenu;

        sv.documentView = _mockListTable;
        [cv addSubview:sv];
        vc.view = cv;

        _mockPopover = [[NSPopover alloc] init];
        _mockPopover.contentViewController = vc;
        _mockPopover.behavior = NSPopoverBehaviorTransient;
    }
    [_mockListTable reloadData];
    [_mockPopover showRelativeToRect:_mockListButton.bounds ofView:_mockListButton preferredEdge:NSRectEdgeMaxY];
}

- (void)editMockFromListWindow:(id)sender {
    NSInteger row = _mockListTable.clickedRow;
    if (row < 0 || row >= (NSInteger)_mockRules.count) return;
    [self openMockEditorWithEntry:_mockRules[row] fromMockList:YES];
}

- (void)deleteMockFromListWindow:(id)sender {
    NSInteger row = _mockListTable.clickedRow;
    if (row < 0 || row >= (NSInteger)_mockRules.count) return;
    NSString *name = _mockRules[row][@"name"];
    [self deleteMockRuleFromDB:name];
    [self loadMockRulesFromDB];
    [_mockListTable reloadData];
    [self sendMessage:@"networkMock" content:@{@"action": @"delete", @"name": name}];
    [self updateStatusForConnection];
}

- (void)toggleMockFromListWindow:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_mockRules.count) return;
    NSMutableDictionary *rule = [_mockRules[row] mutableCopy];
    BOOL newState = ![rule[@"enabled"] boolValue];
    rule[@"enabled"] = @(newState);
    _mockRules[row] = rule;
    [self saveMockRuleToDB:rule];
    [_mockListTable reloadData];

    if (newState) {
        [self sendMessage:@"networkMock" content:@{
            @"action": @"add", @"name": rule[@"name"], @"url": rule[@"url"],
            @"statusCode": rule[@"statusCode"], @"responseHeaders": rule[@"responseHeaders"],
            @"responseBody": rule[@"responseBody"], @"enabled": @YES,
        }];
    } else {
        [self sendMessage:@"networkMock" content:@{@"action": @"delete", @"name": rule[@"name"]}];
    }
}

#pragma mark - Mock: 编辑

- (void)mockSelectedRequest:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_entries.count) return;
    [self openMockEditorWithEntry:_entries[row] fromMockList:NO];
}

- (void)openMockEditorWithEntry:(NSDictionary *)entry fromMockList:(BOOL)fromMockList {
    NSString *url = entry[@"url"];
    if ([url hasPrefix:@"[MOCK] "]) url = [url substringFromIndex:7];

    NSString *name;
    NSInteger statusCode;
    NSString *body;

    if (fromMockList) {
        name = entry[@"name"];
        statusCode = [entry[@"statusCode"] integerValue];
        body = entry[@"responseBody"];
    } else {
        // 从请求列表打开：显示当前真实 Response Body，不显示已保存的 mock 数据
        name = @"";
        statusCode = [entry[@"statusCode"] integerValue];
        body = entry[@"responseBody"] ?: @"";
    }

    [self showMockEditSheetWithName:name url:url statusCode:statusCode body:body];
}

- (void)showMockEditSheetWithName:(NSString *)name
                              url:(NSString *)url
                       statusCode:(NSInteger)statusCode
                             body:(NSString *)body {
    if (!_mockEditSheet || !_mockEditSheet.contentView) [self createMockEditSheet];
    _mockEditNameField.stringValue = name ?: @"";
    _mockEditURLField.stringValue = url;
    _mockEditStatusField.stringValue = [NSString stringWithFormat:@"%ld", (long)(statusCode > 0 ? statusCode : 200)];
    _mockEditBodyView.string = body ?: @"";
    [self.view.window beginSheet:_mockEditSheet completionHandler:nil];
}

- (void)createMockEditSheet {
    NSRect frame = NSMakeRect(0, 0, 520, 380);
    _mockEditSheet = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                   backing:NSBackingStoreBuffered defer:NO];
    _mockEditSheet.releasedWhenClosed = NO;
    _mockEditSheet.title = @"Mock Rule";

    NSView *cv = _mockEditSheet.contentView;
    CGFloat y = frame.size.height - 30;

    // 名称（必填）
    NSTextField *nameLabel = [self labelWithString:NSLocalizedString(@"名称 *:", nil)];
    nameLabel.frame = NSMakeRect(16, y, 50, 18); [cv addSubview:nameLabel];
    _mockEditNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(70, y-2, 434, 22)];
    _mockEditNameField.font = [NSFont systemFontOfSize:11];
    _mockEditNameField.placeholderString = NSLocalizedString(@"必填，同一URL可用不同名称区分", nil);
    [cv addSubview:_mockEditNameField];
    y -= 28;

    // URL
    NSTextField *urlLabel = [self labelWithString:@"URL:"];
    urlLabel.frame = NSMakeRect(16, y, 40, 18); [cv addSubview:urlLabel];
    _mockEditURLField = [[NSTextField alloc] initWithFrame:NSMakeRect(60, y-2, 444, 22)];
    _mockEditURLField.editable = NO; _mockEditURLField.font = [NSFont systemFontOfSize:11];
    [cv addSubview:_mockEditURLField];
    y -= 28;

    // Status
    NSTextField *statusLabel = [self labelWithString:@"Status:"];
    statusLabel.frame = NSMakeRect(16, y, 50, 18); [cv addSubview:statusLabel];
    _mockEditStatusField = [[NSTextField alloc] initWithFrame:NSMakeRect(70, y-2, 60, 22)];
    _mockEditStatusField.font = [NSFont systemFontOfSize:11];
    [cv addSubview:_mockEditStatusField];
    y -= 32;

    // Response Body
    NSTextField *bodyLabel = [self labelWithString:@"Response Body:"];
    bodyLabel.frame = NSMakeRect(16, y, 100, 18); [cv addSubview:bodyLabel];
    y -= 20;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 50, 488, y - 50)];
    sv.borderType = NSBezelBorder; sv.hasVerticalScroller = YES;
    _mockEditBodyView = [[NSTextView alloc] initWithFrame:sv.bounds];
    _mockEditBodyView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    sv.documentView = _mockEditBodyView;
    [cv addSubview:sv];

    NSButton *saveBtn = [NSButton buttonWithTitle:NSLocalizedString(@"保存", nil) target:self action:@selector(saveMockRule:)];
    saveBtn.bezelStyle = NSBezelStyleRounded; saveBtn.frame = NSMakeRect(430, 12, 74, 28);
    [cv addSubview:saveBtn];

    NSButton *cancelBtn = [NSButton buttonWithTitle:NSLocalizedString(@"取消", nil) target:self action:@selector(cancelMockEdit:)];
    cancelBtn.bezelStyle = NSBezelStyleRounded; cancelBtn.frame = NSMakeRect(350, 12, 74, 28);
    [cv addSubview:cancelBtn];
}

- (NSTextField *)labelWithString:(NSString *)s {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSZeroRect];
    l.stringValue = s; l.editable = NO; l.bordered = NO; l.selectable = NO;
    l.backgroundColor = [NSColor clearColor]; l.font = [NSFont systemFontOfSize:11];
    return l;
}

- (void)saveMockRule:(id)sender {
    NSString *name = _mockEditNameField.stringValue;
    if (name.length == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"名称不能为空", nil);
        [alert beginSheetModalForWindow:_mockEditSheet completionHandler:nil];
        return;
    }
    NSString *url = _mockEditURLField.stringValue;
    NSInteger statusCode = [_mockEditStatusField.stringValue integerValue];
    NSString *body = _mockEditBodyView.string;

    NSDictionary *rule = @{
        @"name": name, @"url": url,
        @"statusCode": @(statusCode > 0 ? statusCode : 200),
        @"responseHeaders": @"{}", @"responseBody": body ?: @"", @"enabled": @YES,
    };
    [self saveMockRuleToDB:rule];
    [self loadMockRulesFromDB];
    if (_mockPopover) [_mockListTable reloadData];
    [self updateStatusForConnection];

    [self sendMessage:@"networkMock" content:@{
        @"action": @"add", @"name": name, @"url": url,
        @"statusCode": @(statusCode > 0 ? statusCode : 200),
        @"responseHeaders": @"{}", @"responseBody": body ?: @"",
        @"enabled": @YES,
    }];

    [self.view.window endSheet:_mockEditSheet];
    [_mockEditSheet orderOut:nil];
}

- (void)cancelMockEdit:(id)sender {
    [self.view.window endSheet:_mockEditSheet];
    [_mockEditSheet orderOut:nil];
}

#pragma mark - Actions

- (void)toggleMonitor:(NSButton *)sender {
    _isMonitoring = !_isMonitoring;
    sender.title = _isMonitoring ? NSLocalizedString(NSLocalizedString(@"⏸ 停止", nil), nil) : NSLocalizedString(@"▶ 开始", nil);
    [self sendMessage:@"networkMonitor" content:@{@"action": _isMonitoring ? @"start" : @"stop"}];
}

- (void)clearEntries:(NSButton *)sender {
    [self.entries removeAllObjects];
    [self.tableView reloadData];
    _selectedEntry = nil;
    self.detailTextView.string = @"";
    [self updateStatusForConnection];
}

#pragma mark - Messaging

- (void)sendMessage:(NSString *)type content:(NSDictionary *)content {
    [self.client sendMessage:@{kMsgVersion: @"1.0", kMsgType: type, kMsgContent: content}];
}

- (void)didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[kMsgType];
    NSDictionary *content = dict[kMsgContent];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([type isEqualToString:@"networkMonitor"]) {
            if ([content[@"action"] isEqualToString:@"push"]) {
                NSDictionary *e = content[@"entry"];
                if ([e isKindOfClass:[NSDictionary class]]) {
                    [self.entries addObject:e];
                    if (self.entries.count > 200) [self.entries removeObjectAtIndex:0];
                    [self.tableView insertRowsAtIndexes:[NSIndexSet indexSetWithIndex:self.entries.count - 1]
                                          withAnimation:NSTableViewAnimationEffectNone];
                    [self updateStatusForConnection];
                }
            }
            if (content[@"monitoring"]) _isMonitoring = [content[@"monitoring"] boolValue];
        } else if ([type isEqualToString:@"networkMock"]) {
            if ([content[@"success"] boolValue]) {
                NSLog(@"[Mock] iOS 端已同步: %@", content[@"action"]);
            }
        }
    });
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    if (tv == _mockListTable) return (NSInteger)_mockRules.count;
    return (NSInteger)_entries.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (tv == _mockListTable) return [self mockListCellForColumn:col row:row];
    return [self requestCellForColumn:col row:row];
}

- (NSView *)requestCellForColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSDictionary *e = _entries[row]; NSString *cid = col.identifier; NSString *text = @"";
    if ([cid isEqualToString:@"method"])   text = e[@"method"];
    else if ([cid isEqualToString:@"url"]) text = e[@"url"];
    else if ([cid isEqualToString:@"status"]) {
        NSInteger c = [e[@"statusCode"] integerValue];
        text = c > 0 ? [NSString stringWithFormat:@"%ld", (long)c] : @"…";
    } else if ([cid isEqualToString:@"duration"])
        text = [NSString stringWithFormat:@"%.0f ms", [e[@"duration"] doubleValue] * 1000];
    else if ([cid isEqualToString:@"size"])
        text = [self formatBytes:[e[@"requestSize"] unsignedIntegerValue] + [e[@"responseSize"] unsignedIntegerValue]];
    return [self cellWithText:text identifier:cid inTable:_tableView];
}

- (NSView *)mockListCellForColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSDictionary *r = _mockRules[row]; NSString *cid = col.identifier;

    if ([cid isEqualToString:@"ml_on"]) {
        NSButton *btn = [_mockListTable makeViewWithIdentifier:cid owner:self];
        if (!btn) { btn = [[NSButton alloc] initWithFrame:NSZeroRect]; btn.title = @""; btn.bezelStyle = NSBezelStyleRegularSquare; btn.bordered = NO; btn.identifier = cid; }
        btn.tag = row; btn.title = [r[@"enabled"] boolValue] ? @"✅" : @"⬜";
        btn.target = self; btn.action = @selector(toggleMockFromListWindow:);
        return btn;
    }

    NSString *text = @"";
    if ([cid isEqualToString:@"ml_name"])   text = r[@"name"];
    else if ([cid isEqualToString:@"ml_url"]) text = r[@"url"];
    else if ([cid isEqualToString:@"ml_status"]) text = [r[@"statusCode"] stringValue];
    return [self cellWithText:text identifier:cid inTable:_mockListTable];
}

- (NSTableCellView *)cellWithText:(NSString *)text identifier:(NSString *)cid inTable:(NSTableView *)tv {
    NSTableCellView *cell = [tv makeViewWithIdentifier:cid owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO; tf.bordered = NO; tf.selectable = NO;
        tf.backgroundColor = [NSColor clearColor]; tf.font = [NSFont systemFontOfSize:11];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField = tf; [cell addSubview:tf];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]]; cell.identifier = cid;
    }
    cell.textField.stringValue = text; cell.textField.textColor = [NSColor textColor];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == _tableView) {
        NSInteger row = _tableView.selectedRow;
        if (row >= 0 && row < (NSInteger)_entries.count) [self showDetailForRow:row];
    }
}

#pragma mark - Detail

- (void)showDetailForRow:(NSInteger)row { _selectedEntry = _entries[row]; [self refreshDetail]; }
- (void)detailCategoryChanged:(NSSegmentedControl *)sender { _detailCategory = sender.selectedSegment; [self refreshDetail]; }
- (void)refreshDetail {
    if (!_selectedEntry) { self.detailTextView.string = @""; return; }
    NSDictionary *e = _selectedEntry; NSString *c = @"(empty)";
    switch (_detailCategory) {
        case 0: c = [e[@"requestHeaders"] length] ? e[@"requestHeaders"] : @"(empty)"; break;
        case 1: c = [e[@"requestBody"] length] ? e[@"requestBody"] : @"(empty)"; break;
        case 2: c = [e[@"responseHeaders"] length] ? e[@"responseHeaders"] : @"(empty)"; break;
        case 3: c = [e[@"responseBody"] length] ? e[@"responseBody"] : @"(empty)"; break;
    }
    self.detailTextView.string = c;
}

#pragma mark - Helpers

- (NSString *)formatBytes:(NSUInteger)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lu B", (unsigned long)bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
}

@end
