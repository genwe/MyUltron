//
//  NetworkMonitorViewController.m
//  MyUltron
//
//  网络监控 — 通过 TCP 从 iOS 端拉取请求列表，NSTableView 展示。
//

#import "NetworkMonitorViewController.h"
#import "../ViewController.h"
#import "../Core/MyUltronClient.h"

static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

@interface NetworkMonitorViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTableView       *tableView;
@property (nonatomic, strong) NSScrollView      *scrollView;
@property (nonatomic, strong) NSButton          *toggleButton;
@property (nonatomic, strong) NSButton          *clearButton;
@property (nonatomic, strong) NSButton          *refreshButton;
@property (nonatomic, strong) NSTextField       *statusLabel;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *entries;
@property (nonatomic, assign) BOOL               isMonitoring;

// Detail area
@property (nonatomic, strong) NSTextField       *detailLabel;
@property (nonatomic, strong) NSScrollView      *detailScrollView;
@property (nonatomic, strong) NSTextView        *detailTextView;

@end

@implementation NetworkMonitorViewController

#pragma mark - Init

+ (BOOL)requiresApp { return YES; }

- (instancetype)init {
    self = [super initWithFeatureName:@"网络监控"];
    if (self) {
        _entries = [NSMutableArray array];
        _isMonitoring = YES;
    }
    return self;
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    self.view.wantsLayer = YES;
    [self setupUI];
    [self updateStatusForConnection];
    // 拉取已有请求列表（后续增量由实时推送驱动）
    [self fetchData];
}

- (void)viewDidConnect {
    [super viewDidConnect];
    [self updateStatusForConnection];
    [self fetchData];
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
            self.statusLabel.stringValue = [NSString stringWithFormat:@"已连接 | %lu 条请求",
                                            (unsigned long)self.entries.count];
            self.toggleButton.enabled = YES;
            self.refreshButton.enabled = YES;
            self.clearButton.enabled = YES;
        } else {
            self.statusLabel.stringValue = @"未连接";
            self.toggleButton.enabled = NO;
            self.refreshButton.enabled = NO;
            self.clearButton.enabled = NO;
        }
    });
}

#pragma mark - UI

- (void)setupUI {
    // ---- 按钮栏 ----
    _toggleButton = [NSButton buttonWithTitle:@"⏸ 停止"
                                       target:self
                                       action:@selector(toggleMonitor:)];
    _toggleButton.bezelStyle = NSBezelStyleRounded;
    _toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_toggleButton];

    _clearButton = [NSButton buttonWithTitle:@"清空"
                                      target:self
                                      action:@selector(clearEntries:)];
    _clearButton.bezelStyle = NSBezelStyleRounded;
    _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_clearButton];

    _refreshButton = [NSButton buttonWithTitle:@"刷新"
                                        target:self
                                        action:@selector(fetchData)];
    _refreshButton.bezelStyle = NSBezelStyleRounded;
    _refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_refreshButton];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO;
    _statusLabel.bordered = NO;
    _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.stringValue = @"正在检测连接…";
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    // ---- 请求列表 Table ----
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.borderType = NSBezelBorder;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.usesAlternatingRowBackgroundColors = YES;

    // Columns: Method | URL | Status | Duration | Size
    NSArray *cols = @[
        @{@"id": @"method",   @"title": @"Method",  @"width": @60},
        @{@"id": @"url",      @"title": @"URL",     @"width": @280},
        @{@"id": @"status",   @"title": @"Status",  @"width": @55},
        @{@"id": @"duration", @"title": @"Duration", @"width": @70},
        @{@"id": @"size",     @"title": @"Size",    @"width": @70},
    ];
    for (NSDictionary *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[@"id"]];
        col.title = c[@"title"];
        col.width = [c[@"width"] doubleValue];
        [_tableView addTableColumn:col];
    }

    _scrollView.documentView = _tableView;
    [self.view addSubview:_scrollView];

    // ---- 详情区域 ----
    _detailLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _detailLabel.stringValue = @"请求详情：";
    _detailLabel.editable = NO;
    _detailLabel.bordered = NO;
    _detailLabel.selectable = NO;
    _detailLabel.backgroundColor = [NSColor clearColor];
    _detailLabel.font = [NSFont boldSystemFontOfSize:11];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_detailLabel];

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

    // ---- Auto Layout ----
    [NSLayoutConstraint activateConstraints:@[
        [_toggleButton.topAnchor     constraintEqualToAnchor:self.view.topAnchor constant:12],
        [_toggleButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],

        [_clearButton.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_clearButton.leadingAnchor constraintEqualToAnchor:_toggleButton.trailingAnchor constant:8],

        [_refreshButton.centerYAnchor constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_refreshButton.leadingAnchor constraintEqualToAnchor:_clearButton.trailingAnchor constant:8],

        [_statusLabel.centerYAnchor  constraintEqualToAnchor:_toggleButton.centerYAnchor],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [_scrollView.topAnchor      constraintEqualToAnchor:_toggleButton.bottomAnchor constant:10],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_scrollView.heightAnchor   constraintEqualToConstant:220],

        [_detailLabel.topAnchor     constraintEqualToAnchor:_scrollView.bottomAnchor constant:10],
        [_detailLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],

        [_detailScrollView.topAnchor      constraintEqualToAnchor:_detailLabel.bottomAnchor constant:4],
        [_detailScrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_detailScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_detailScrollView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
    ]];
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
    self.detailTextView.string = @"";
    [self sendMessage:@"networkMonitor" content:@{@"action": @"clear"}];
    [self updateStatusForConnection];
}

- (void)fetchData {
    if (!self.client.isConnected) return;
    [self sendMessage:@"networkMonitor" content:@{@"action": @"fetch"}];
}

#pragma mark - Messaging

- (void)sendMessage:(NSString *)type content:(NSDictionary *)content {
    [self.client sendMessage:@{
        kMsgVersion: @"1.0",
        kMsgType:    type,
        kMsgContent: content,
    }];
}

- (void)didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[kMsgType];
    if (![type isEqualToString:@"networkMonitor"]) return;

    NSDictionary *content = dict[kMsgContent];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *action = content[@"action"];

        if ([action isEqualToString:@"push"]) {
            // 实时推送：增量追加单条，不刷新整个列表
            NSDictionary *entry = content[@"entry"];
            if ([entry isKindOfClass:[NSDictionary class]]) {
                [self.entries addObject:entry];
                if (self.entries.count > 200) {
                    [self.entries removeObjectAtIndex:0];
                }
                [self.tableView insertRowsAtIndexes:[NSIndexSet indexSetWithIndex:self.entries.count - 1]
                                      withAnimation:NSTableViewAnimationEffectNone];
                [self updateStatusForConnection];
            }
        } else {
            // fetch / start / stop：全量替换
            if (![content[@"success"] boolValue]) return;

            NSArray *newEntries = content[@"entries"];
            if (![newEntries isKindOfClass:[NSArray class]]) return;

            self.isMonitoring = [content[@"monitoring"] boolValue];

            [self.entries removeAllObjects];
            [self.entries addObjectsFromArray:newEntries];
            [self.tableView reloadData];
            [self updateStatusForConnection];

            NSInteger sel = self.tableView.selectedRow;
            if (sel >= 0 && sel < (NSInteger)self.entries.count) {
                [self showDetailForRow:sel];
            }
        }
    });
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)self.entries.count;
}

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row {
    NSDictionary *entry = self.entries[row];
    NSString *colID = col.identifier;
    NSString *text = @"";

    if ([colID isEqualToString:@"method"]) {
        text = entry[@"method"];
    } else if ([colID isEqualToString:@"url"]) {
        text = entry[@"url"];
    } else if ([colID isEqualToString:@"status"]) {
        NSInteger code = [entry[@"statusCode"] integerValue];
        text = code > 0 ? [NSString stringWithFormat:@"%ld", (long)code] : @"…";
    } else if ([colID isEqualToString:@"duration"]) {
        double dur = [entry[@"duration"] doubleValue];
        text = [NSString stringWithFormat:@"%.0f ms", dur * 1000];
    } else if ([colID isEqualToString:@"size"]) {
        NSUInteger reqS = [entry[@"requestSize"] unsignedIntegerValue];
        NSUInteger respS = [entry[@"responseSize"] unsignedIntegerValue];
        text = [self formatBytes:reqS + respS];
    }

    NSTableCellView *cell = [tv makeViewWithIdentifier:colID owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO;
        tf.bordered = NO;
        tf.selectable = NO;
        tf.backgroundColor = [NSColor clearColor];
        tf.font = [NSFont systemFontOfSize:11];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField = tf;
        [cell addSubview:tf];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        cell.identifier = colID;
    }
    cell.textField.stringValue = text;

    // Color status code
    if ([colID isEqualToString:@"status"]) {
        NSInteger code = [entry[@"statusCode"] integerValue];
        if (code >= 200 && code < 300) {
            cell.textField.textColor = [NSColor systemGreenColor];
        } else if (code >= 400) {
            cell.textField.textColor = [NSColor systemRedColor];
        } else {
            cell.textField.textColor = [NSColor secondaryLabelColor];
        }
    } else {
        cell.textField.textColor = [NSColor textColor];
    }

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.tableView.selectedRow;
    if (row >= 0 && row < (NSInteger)self.entries.count) {
        [self showDetailForRow:row];
    }
}

#pragma mark - Detail

- (void)showDetailForRow:(NSInteger)row {
    NSDictionary *e = self.entries[row];
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ %@\n", e[@"method"], e[@"url"]];
    [s appendFormat:@"Status: %@ | Duration: %.0f ms | Req: %@ | Resp: %@\n\n",
     e[@"statusCode"], [e[@"duration"] doubleValue] * 1000,
     [self formatBytes:[e[@"requestSize"] unsignedIntegerValue]],
     [self formatBytes:[e[@"responseSize"] unsignedIntegerValue]]];
    [s appendFormat:@"--- Request Headers ---\n%@\n\n", e[@"requestHeaders"]];
    [s appendFormat:@"--- Response Headers ---\n%@\n", e[@"responseHeaders"]];
    self.detailTextView.string = s;
}

#pragma mark - Helpers

- (NSString *)formatBytes:(NSUInteger)bytes {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lu B", (unsigned long)bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
}

@end
