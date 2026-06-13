//
//  SandboxViewController.m
//  MyUltron
//
//  沙盒管理完整实现。
//  协议见底部注释。
//

#import "SandboxViewController.h"
#import "../ViewController.h"
#import "../Core/MyUltronClient.h"
#import "MyUltronTheme.h"

// ---- Message keys ----
static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

// ---- Sandbox message types ----
static NSString * const kTypeSandboxList      = @"sandboxList";
static NSString * const kTypeSandboxCreateDir = @"sandboxCreateDir";
static NSString * const kTypeSandboxDelete    = @"sandboxDelete";

// ---- Entry model ----
@interface SandboxEntry : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, assign) BOOL      isDir;
@property (nonatomic, assign) int64_t   size;
@property (nonatomic, copy)   NSString *modDate;
@end

@implementation SandboxEntry
@end

// ---- ViewController ----
@interface SandboxViewController () <NSTableViewDataSource, NSTableViewDelegate>

// Toolbar
@property (nonatomic, strong) NSTextField *pathField;
@property (nonatomic, strong) NSButton    *backButton;
@property (nonatomic, strong) NSButton    *refreshButton;
@property (nonatomic, strong) NSButton    *addFolderButton;
@property (nonatomic, strong) NSButton    *deleteButton;
@property (nonatomic, strong) NSButton    *uploadButton;
@property (nonatomic, strong) NSButton    *downloadButton;

// Table
@property (nonatomic, strong) NSScrollView  *scrollView;
@property (nonatomic, strong) NSTableView   *tableView;

// Status
@property (nonatomic, strong) NSTextField   *statusLabel;

// State
@property (nonatomic, copy)   NSString          *currentPath;
@property (nonatomic, strong) NSMutableArray<SandboxEntry *> *entries;
@property (nonatomic, strong) NSMutableArray<NSString *>    *pathHistory;
@property (nonatomic, assign) BOOL               loadingRequested;
@property (nonatomic, copy)   NSString          *pendingDownloadName;
@property (nonatomic, copy)   NSString          *pendingDownloadDir;

@end

@implementation SandboxViewController

- (instancetype)init {
    self = [super initWithFeatureName:NSLocalizedString(@"沙盒管理", nil)];
    if (self) {
        _entries     = [NSMutableArray array];
        _pathHistory = [NSMutableArray array];
        _currentPath = @"/";   // root of sandbox
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildUI];

    if (self.client.isConnected) {
        [self requestDirectoryListing];
    } else {
        [self setStatus:NSLocalizedString(NSLocalizedString(NSLocalizedString(@"未连接 — 请先选择设备 → 选择 App", nil), nil), nil)];
    }
}

- (void)viewDidConnect {
    // Only auto-request on first connect, not on re-connections
    if (!self.loadingRequested) {
        [self requestDirectoryListing];
    }
}

- (void)viewDidDisconnect {
    [self setStatus:NSLocalizedString(@"连接已断开", nil)];
}

#pragma mark - UI Construction

- (void)buildUI {
    CGFloat margin = [MyUltronTheme standardMargin];

    // ---- Path field ----
    self.pathField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.pathField.editable   = NO;
    self.pathField.bordered   = YES;
    self.pathField.bezelStyle = NSTextFieldSquareBezel;
    self.pathField.font       = [MyUltronTheme monospacedFont];
    self.pathField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pathField];

    // ---- Toolbar buttons (SF Symbols) ----
    self.backButton       = [MyUltronTheme symbolButton:@"arrow.left"        tooltip:NSLocalizedString(@"返回上级", nil)   target:self action:@selector(navigateUp:)];
    self.refreshButton    = [MyUltronTheme symbolButton:@"arrow.clockwise"   tooltip:NSLocalizedString(@"刷新", nil)       target:self action:@selector(refreshListing:)];
    self.addFolderButton  = [MyUltronTheme symbolButton:@"folder.badge.plus" tooltip:NSLocalizedString(@"新建文件夹", nil) target:self action:@selector(createFolder:)];
    self.deleteButton     = [MyUltronTheme symbolButton:@"trash"             tooltip:NSLocalizedString(@"删除", nil)       target:self action:@selector(deleteSelected:)];
    self.uploadButton     = [MyUltronTheme symbolButton:@"square.and.arrow.up"   tooltip:NSLocalizedString(@"上传", nil) target:self action:@selector(uploadFile:)];
    self.downloadButton   = [MyUltronTheme symbolButton:@"square.and.arrow.down" tooltip:NSLocalizedString(@"下载", nil) target:self action:@selector(downloadFile:)];

    for (NSButton *btn in @[self.backButton, self.refreshButton, self.addFolderButton,
                             self.deleteButton, self.uploadButton, self.downloadButton]) {
        [self.view addSubview:btn];
    }

    // ---- Stack the toolbar buttons horizontally ----
    NSStackView *toolbarStack = [NSStackView stackViewWithViews:@[
        self.pathField, self.backButton, self.refreshButton, self.addFolderButton,
        self.deleteButton, self.uploadButton, self.downloadButton
    ]];
    toolbarStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    toolbarStack.spacing = 6;
    toolbarStack.alignment = NSLayoutAttributeCenterY;
    toolbarStack.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbarStack setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.view addSubview:toolbarStack];

    // ---- Table view ----
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.allowsMultipleSelection = YES;

    NSArray *cols = @[
        @{@"id": @"type", @"title": NSLocalizedString(@"类型", nil),   @"w": @80},
        @{@"id": @"name", @"title": NSLocalizedString(@"名称", nil),   @"w": @200},
        @{@"id": @"size", @"title": NSLocalizedString(@"大小", nil),   @"w": @80},
        @{@"id": @"date", @"title": NSLocalizedString(@"修改时间", nil), @"w": @150},
    ];
    for (NSDictionary *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[@"id"]];
        col.title = c[@"title"];
        col.width = [c[@"w"] doubleValue];
        [self.tableView addTableColumn:col];
    }

    self.tableView.dataSource   = self;
    self.tableView.delegate     = self;
    self.tableView.doubleAction = @selector(tableViewDoubleClick:);
    self.tableView.target       = self;

    self.scrollView.documentView = self.tableView;
    [self.view addSubview:self.scrollView];

    // ---- Status bar ----
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.statusLabel.editable    = NO;
    self.statusLabel.bordered    = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.textColor   = [MyUltronTheme statusColor];
    self.statusLabel.font        = [MyUltronTheme statusFont];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    // ---- Auto Layout Constraints ----
    [NSLayoutConstraint activateConstraints:@[
        // Toolbar stack at top
        [toolbarStack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:margin],
        [toolbarStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [toolbarStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-margin],

        // Path field width
        [self.pathField.widthAnchor constraintEqualToConstant:320],

        // Table view fills remaining space
        [self.scrollView.topAnchor constraintEqualToAnchor:toolbarStack.bottomAnchor constant:8],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-margin],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-4],

        // Status bar at bottom
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:margin],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-6],
    ]];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.entries.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)column
                  row:(NSInteger)row
{
    SandboxEntry *e = self.entries[row];
    NSString *colID = column.identifier;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:colID owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = colID;

        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable          = NO;
        tf.bordered          = NO;
        tf.drawsBackground   = NO;
        tf.font              = [MyUltronTheme tableFont];
        tf.lineBreakMode     = NSLineBreakByTruncatingTail;
        tf.cell.truncatesLastVisibleLine = YES;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:tf];
        cell.textField = tf;

        CGFloat leadingPad = 6;
        if ([colID isEqualToString:@"type"]) {
            NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iv.imageScaling = NSImageScaleProportionallyDown;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:iv];
            cell.imageView = iv;
            leadingPad = 24;

            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [iv.widthAnchor constraintEqualToConstant:16],
                [iv.heightAnchor constraintEqualToConstant:16],
            ]];
        }

        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:leadingPad],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    NSString *value = @"";
    if ([colID isEqualToString:@"name"])  value = e.name;
    else if ([colID isEqualToString:@"size"])  value = e.isDir ? @"--" : [self formatSize:e.size];
    else if ([colID isEqualToString:@"type"])  value = e.isDir ? NSLocalizedString(@"文件夹", nil) : [e.name pathExtension];
    else if ([colID isEqualToString:@"date"])  value = e.modDate ?: @"--";

    cell.textField.stringValue = value;

    // Icon only for type column
    if ([colID isEqualToString:@"type"]) {
        NSImage *icon = e.isDir
            ? [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericFolderIcon)]
            : [[NSWorkspace sharedWorkspace] iconForFileType:(__bridge NSString *)kUTTypeData];
        icon.size = NSMakeSize(16, 16);
        cell.imageView.image = icon;
    }

    return cell;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return [MyUltronTheme tableRowHeight];
}

#pragma mark - Table View Actions

- (void)tableViewDoubleClick:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.entries.count) return;

    SandboxEntry *e = self.entries[row];
    if (e.isDir) {
        [self.pathHistory addObject:self.currentPath];
        self.currentPath = e.path;
        [self requestDirectoryListing];
    }
}

#pragma mark - Toolbar Actions

- (void)navigateUp:(id)sender {
    if (self.pathHistory.count == 0) return;
    self.currentPath = self.pathHistory.lastObject;
    [self.pathHistory removeLastObject];
    [self requestDirectoryListing];
}

- (void)refreshListing:(id)sender {
    [self requestDirectoryListing];
}

- (void)createFolder:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"新建文件夹", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"创建", nil)];
    [alert addButtonWithTitle:NSLocalizedString(NSLocalizedString(@"取消", nil), nil)];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    input.placeholderString = NSLocalizedString(@"文件夹名称", nil);
    alert.accessoryView = input;

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn || input.stringValue.length == 0) return;
        NSString *dirPath = [self.currentPath stringByAppendingPathComponent:input.stringValue];
        [self sendMessage:kTypeSandboxCreateDir content:@{@"path": dirPath}];
    }];
}

- (void)deleteSelected:(id)sender {
    NSIndexSet *rows = self.tableView.selectedRowIndexes;
    if (rows.count == 0) return;

    __block NSString *itemList = @"";
    __block NSUInteger count = 0;
    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (count++ < 3) {
            itemList = [itemList stringByAppendingFormat:@"\n%@", self.entries[idx].name];
        }
    }];
    if (rows.count > 3) {
        itemList = [itemList stringByAppendingFormat:NSLocalizedString(@"\n... 等 %lu 项", nil), (unsigned long)rows.count];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"确认删除", nil);
    alert.informativeText = [NSString stringWithFormat:NSLocalizedString(@"将删除:%@", nil), itemList];
    [alert addButtonWithTitle:NSLocalizedString(@"删除", nil)];
    [alert addButtonWithTitle:NSLocalizedString(NSLocalizedString(@"取消", nil), nil)];
    alert.alertStyle = NSAlertStyleWarning;

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) return;
        [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            [self sendMessage:kTypeSandboxDelete
                      content:@{@"path": self.entries[idx].path}];
        }];
        // Refresh after a short delay to let the server process deletions
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self requestDirectoryListing];
        });
    }];
}

- (void)uploadFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles          = YES;
    panel.canChooseDirectories    = YES;
    panel.allowsMultipleSelection = YES;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) {
            NSLog(@"[Sandbox] 上传: %@", url.path);
            // TODO: implement binary file transfer
            // [self uploadItemAtPath:url.path toRemoteDir:self.currentPath];
        }
    }];
}

- (void)downloadFile:(id)sender {
    NSIndexSet *rows = self.tableView.selectedRowIndexes;
    if (rows.count == 0) return;

    // Pick a single entry for simplicity
    SandboxEntry *e = self.entries[rows.firstIndex];

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = e.name;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *localPath = panel.URL.path;

        // Store pending download info
        self.pendingDownloadName = e.name;
        self.pendingDownloadDir  = [localPath stringByDeletingLastPathComponent];

        // Send download request to the server
        [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"下载中: %@ ...", nil), e.name]];
        [self sendMessage:@"sandboxDownload" content:@{@"path": e.path}];
    }];
}

#pragma mark - Communication

- (MyUltronClient *)client {
    return ((ViewController *)self.parentViewController).client;
}

- (void)sendMessage:(NSString *)type content:(NSDictionary *)content {
    if (!self.client.isConnected) {
        [self setStatus:NSLocalizedString(NSLocalizedString(NSLocalizedString(@"未连接 — 请先选择设备 → 选择 App", nil), nil), nil)];
        return;
    }
    [self.client sendMessage:@{
        kMsgVersion: @"1.0",
        kMsgType:    type,
        kMsgContent: content,
    }];
}

- (void)requestDirectoryListing {
    if (!self.client.isConnected) {
        [self setStatus:NSLocalizedString(NSLocalizedString(NSLocalizedString(@"未连接 — 请先选择设备 → 选择 App", nil), nil), nil)];
        return;
    }

    self.loadingRequested = YES;
    [self.pathField setStringValue:self.currentPath];
    self.entries = [NSMutableArray array];
    [self.tableView reloadData];
    [self setStatus:NSLocalizedString(@"加载中...", nil)];

    NSLog(@"[Sandbox] Requesting listing for: %@ (connected=%d)",
          self.currentPath, self.client.isConnected);
    [self sendMessage:kTypeSandboxList content:@{@"path": self.currentPath}];
}

#pragma mark - Message Handler

- (void)didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[kMsgType];
    NSDictionary *content = dict[kMsgContent];
    NSLog(@"[Sandbox] ← received messageType: %@", type);

    if ([type isEqualToString:kTypeSandboxList]) {
        [self handleListResponse:content];
    } else if ([type isEqualToString:kTypeSandboxCreateDir]) {
        [self handleCreateDirResponse:content];
    } else if ([type isEqualToString:kTypeSandboxDelete]) {
        [self handleDeleteResponse:content];
    } else if ([type isEqualToString:@"sandboxDownload"]) {
        [self handleDownloadResponse:content];
    }
}

- (void)handleDownloadResponse:(NSDictionary *)content {
    BOOL success = [content[@"success"] boolValue];
    if (!success) {
        [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"下载失败: %@", nil), content[@"error"] ?: @"未知"]];
        self.pendingDownloadName = nil;
        return;
    }
    // Binary data will arrive in didReceiveBinaryData:
    // The JSON response here just confirms the file was found on the server.
}

- (void)didReceiveBinaryData:(NSData *)data {
    if (!self.pendingDownloadName || !self.pendingDownloadDir) return;

    NSString *filePath = [self.pendingDownloadDir stringByAppendingPathComponent:self.pendingDownloadName];
    NSError *error = nil;
    BOOL ok = [data writeToFile:filePath options:NSDataWritingAtomic error:&error];
    if (ok) {
        [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"已下载: %@", nil), self.pendingDownloadName]];
    } else {
        [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"保存失败: %@", nil), error.localizedDescription]];
    }
    self.pendingDownloadName = nil;
    self.pendingDownloadDir  = nil;
}

- (void)handleListResponse:(NSDictionary *)content {
    NSString *path = content[@"path"];
    NSArray *rawEntries = content[@"entries"];

    // Ignore responses for old requests (race condition)
    if (![path isEqualToString:self.currentPath]) return;

    [self.entries removeAllObjects];

    for (NSDictionary *d in rawEntries) {
        SandboxEntry *e = [[SandboxEntry alloc] init];
        e.name    = d[@"name"]    ?: @"?";
        e.path    = d[@"path"]    ?: [path stringByAppendingPathComponent:e.name];
        e.isDir   = [d[@"isDir"] boolValue];
        e.size    = [d[@"size"] longLongValue];
        e.modDate = d[@"modDate"];
        [self.entries addObject:e];
    }

    // Sort: directories first, then alphabetically
    [self.entries sortUsingComparator:^NSComparisonResult(SandboxEntry *a, SandboxEntry *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        return [a.name compare:b.name options:NSCaseInsensitiveSearch];
    }];

    [self.tableView reloadData];
    [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"%lu 个项目", nil), (unsigned long)self.entries.count]];
}

- (void)handleCreateDirResponse:(NSDictionary *)content {
    BOOL success = [content[@"success"] boolValue];
    if (success) {
        [self requestDirectoryListing];
    } else {
        [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"创建失败: %@", nil), content[@"error"] ?: NSLocalizedString(NSLocalizedString(@"未知错误", nil), nil)]];
    }
}

- (void)handleDeleteResponse:(NSDictionary *)content {
    BOOL success = [content[@"success"] boolValue];
    if (success) {
        [self requestDirectoryListing];
    } else {
        [self setStatus:[NSString stringWithFormat:NSLocalizedString(@"删除失败: %@", nil), content[@"error"] ?: NSLocalizedString(NSLocalizedString(@"未知错误", nil), nil)]];
    }
}

#pragma mark - Helpers

- (NSString *)formatSize:(int64_t)bytes {
    if (bytes < 1024)           return [NSString stringWithFormat:@"%lld B", bytes];
    if (bytes < 1024 * 1024)    return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    if (bytes < 1024*1024*1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0*1024.0)];
    return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0*1024.0*1024.0)];
}

- (void)setStatus:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = text;
    });
}

@end

/*
 ──────────────────────────────────────────
  沙盒通信协议 (Sandbox Protocol)
 ──────────────────────────────────────────

 1. 列出目录
    REQ: { messageType:"sandboxList", content:{ path:"/Documents" } }
    RES: { messageType:"sandboxList", content:{
            path:"/Documents",
            entries:[
              { name:"file.txt", path:"/Documents/file.txt", isDir:false,
                size:1024, modDate:"2026-05-11 10:00:00" },
              { name:"subdir",   path:"/Documents/subdir",   isDir:true,
                size:0,    modDate:"..." }
            ]
          }}

 2. 新建文件夹
    REQ: { messageType:"sandboxCreateDir", content:{ path:"/Documents/new" } }
    RES: { messageType:"sandboxCreateDir", content:{ path:"/Documents/new",
            success:true, error:"" }}

 3. 删除
    REQ: { messageType:"sandboxDelete", content:{ path:"/Documents/file.txt" } }
    RES: { messageType:"sandboxDelete", content:{ path:"/Documents/file.txt",
            success:true, error:"" }}

 4. 上传 / 下载 (预留，待实现二进制传输)
    REQ: { messageType:"sandboxDownload", content:{ path:"..." } }
    RES: binary packet (file data)
    REQ: binary packet (file data + { path, filename })
    RES: { messageType:"sandboxUpload", content:{ success:true } }
 ──────────────────────────────────────────
 */
