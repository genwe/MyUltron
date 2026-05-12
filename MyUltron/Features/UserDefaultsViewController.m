//
//  UserDefaultsViewController.m
//  MyUltron
//
//  NSUserDefaults browser — list, add, edit, delete keys on the connected device.
//

#import "UserDefaultsViewController.h"
#import "../ViewController.h"
#import "../Core/MyUltronClient.h"

static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

// ---- Entry model ----
@interface UDEntry : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *preview;
@end
@implementation UDEntry
@end

@interface UserDefaultsViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTextField   *statusLabel;
@property (nonatomic, strong) NSScrollView  *scrollView;
@property (nonatomic, strong) NSTableView   *tableView;
@property (nonatomic, strong) NSButton      *addButton;
@property (nonatomic, strong) NSButton      *editButton;
@property (nonatomic, strong) NSButton      *deleteButton;

@property (nonatomic, strong) NSMutableArray<UDEntry *> *entries;
@property (nonatomic, assign) BOOL loaded;

@end

@implementation UserDefaultsViewController

- (instancetype)init {
    self = [super initWithFeatureName:@"UserDefault数据"];
    if (self) {
        _entries = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildUI];
    if (self.client.isConnected) [self requestList];
    else [self setStatus:@"未连接"];
}

- (void)viewDidConnect { if (!self.loaded) [self requestList]; }

#pragma mark - UI

- (void)buildUI {
    CGFloat margin = 12;
    CGFloat y = self.view.bounds.size.height - 40;

    self.addButton = [self button:@"＋ 新增" x:margin y:y action:@selector(addKey:)];
    CGFloat x = NSMaxX(self.addButton.frame) + 8;
    self.editButton = [self button:@"✎ 编辑" x:x y:y action:@selector(editKey:)];
    x = NSMaxX(self.editButton.frame) + 8;
    self.deleteButton = [self button:@"✕ 删除" x:x y:y action:@selector(deleteKey:)];

    CGFloat tableTop = y - 8;
    NSRect tableFrame = NSMakeRect(margin, 32,
                                   self.view.bounds.size.width - margin * 2,
                                   tableTop - 32);
    self.scrollView = [[NSScrollView alloc] initWithFrame:tableFrame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.hasVerticalScroller = YES;

    self.tableView = [[NSTableView alloc] initWithFrame:self.scrollView.bounds];
    self.tableView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    for (NSDictionary *c in @[
        @{@"id":@"key",  @"title":@"Key",   @"w":@220},
        @{@"id":@"type", @"title":@"Type",  @"w":@80},
        @{@"id":@"val",  @"title":@"Value", @"w":@300},
    ]) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[@"id"]];
        col.title = c[@"title"];
        col.width = [c[@"w"] doubleValue];
        [self.tableView addTableColumn:col];
    }
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.doubleAction = @selector(tableViewDoubleClick:);
    self.tableView.target       = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.scrollView.documentView = self.tableView;
    [self.view addSubview:self.scrollView];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, 6, 400, 18)];
    self.statusLabel.editable = NO;
    self.statusLabel.bordered = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.view addSubview:self.statusLabel];
}

- (NSButton *)button:(NSString *)title x:(CGFloat)x y:(CGFloat)y action:(SEL)sel {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, 80, 26)];
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = self;
    b.action = sel;
    b.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:b];
    return b;
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.entries.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    UDEntry *e = self.entries[row];
    NSString *cid = column.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:cid owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = cid;
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO; tf.bordered = NO; tf.drawsBackground = NO;
        tf.font = [NSFont systemFontOfSize:12];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf]; cell.textField = tf;
    }
    NSString *v = @"";
    if ([cid isEqualToString:@"key"])  v = e.key;
    else if ([cid isEqualToString:@"type"]) v = e.type;
    else if ([cid isEqualToString:@"val"])  v = e.preview;
    cell.textField.stringValue = v;
    CGFloat rowH = tableView.rowHeight;
    cell.textField.frame = NSMakeRect(4, (rowH - 16) / 2, column.width - 8, 16);
    return cell;
}

- (void)tableViewDoubleClick:(id)sender { [self editKey:sender]; }

#pragma mark - Actions

- (void)addKey:(id)sender {
    [self showEditor:@"新增" key:@"" value:@"" type:@"String" handler:^(NSString *k, NSString *v, NSString *t) {
        [self setStatus:@"保存中..."];
        [self send:@"userDefaultsSet" content:@{@"key":k, @"value":v, @"type":t}];
    }];
}

- (void)editKey:(id)sender {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0) return;
    UDEntry *e = self.entries[row];
    [self showEditor:@"编辑" key:e.key value:e.preview type:e.type handler:^(NSString *k, NSString *v, NSString *t) {
        [self setStatus:@"保存中..."];
        [self send:@"userDefaultsSet" content:@{@"key":k, @"value":v, @"type":t}];
    }];
}

- (void)deleteKey:(id)sender {
    NSInteger row = self.tableView.selectedRow;
    if (row < 0) return;
    UDEntry *e = self.entries[row];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"删除 \"%@\" ?", e.key];
    a.alertStyle = NSAlertStyleWarning;
    [a addButtonWithTitle:@"删除"];
    [a addButtonWithTitle:@"取消"];
    [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) return;
        [self setStatus:@"删除中..."];
        [self send:@"userDefaultsDelete" content:@{@"key":e.key}];
    }];
}

- (void)showEditor:(NSString *)title
               key:(NSString *)preKey
             value:(NSString *)preVal
              type:(NSString *)preType
           handler:(void(^)(NSString *key, NSString *val, NSString *type))handler
{
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = title;
    [a addButtonWithTitle:@"确定"];
    [a addButtonWithTitle:@"取消"];

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 90)];

    NSTextField *kl = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 66, 40, 20)];
    kl.editable = NO; kl.bordered = NO; kl.drawsBackground = NO;
    kl.stringValue = @"Key:"; kl.font = [NSFont systemFontOfSize:12];
    [container addSubview:kl];

    NSTextField *kf = [[NSTextField alloc] initWithFrame:NSMakeRect(44, 64, 292, 22)];
    kf.stringValue = preKey;
    [container addSubview:kf];

    NSTextField *vl = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 36, 40, 20)];
    vl.editable = NO; vl.bordered = NO; vl.drawsBackground = NO;
    vl.stringValue = @"Val:"; vl.font = [NSFont systemFontOfSize:12];
    [container addSubview:vl];

    NSTextField *vf = [[NSTextField alloc] initWithFrame:NSMakeRect(44, 34, 200, 22)];
    vf.stringValue = preVal;
    [container addSubview:vf];

    NSTextField *tl = [[NSTextField alloc] initWithFrame:NSMakeRect(250, 36, 36, 20)];
    tl.editable = NO; tl.bordered = NO; tl.drawsBackground = NO;
    tl.stringValue = @"类型:"; tl.font = [NSFont systemFontOfSize:11];
    [container addSubview:tl];

    NSPopUpButton *typePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(250, 6, 86, 22)];
    [typePopup addItemsWithTitles:@[@"String", @"Number", @"Boolean", @"Date"]];
    NSInteger selIdx = [@[@"String",@"Number",@"Boolean",@"Date"] indexOfObject:preType];
    if (selIdx != NSNotFound) [typePopup selectItemAtIndex:selIdx];
    [container addSubview:typePopup];

    a.accessoryView = container;
    a.window.initialFirstResponder = kf;

    [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) return;
        if (kf.stringValue.length == 0) return;
        handler(kf.stringValue, vf.stringValue, typePopup.selectedItem.title);
    }];
}

#pragma mark - Communication

- (MyUltronClient *)client { return ((ViewController *)self.parentViewController).client; }
- (void)send:(NSString *)type content:(NSDictionary *)content {
    [self.client sendMessage:@{kMsgVersion:@"1.0", kMsgType:type, kMsgContent:content}];
}

- (void)requestList {
    [self setStatus:@"加载中..."];
    [self send:@"userDefaultsList" content:@{}];
}

#pragma mark - Message Handler

- (void)didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[kMsgType];
    NSDictionary *c = dict[kMsgContent];
    if ([type isEqualToString:@"userDefaultsList"]) {
        self.loaded = YES;
        [self.entries removeAllObjects];
        for (NSDictionary *d in c[@"keys"]) {
            UDEntry *e = [UDEntry new];
            e.key     = d[@"key"] ?: @"?";
            e.type    = d[@"type"] ?: @"?";
            e.preview = d[@"preview"] ?: @"";
            [self.entries addObject:e];
        }
        [self.tableView reloadData];
        [self setStatus:[NSString stringWithFormat:@"%lu keys", (unsigned long)self.entries.count]];
    } else if ([type isEqualToString:@"userDefaultsSet"]) {
        [self requestList];
    } else if ([type isEqualToString:@"userDefaultsDelete"]) {
        [self requestList];
    }
}

- (void)setStatus:(NSString *)t { self.statusLabel.stringValue = t; }

@end
