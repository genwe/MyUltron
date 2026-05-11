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

@end

@implementation SandboxViewController

- (instancetype)init {
    self = [super initWithFeatureName:@"沙盒管理"];
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
        [self setStatus:@"未连接 — 请先选择设备 → 选择 App"];
    }
}

- (void)viewDidConnect {
    // Only auto-request on first connect, not on re-connections
    if (!self.loadingRequested) {
        [self requestDirectoryListing];
    }
}

- (void)viewDidDisconnect {
    [self setStatus:@"连接已断开"];
}

#pragma mark - UI Construction

- (void)buildUI {
    CGFloat margin = 12;
    CGFloat btnW   = 28;
    CGFloat y      = self.view.bounds.size.height - 36;

    // ---- Path field ----
    self.pathField = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, y, 320, 24)];
    self.pathField.editable   = NO;
    self.pathField.bordered   = YES;
    self.pathField.bezelStyle = NSTextFieldSquareBezel;
    self.pathField.font       = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.pathField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:self.pathField];

    CGFloat x = NSMaxX(self.pathField.frame) + 6;
    y += 1;

    // ---- Back (up) button ----
    self.backButton = [self buttonWithSymbol:@"←" title:@"返回" x:&x y:y];
    self.backButton.action = @selector(navigateUp:);

    // ---- Refresh ----
    self.refreshButton = [self buttonWithSymbol:@"↻" title:@"刷新" x:&x y:y];
    self.refreshButton.action = @selector(refreshListing:);

    // ---- New folder ----
    self.addFolderButton = [self buttonWithSymbol:@"＋" title:@"新建文件夹" x:&x y:y];
    self.addFolderButton.action = @selector(createFolder:);

    // ---- Delete ----
    self.deleteButton = [self buttonWithSymbol:@"✕" title:@"删除选中" x:&x y:y];
    self.deleteButton.action = @selector(deleteSelected:);

    x += 8;

    // ---- Upload ----
    self.uploadButton = [self buttonWithSymbol:@"↑" title:@"上传" x:&x y:y];
    self.uploadButton.action = @selector(uploadFile:);

    // ---- Download ----
    self.downloadButton = [self buttonWithSymbol:@"↓" title:@"下载" x:&x y:y];
    self.downloadButton.action = @selector(downloadFile:);

    // ---- Table view ----
    CGFloat tableTop = y - 8;
    NSRect tableFrame = NSMakeRect(margin, 32,
                                   self.view.bounds.size.width - margin * 2,
                                   tableTop - 32);

    self.scrollView = [[NSScrollView alloc] initWithFrame:tableFrame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.borderType       = NSBezelBorder;
    self.scrollView.hasVerticalScroller = YES;

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSArray *cols = @[
        @{@"id": @"name", @"title": @"名称",   @"w": @200},
        @{@"id": @"size", @"title": @"大小",   @"w": @80},
        @{@"id": @"type", @"title": @"类型",   @"w": @80},
        @{@"id": @"date", @"title": @"修改时间", @"w": @150},
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
    self.tableView.allowsMultipleSelection = YES;

    self.scrollView.documentView = self.tableView;
    [self.view addSubview:self.scrollView];

    // ---- Status bar ----
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, 6, 400, 18)];
    self.statusLabel.editable    = NO;
    self.statusLabel.bordered    = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.textColor   = [NSColor secondaryLabelColor];
    self.statusLabel.font        = [NSFont systemFontOfSize:11];
    self.statusLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.view addSubview:self.statusLabel];
}

- (NSButton *)buttonWithSymbol:(NSString *)sym
                         title:(NSString *)tooltip
                             x:(CGFloat *)x
                             y:(CGFloat)y
{
    NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(*x, y, 28, 24)];
    btn.title          = sym;
    btn.toolTip        = tooltip;
    btn.bezelStyle     = NSBezelStyleSmallSquare;
    btn.bordered       = NO;
    btn.font           = [NSFont systemFontOfSize:14];
    btn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:btn];
    *x += 30;
    return btn;
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
        tf.font              = [NSFont systemFontOfSize:12];
        tf.lineBreakMode     = NSLineBreakByTruncatingTail;
        tf.cell.truncatesLastVisibleLine = YES;
        [cell addSubview:tf];
        cell.textField = tf;
    }

    NSString *value = @"";
    if ([colID isEqualToString:@"name"])  value = e.name;
    else if ([colID isEqualToString:@"size"])  value = e.isDir ? @"--" : [self formatSize:e.size];
    else if ([colID isEqualToString:@"type"])  value = e.isDir ? @"文件夹" : [e.name pathExtension];
    else if ([colID isEqualToString:@"date"])  value = e.modDate ?: @"--";

    cell.textField.stringValue = value;

    // Constrain text field to column width
    CGFloat iconPad = ([colID isEqualToString:@"name"]) ? 22.0 : 4.0;
    CGFloat colW    = column.width;
    CGFloat rowH    = tableView.rowHeight;
    cell.textField.frame = NSMakeRect(iconPad, 0, colW - iconPad - 4, rowH);

    // Icon only for name column
    if ([colID isEqualToString:@"name"]) {
        NSImage *icon = e.isDir
            ? [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericFolderIcon)]
            : [[NSWorkspace sharedWorkspace] iconForFileType:(__bridge NSString *)kUTTypeData];
        icon.size = NSMakeSize(16, 16);
        cell.imageView.image = icon;
        cell.imageView.frame = NSMakeRect(2, (rowH - 16) / 2, 16, 16);
    }

    return cell;
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
    alert.messageText = @"新建文件夹";
    [alert addButtonWithTitle:@"创建"];
    [alert addButtonWithTitle:@"取消"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    input.placeholderString = @"文件夹名称";
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
        itemList = [itemList stringByAppendingFormat:@"\n... 等 %lu 项", (unsigned long)rows.count];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"确认删除";
    alert.informativeText = [NSString stringWithFormat:@"将删除:%@", itemList];
    [alert addButtonWithTitle:@"删除"];
    [alert addButtonWithTitle:@"取消"];
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

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles          = NO;
    panel.canChooseDirectories    = YES;
    panel.canCreateDirectories    = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt                  = @"保存到此目录";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *localDir = panel.URL.path;
        [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            SandboxEntry *e = self.entries[idx];
            NSLog(@"[Sandbox] 下载: %@ → %@", e.path, localDir);
            // TODO: implement binary file transfer
            // [self downloadItemAtPath:e.path toLocalDir:localDir];
        }];
    }];
}

#pragma mark - Communication

- (MyUltronClient *)client {
    return ((ViewController *)self.parentViewController).client;
}

- (void)sendMessage:(NSString *)type content:(NSDictionary *)content {
    if (!self.client.isConnected) {
        [self setStatus:@"未连接 — 请先选择设备 → 选择 App"];
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
        [self setStatus:@"未连接 — 请先选择设备 → 选择 App"];
        return;
    }

    self.loadingRequested = YES;
    [self.pathField setStringValue:self.currentPath];
    self.entries = [NSMutableArray array];
    [self.tableView reloadData];
    [self setStatus:@"加载中..."];

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
    }
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
    [self setStatus:[NSString stringWithFormat:@"%lu 个项目", (unsigned long)self.entries.count]];
}

- (void)handleCreateDirResponse:(NSDictionary *)content {
    BOOL success = [content[@"success"] boolValue];
    if (success) {
        [self requestDirectoryListing];
    } else {
        [self setStatus:[NSString stringWithFormat:@"创建失败: %@", content[@"error"] ?: @"未知错误"]];
    }
}

- (void)handleDeleteResponse:(NSDictionary *)content {
    BOOL success = [content[@"success"] boolValue];
    if (success) {
        [self requestDirectoryListing];
    } else {
        [self setStatus:[NSString stringWithFormat:@"删除失败: %@", content[@"error"] ?: @"未知错误"]];
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
