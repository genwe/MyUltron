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
@property (nonatomic, strong) NSTableView        *mockTableView;
@property (nonatomic, strong) NSScrollView       *mockScrollView;
@property (nonatomic, strong) NSTextField        *mockLabel;

// Mock edit sheet
@property (nonatomic, strong) NSWindow           *mockEditSheet;
@property (nonatomic, strong) NSTextField        *mockEditURLField;
@property (nonatomic, strong) NSTextField        *mockEditStatusField;
@property (nonatomic, strong) NSTextView         *mockEditBodyView;

// SQLite
@property (nonatomic, assign) sqlite3            *mockDB;

@end

@implementation NetworkMonitorViewController {
    NSInteger _detailCategory;
    NSInteger _mockEditIndex; // -1 for new, >=0 for editing existing
}

#pragma mark - Init

+ (BOOL)requiresApp { return YES; }

- (instancetype)init {
    self = [super initWithFeatureName:@"网络监控"];
    if (self) {
        _entries = [NSMutableArray array];
        _mockRules = [NSMutableArray array];
        _isMonitoring = YES;
        _mockEditIndex = -1;
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

    const char *sql = "CREATE TABLE IF NOT EXISTS mock_rules ("
                      "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                      "url TEXT UNIQUE,"
                      "statusCode INTEGER DEFAULT 200,"
                      "responseHeaders TEXT DEFAULT '{}',"
                      "responseBody TEXT DEFAULT '',"
                      "enabled INTEGER DEFAULT 1)";
    sqlite3_exec(_mockDB, sql, NULL, NULL, NULL);
    [self loadMockRulesFromDB];
}

- (void)loadMockRulesFromDB {
    [_mockRules removeAllObjects];
    const char *sql = "SELECT url, statusCode, responseHeaders, responseBody, enabled FROM mock_rules ORDER BY id";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_mockDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            d[@"url"]  = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)] ?: @"";
            d[@"statusCode"] = @(sqlite3_column_int(stmt, 1));
            const char *h = (const char *)sqlite3_column_text(stmt, 2);
            d[@"responseHeaders"] = h ? [NSString stringWithUTF8String:h] : @"{}";
            const char *b = (const char *)sqlite3_column_text(stmt, 3);
            d[@"responseBody"] = b ? [NSString stringWithUTF8String:b] : @"";
            d[@"enabled"] = @(sqlite3_column_int(stmt, 4));
            [_mockRules addObject:d];
        }
        sqlite3_finalize(stmt);
    }
}

- (void)saveMockRuleToDB:(NSDictionary *)rule {
    const char *sql = "INSERT OR REPLACE INTO mock_rules (url, statusCode, responseHeaders, responseBody, enabled) VALUES (?,?,?,?,?)";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_mockDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [rule[@"url"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt,  2, [rule[@"statusCode"] intValue]);
        sqlite3_bind_text(stmt, 3, [rule[@"responseHeaders"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [rule[@"responseBody"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt,  5, [rule[@"enabled"] boolValue] ? 1 : 0);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

- (void)deleteMockRuleFromDB:(NSString *)url {
    const char *sql = "DELETE FROM mock_rules WHERE url=?";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_mockDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
}

- (void)syncMockRulesToDevice {
    // 打包所有启用的规则，一次性同步
    NSMutableArray *rules = [NSMutableArray array];
    for (NSDictionary *rule in _mockRules) {
        if ([rule[@"enabled"] boolValue]) {
            [rules addObject:@{
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
    // 连接后同步 mock 规则到设备
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
            self.statusLabel.stringValue = [NSString stringWithFormat:@"已连接 | %lu 请求 | %lu Mock",
                                            (unsigned long)self.entries.count, (unsigned long)self.mockRules.count];
            self.toggleButton.enabled = YES;
            self.clearButton.enabled = YES;
        } else {
            self.statusLabel.stringValue = @"未连接";
            self.toggleButton.enabled = NO;
            self.clearButton.enabled = NO;
        }
    });
}

#pragma mark - UI

- (void)setupUI {
    _toggleButton = [NSButton buttonWithTitle:@"⏸ 停止" target:self action:@selector(toggleMonitor:)];
    _toggleButton.bezelStyle = NSBezelStyleRounded;
    _toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toggleButton];

    _clearButton = [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearEntries:)];
    _clearButton.bezelStyle = NSBezelStyleRounded;
    _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_clearButton];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO; _statusLabel.bordered = NO; _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.stringValue = @"正在检测连接…";
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
    _detailLabel.stringValue = @"请求详情：";
    _detailLabel.editable = NO; _detailLabel.bordered = NO; _detailLabel.selectable = NO;
    _detailLabel.backgroundColor = [NSColor clearColor];
    _detailLabel.font = [NSFont boldSystemFontOfSize:11];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_detailLabel];

    _detailSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"请求头",@"请求体",@"响应头",@"响应体"]
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

    // ---- Mock 规则列表 ----
    _mockLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _mockLabel.stringValue = @"Mock 规则：";
    _mockLabel.editable = NO; _mockLabel.bordered = NO; _mockLabel.selectable = NO;
    _mockLabel.backgroundColor = [NSColor clearColor];
    _mockLabel.font = [NSFont boldSystemFontOfSize:11];
    _mockLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_mockLabel];

    _mockScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _mockScrollView.borderType = NSBezelBorder;
    _mockScrollView.hasVerticalScroller = YES;
    _mockScrollView.translatesAutoresizingMaskIntoConstraints = NO;

    _mockTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _mockTableView.dataSource = self; _mockTableView.delegate = self;
    _mockTableView.usesAlternatingRowBackgroundColors = YES;
    NSArray *mockCols = @[
        @{@"id": @"mock_url",   @"title": @"Mock URL",    @"width": @280},
        @{@"id": @"mock_status",@"title": @"Status",      @"width": @55},
        @{@"id": @"mock_enabled",@"title": @"On",         @"width": @35},
    ];
    for (NSDictionary *c in mockCols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[@"id"]];
        col.title = c[@"title"]; col.width = [c[@"width"] doubleValue];
        [_mockTableView addTableColumn:col];
    }
    NSMenu *mockMenu = [[NSMenu alloc] init];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"查看/修改" action:@selector(editMockRule:) keyEquivalent:@""];
    editItem.target = self;
    [mockMenu addItem:editItem];
    NSMenuItem *delItem = [[NSMenuItem alloc] initWithTitle:@"删除" action:@selector(deleteMockRule:) keyEquivalent:@""];
    delItem.target = self;
    [mockMenu addItem:delItem];
    _mockTableView.menu = mockMenu;

    _mockScrollView.documentView = _mockTableView;
    [self.view addSubview:_mockScrollView];

    // ---- Layout ----
    [NSLayoutConstraint activateConstraints:@[
        [_toggleButton.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
        [_toggleButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_clearButton.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_clearButton.leadingAnchor constraintEqualToAnchor:_toggleButton.trailingAnchor constant:8],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [_scrollView.topAnchor constraintEqualToAnchor:_toggleButton.bottomAnchor constant:10],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_scrollView.heightAnchor constraintEqualToConstant:200],

        [_detailLabel.topAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:8],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailSegment.topAnchor constraintEqualToAnchor:_detailLabel.bottomAnchor constant:4],
        [_detailSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [_detailScrollView.topAnchor constraintEqualToAnchor:_detailSegment.bottomAnchor constant:4],
        [_detailScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_detailScrollView.heightAnchor constraintEqualToConstant:80],

        [_mockLabel.topAnchor constraintEqualToAnchor:_detailScrollView.bottomAnchor constant:8],
        [_mockLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],

        [_mockScrollView.topAnchor constraintEqualToAnchor:_mockLabel.bottomAnchor constant:4],
        [_mockScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_mockScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_mockScrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
    ]];
}

- (NSMenu *)createContextMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Mock This URL"
                                                  action:@selector(mockSelectedRequest:)
                                           keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return menu;
}

#pragma mark - Mock Actions

- (void)mockSelectedRequest:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_entries.count) return;
    [self openMockEditorWithEntry:_entries[row] fromMockList:NO];
}

- (void)openMockEditorWithEntry:(NSDictionary *)entry fromMockList:(BOOL)fromMockList {
    NSString *url = entry[@"url"];
    if ([url hasPrefix:@"[MOCK] "]) url = [url substringFromIndex:7];

    NSInteger statusCode;
    NSString *body;

    if (fromMockList) {
        _mockEditIndex = _mockTableView.clickedRow;
        statusCode = [entry[@"statusCode"] integerValue];
        body = entry[@"responseBody"];
    } else {
        _mockEditIndex = -1;
        for (NSInteger i = 0; i < (NSInteger)_mockRules.count; i++) {
            if ([_mockRules[i][@"url"] isEqualToString:url]) {
                _mockEditIndex = i;
                break;
            }
        }
        NSDictionary *existing = _mockEditIndex >= 0 ? _mockRules[_mockEditIndex] : nil;
        statusCode = existing ? [existing[@"statusCode"] integerValue] : [entry[@"statusCode"] integerValue];
        body = existing ? existing[@"responseBody"] : entry[@"responseBody"];
    }

    [self showMockEditSheetWithURL:url statusCode:statusCode body:body];
}

- (void)showMockEditSheetWithURL:(NSString *)url
                      statusCode:(NSInteger)statusCode
                            body:(NSString *)body {
    if (!_mockEditSheet) {
        [self createMockEditSheet];
    }
    _mockEditURLField.stringValue = url;
    _mockEditStatusField.stringValue = [NSString stringWithFormat:@"%ld", (long)(statusCode > 0 ? statusCode : 200)];
    _mockEditBodyView.string = body ?: @"";
    [self.view.window beginSheet:_mockEditSheet completionHandler:nil];
}

- (void)createMockEditSheet {
    NSRect frame = NSMakeRect(0, 0, 500, 350);
    _mockEditSheet = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                   backing:NSBackingStoreBuffered defer:NO];
    _mockEditSheet.title = @"Edit Mock Rule";

    NSView *cv = _mockEditSheet.contentView;

    NSTextField *urlLabel = [self labelWithString:@"URL:"];
    urlLabel.frame = NSMakeRect(16, frame.size.height - 30, 40, 18);
    [cv addSubview:urlLabel];

    _mockEditURLField = [[NSTextField alloc] initWithFrame:NSMakeRect(60, frame.size.height - 32, 424, 22)];
    _mockEditURLField.editable = NO;
    _mockEditURLField.font = [NSFont systemFontOfSize:11];
    [cv addSubview:_mockEditURLField];

    NSTextField *statusLabel = [self labelWithString:@"Status:"];
    statusLabel.frame = NSMakeRect(16, frame.size.height - 58, 50, 18);
    [cv addSubview:statusLabel];

    _mockEditStatusField = [[NSTextField alloc] initWithFrame:NSMakeRect(70, frame.size.height - 60, 60, 22)];
    _mockEditStatusField.font = [NSFont systemFontOfSize:11];
    [cv addSubview:_mockEditStatusField];

    NSTextField *bodyLabel = [self labelWithString:@"Response Body:"];
    bodyLabel.frame = NSMakeRect(16, frame.size.height - 90, 100, 18);
    [cv addSubview:bodyLabel];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 50, 468, frame.size.height - 145)];
    sv.borderType = NSBezelBorder; sv.hasVerticalScroller = YES;
    _mockEditBodyView = [[NSTextView alloc] initWithFrame:sv.bounds];
    _mockEditBodyView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    sv.documentView = _mockEditBodyView;
    [cv addSubview:sv];

    NSButton *saveBtn = [NSButton buttonWithTitle:@"保存" target:self action:@selector(saveMockRule:)];
    saveBtn.bezelStyle = NSBezelStyleRounded;
    saveBtn.frame = NSMakeRect(410, 12, 74, 28);
    [cv addSubview:saveBtn];

    NSButton *cancelBtn = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelMockEdit:)];
    cancelBtn.bezelStyle = NSBezelStyleRounded;
    cancelBtn.frame = NSMakeRect(330, 12, 74, 28);
    [cv addSubview:cancelBtn];
}

- (NSTextField *)labelWithString:(NSString *)s {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSZeroRect];
    l.stringValue = s; l.editable = NO; l.bordered = NO; l.selectable = NO;
    l.backgroundColor = [NSColor clearColor];
    l.font = [NSFont systemFontOfSize:11];
    return l;
}

- (void)saveMockRule:(id)sender {
    NSString *url = _mockEditURLField.stringValue;
    NSInteger statusCode = [_mockEditStatusField.stringValue integerValue];
    NSString *body = _mockEditBodyView.string;

    NSDictionary *rule = @{
        @"url": url,
        @"statusCode": @(statusCode > 0 ? statusCode : 200),
        @"responseHeaders": @"{}",
        @"responseBody": body ?: @"",
        @"enabled": @YES,
    };

    [self saveMockRuleToDB:rule];
    [self loadMockRulesFromDB];
    [self.mockTableView reloadData];
    [self updateStatusForConnection];

    // 同步到 iOS 端
    [self sendMessage:@"networkMock" content:@{
        @"action": @"add",
        @"url": url,
        @"statusCode": @(statusCode > 0 ? statusCode : 200),
        @"responseHeaders": @"{}",
        @"responseBody": body ?: @"",
        @"enabled": @YES,
    }];

    [self.view.window endSheet:_mockEditSheet];
    [_mockEditSheet orderOut:nil];
}

- (void)cancelMockEdit:(id)sender {
    [self.view.window endSheet:_mockEditSheet];
    [_mockEditSheet orderOut:nil];
}

- (void)editMockRule:(id)sender {
    NSInteger row = _mockTableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_mockRules.count) return;
    NSDictionary *rule = _mockRules[row];
    [self openMockEditorWithEntry:rule fromMockList:YES];
}

- (void)toggleMockEnabled:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)_mockRules.count) return;
    NSMutableDictionary *rule = [_mockRules[row] mutableCopy];
    BOOL newState = ![rule[@"enabled"] boolValue];
    rule[@"enabled"] = @(newState);
    _mockRules[row] = rule;

    [self saveMockRuleToDB:rule];
    [self.mockTableView reloadData];

    // 同步到 iOS
    if (newState) {
        [self sendMessage:@"networkMock" content:@{
            @"action": @"add", @"url": rule[@"url"],
            @"statusCode": rule[@"statusCode"], @"responseHeaders": rule[@"responseHeaders"],
            @"responseBody": rule[@"responseBody"], @"enabled": @YES,
        }];
    } else {
        [self sendMessage:@"networkMock" content:@{@"action": @"delete", @"url": rule[@"url"]}];
    }
}

- (void)deleteMockRule:(id)sender {
    NSInteger row = _mockTableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_mockRules.count) return;

    NSString *url = _mockRules[row][@"url"];
    [self deleteMockRuleFromDB:url];
    [self loadMockRulesFromDB];
    [self.mockTableView reloadData];

    [self sendMessage:@"networkMock" content:@{@"action": @"delete", @"url": url}];
    [self updateStatusForConnection];
}

#pragma mark - Actions

- (void)toggleMonitor:(NSButton *)sender {
    _isMonitoring = !_isMonitoring;
    NSString *action = _isMonitoring ? @"start" : @"stop";
    sender.title = _isMonitoring ? @"⏸ 停止" : @"▶ 开始";
    [self sendMessage:@"networkMonitor" content:@{@"action": action}];
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
            NSString *action = content[@"action"];
            if ([action isEqualToString:@"push"]) {
                NSDictionary *entry = content[@"entry"];
                if ([entry isKindOfClass:[NSDictionary class]]) {
                    [self.entries addObject:entry];
                    if (self.entries.count > 200) [self.entries removeObjectAtIndex:0];
                    [self.tableView insertRowsAtIndexes:[NSIndexSet indexSetWithIndex:self.entries.count - 1]
                                          withAnimation:NSTableViewAnimationEffectNone];
                    [self updateStatusForConnection];
                }
            }
            if (content[@"monitoring"]) {
                _isMonitoring = [content[@"monitoring"] boolValue];
            }
        } else if ([type isEqualToString:@"networkMock"]) {
            // mock 规则变更确认
            if ([content[@"success"] boolValue]) {
                NSLog(@"[Mock] iOS 端已同步: %@", content[@"action"]);
            }
        }
    });
}

#pragma mark - NSTableViewDataSource (shared by request list & mock list)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    if (tv == _mockTableView) return (NSInteger)_mockRules.count;
    return (NSInteger)_entries.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (tv == _mockTableView) return [self mockCellForColumn:col row:row];
    return [self requestCellForColumn:col row:row];
}

- (NSView *)requestCellForColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSDictionary *e = _entries[row];
    NSString *cid = col.identifier;
    NSString *text = @"";
    if ([cid isEqualToString:@"method"])   text = e[@"method"];
    else if ([cid isEqualToString:@"url"]) text = e[@"url"];
    else if ([cid isEqualToString:@"status"]) {
        NSInteger c = [e[@"statusCode"] integerValue];
        text = c > 0 ? [NSString stringWithFormat:@"%ld", (long)c] : @"…";
    } else if ([cid isEqualToString:@"duration"]) {
        text = [NSString stringWithFormat:@"%.0f ms", [e[@"duration"] doubleValue] * 1000];
    } else if ([cid isEqualToString:@"size"]) {
        NSUInteger req = [e[@"requestSize"] unsignedIntegerValue];
        NSUInteger resp = [e[@"responseSize"] unsignedIntegerValue];
        text = [self formatBytes:req + resp];
    }
    return [self cellWithText:text identifier:cid inTable:_tableView];
}

- (NSView *)mockCellForColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSDictionary *r = _mockRules[row];
    NSString *cid = col.identifier;
    NSString *text = @"";

    if ([cid isEqualToString:@"mock_enabled"]) {
        NSButton *btn = [_mockTableView makeViewWithIdentifier:cid owner:self];
        if (!btn) {
            btn = [[NSButton alloc] initWithFrame:NSZeroRect];
            btn.title = @"";
            btn.bezelStyle = NSBezelStyleRegularSquare;
            btn.bordered = NO;
            btn.identifier = cid;
        }
        btn.tag = row;
        btn.title = [r[@"enabled"] boolValue] ? @"✅" : @"⬜";
        btn.target = self;
        btn.action = @selector(toggleMockEnabled:);
        return btn;
    }

    if ([cid isEqualToString:@"mock_url"])      text = r[@"url"];
    else if ([cid isEqualToString:@"mock_status"]) text = [r[@"statusCode"] stringValue];
    return [self cellWithText:text identifier:cid inTable:_mockTableView];
}

- (NSTableCellView *)cellWithText:(NSString *)text identifier:(NSString *)cid inTable:(NSTableView *)tv {
    NSTableCellView *cell = [tv makeViewWithIdentifier:cid owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO; tf.bordered = NO; tf.selectable = NO;
        tf.backgroundColor = [NSColor clearColor];
        tf.font = [NSFont systemFontOfSize:11];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField = tf; [cell addSubview:tf];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        cell.identifier = cid;
    }
    cell.textField.stringValue = text;
    cell.textField.textColor = [NSColor textColor];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == _tableView) {
        NSInteger row = _tableView.selectedRow;
        if (row >= 0 && row < (NSInteger)_entries.count) [self showDetailForRow:row];
    }
}

#pragma mark - Detail

- (void)showDetailForRow:(NSInteger)row {
    _selectedEntry = _entries[row]; [self refreshDetail];
}
- (void)detailCategoryChanged:(NSSegmentedControl *)sender { _detailCategory = sender.selectedSegment; [self refreshDetail]; }
- (void)refreshDetail {
    if (!_selectedEntry) { self.detailTextView.string = @""; return; }
    NSDictionary *e = _selectedEntry;
    NSString *c = @"(empty)";
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
