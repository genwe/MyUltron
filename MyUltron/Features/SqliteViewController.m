//
//  SqliteViewController.m
//  MyUltron
//
//  SQLite 数据库浏览器：选择沙盒中的 .db 文件 → 浏览表 → 查看/编辑数据。
//

#import "SqliteViewController.h"
#import "../Core/MyUltronClient.h"
#import "../ViewController.h"

@interface SqliteViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSPopUpButton *dbSelector;
@property (nonatomic, strong) NSPopUpButton *tableSelector;
@property (nonatomic, strong) NSScrollView  *scrollView;
@property (nonatomic, strong) NSTableView   *tableView;
@property (nonatomic, strong) NSButton      *refreshBtn;
@property (nonatomic, strong) NSButton      *addRowBtn;
@property (nonatomic, strong) NSButton      *deleteRowBtn;
@property (nonatomic, strong) NSTextField   *statusLabel;

@property (nonatomic, copy) NSString        *selectedDB;
@property (nonatomic, copy) NSString        *selectedTable;
@property (nonatomic, strong) NSArray<NSString *> *columns;
@property (nonatomic, strong) NSMutableArray<NSMutableArray *> *rows;

@end

@implementation SqliteViewController

+ (BOOL)requiresConnection { return YES; }
+ (BOOL)requiresApp      { return YES; }

- (instancetype)init {
    return [super initWithFeatureName:@"Sqlite"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _rows = [NSMutableArray array];
    _columns = @[];
    [self setupUI];
    // If already connected when this panel is shown, load DB list immediately
    if ([self.parentViewController isKindOfClass:[ViewController class]]) {
        MyUltronClient *c = [(ViewController *)self.parentViewController client];
        if (c.isConnected) {
            [self sendListDBs];
        }
    }
}

- (void)viewDidConnect {
    [self sendListDBs];
}

#pragma mark - UI

- (void)setupUI {
    CGFloat y = self.view.bounds.size.height - 36;

    _dbSelector = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(8, y, 200, 24)];
    [_dbSelector addItemWithTitle:@"选择数据库…"]; _dbSelector.target = self; _dbSelector.action = @selector(dbChanged:);
    _dbSelector.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_dbSelector];

    _tableSelector = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(216, y, 180, 24)];
    [_tableSelector addItemWithTitle:@"选择表…"]; _tableSelector.target = self; _tableSelector.action = @selector(tableChanged:);
    _tableSelector.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_tableSelector];

    _refreshBtn = [NSButton buttonWithTitle:@"刷新" target:self action:@selector(refreshData:)];
    _refreshBtn.frame = NSMakeRect(404, y, 70, 26);
    _refreshBtn.bezelStyle = NSBezelStyleRounded;
    _refreshBtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_refreshBtn];

    _addRowBtn = [NSButton buttonWithTitle:@"+ 行" target:self action:@selector(addRow:)];
    _addRowBtn.frame = NSMakeRect(480, y, 60, 26);
    _addRowBtn.bezelStyle = NSBezelStyleRounded;
    _addRowBtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_addRowBtn];

    _deleteRowBtn = [NSButton buttonWithTitle:@"- 行" target:self action:@selector(deleteRow:)];
    _deleteRowBtn.frame = NSMakeRect(546, y, 60, 26);
    _deleteRowBtn.bezelStyle = NSBezelStyleRounded;
    _deleteRowBtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_deleteRowBtn];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 8, 400, 18)];
    _statusLabel.editable = NO; _statusLabel.bordered = NO; _statusLabel.drawsBackground = NO;
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.stringValue = @"请先连接设备并选择数据库";
    _statusLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.view addSubview:_statusLabel];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 34, self.view.bounds.size.width - 16, y - 48)];
    sv.borderType = NSBezelBorder; sv.hasVerticalScroller = YES; sv.hasHorizontalScroller = YES;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;
    [self.view addSubview:sv];
    _scrollView = sv;

    _tableView = [[NSTableView alloc] initWithFrame:sv.bounds];
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    sv.documentView = _tableView;
}

#pragma mark - Network

- (void)sendMessage:(NSDictionary *)dict {
    if ([self.parentViewController isKindOfClass:[ViewController class]]) {
        [[(ViewController *)self.parentViewController client] sendMessage:dict];
    }
}

- (void)sendListDBs {
    _statusLabel.stringValue = @"正在加载数据库列表…";
    [self sendMessage:@{@"messageType": @"sqliteListDBs", @"version": @"1.0", @"content": @{}}];
}

- (void)sendGetTables {
    [self sendMessage:@{@"messageType": @"sqliteGetTables", @"version": @"1.0",
                        @"content": @{@"database": _selectedDB ?: @""}}];
}

- (void)sendQuery {
    [self sendMessage:@{@"messageType": @"sqliteQuery", @"version": @"1.0",
                        @"content": @{@"database": _selectedDB ?: @"", @"table": _selectedTable ?: @""}}];
}

#pragma mark - Did Receive Message

- (void)didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[@"messageType"];
    NSDictionary *content = dict[@"content"];

    if ([type isEqualToString:@"sqliteListDBs"]) {
        [self handleDBList:content];
    } else if ([type isEqualToString:@"sqliteGetTables"]) {
        [self handleTables:content];
    } else if ([type isEqualToString:@"sqliteQuery"]) {
        [self handleQueryResult:content];
    } else if ([type isEqualToString:@"sqliteExecute"]) {
        [self handleExecuteResult:content];
    }
}

- (void)handleDBList:(NSDictionary *)content {
    NSArray *dbs = content[@"databases"];
    [_dbSelector removeAllItems];
    [_dbSelector addItemWithTitle:@"选择数据库…"];
    if ([dbs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *db in dbs) {
            NSString *name = db[@"name"];
            NSNumber *size = db[@"size"];
            [_dbSelector addItemWithTitle:[NSString stringWithFormat:@"%@  (%@)", name, [self formatSize:size]]];
            _dbSelector.lastItem.representedObject = name;
        }
    }
    _statusLabel.stringValue = dbs.count > 0 ? [NSString stringWithFormat:@"共 %lu 个数据库", (unsigned long)dbs.count] : @"无数据库文件";
}

- (void)handleTables:(NSDictionary *)content {
    NSArray *tables = content[@"tables"];
    [_tableSelector removeAllItems];
    [_tableSelector addItemWithTitle:@"选择表…"];
    self.selectedTable = nil;
    if ([tables isKindOfClass:[NSArray class]]) {
        for (NSDictionary *t in tables) {
            [_tableSelector addItemWithTitle:t[@"name"]];
        }
    }
    _statusLabel.stringValue = [NSString stringWithFormat:@"%@ — %lu 个表", _selectedDB, (unsigned long)tables.count];
}

- (void)handleQueryResult:(NSDictionary *)content {
    NSArray *cols = content[@"columns"];
    NSArray *data = content[@"rows"];
    _columns = [cols isKindOfClass:[NSArray class]] ? cols : @[];
    _rows = [NSMutableArray array];
    if ([data isKindOfClass:[NSArray class]]) {
        for (NSArray *row in data) {
            [_rows addObject:[NSMutableArray arrayWithArray:row]];
        }
    }
    [self rebuildTableColumns];
    [_tableView reloadData];
    _statusLabel.stringValue = [NSString stringWithFormat:@"%@ · %@ — %lu 行", _selectedDB, _selectedTable, (unsigned long)_rows.count];
}

- (void)handleExecuteResult:(NSDictionary *)content {
    BOOL ok = [content[@"success"] boolValue];
    if (ok) {
        _statusLabel.stringValue = @"操作成功";
        [self sendQuery]; // refresh
    } else {
        _statusLabel.stringValue = [NSString stringWithFormat:@"错误: %@", content[@"error"] ?: @"未知"];
    }
}

#pragma mark - Table columns

- (void)rebuildTableColumns {
    for (NSTableColumn *col in _tableView.tableColumns.copy) {
        [_tableView removeTableColumn:col];
    }
    for (NSString *name in _columns) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:name];
        col.title = name;
        col.width = MAX(80, (CGFloat)name.length * 10 + 40);
        col.minWidth = 60;
        col.resizingMask = NSTableColumnUserResizingMask;
        [_tableView addTableColumn:col];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_rows.count;
}

- (nullable NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_rows.count) return nil;

    NSString *ident = [col.identifier stringByAppendingString:@"Cell"];
    NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = YES; tf.bordered = NO; tf.drawsBackground = NO;
        tf.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.target = self;
        tf.action = @selector(cellEdited:);
        [cell addSubview:tf];
        cell.textField = tf;
    }
    NSInteger colIdx = [_columns indexOfObject:col.identifier];
    if (row >= 0 && row < (NSInteger)_rows.count) {
        NSArray *r = _rows[row];
        if (colIdx != NSNotFound && colIdx < (NSInteger)r.count) {
            id val = r[colIdx];
            cell.textField.stringValue = [val isKindOfClass:[NSNull class]] ? @"NULL" : [val description];
        } else {
            cell.textField.stringValue = @"";
        }
    } else {
        cell.textField.stringValue = @"";
    }
    CGFloat rh = tv.rowHeight;
    cell.textField.frame = NSMakeRect(4, (rh - 16) / 2, col.width - 8, 16);
    return cell;
}

- (void)cellEdited:(NSTextField *)sender {
    NSInteger row = [_tableView rowForView:sender];
    NSInteger col = [_tableView columnForView:sender];
    if (row < 0 || col < 0) return;
    if (row >= (NSInteger)_rows.count) return;
    NSArray *rowData = _rows[row];
    if (col >= (NSInteger)rowData.count) return;
    if (col >= (NSInteger)_columns.count) return;

    // Use id column (column 0) as the row identifier for UPDATE
    id rowId = rowData.firstObject;
    if ([rowId isKindOfClass:[NSNull class]] || !rowId) {
        _statusLabel.stringValue = @"无法获取行标识";
        return;
    }

    NSString *newVal = sender.stringValue;
    _rows[row][col] = newVal;

    NSString *colName = _columns[col];
    NSString *escaped = [newVal stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSString *sql = [NSString stringWithFormat:@"UPDATE \"%@\" SET \"%@\" = '%@' WHERE %@ = %@",
                     _selectedTable, colName, escaped, _columns[0], rowId];
    [self sendMessage:@{@"messageType": @"sqliteExecute", @"version": @"1.0",
                        @"content": @{@"database": _selectedDB ?: @"", @"sql": sql}}];
}

#pragma mark - NSTableViewDelegate

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row { return 24; }

#pragma mark - Actions

- (void)dbChanged:(NSPopUpButton *)sender {
    if (sender.indexOfSelectedItem == 0) return;
    _selectedDB = sender.selectedItem.representedObject ?: sender.selectedItem.title;
    [self sendGetTables];
}

- (void)tableChanged:(NSPopUpButton *)sender {
    if (sender.indexOfSelectedItem == 0) return;
    _selectedTable = sender.selectedItem.title;
    [self sendQuery];
}

- (void)refreshData:(id)sender {
    if (_selectedTable) [self sendQuery];
    else if (_selectedDB) [self sendGetTables];
    else [self sendListDBs];
}

- (void)addRow:(id)sender {
    if (!_selectedTable || _columns.count == 0) return;

    // Filter out auto-increment id column for INSERT
    NSMutableArray<NSString *> *insertCols = [NSMutableArray array];
    for (NSString *col in _columns) {
        if ([col compare:@"id" options:NSCaseInsensitiveSearch] != NSOrderedSame) {
            [insertCols addObject:col];
        }
    }
    if (insertCols.count == 0) {
        _statusLabel.stringValue = @"该表无可插入字段";
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"新增数据行";
    alert.informativeText = [NSString stringWithFormat:@"表: %@", _selectedTable];
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];

    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, insertCols.count * 30 + 10)];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < insertCols.count; i++) {
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, i * 30 + 5, 80, 22)];
        label.editable = NO; label.bordered = NO; label.drawsBackground = NO;
        label.stringValue = insertCols[i];
        label.font = [NSFont boldSystemFontOfSize:12];
        [form addSubview:label];

        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(88, i * 30 + 2, 200, 24)];
        field.placeholderString = [NSString stringWithFormat:@"输入 %@ …", insertCols[i]];
        [form addSubview:field];
        [fields addObject:field];
    }
    alert.accessoryView = form;

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) return;

        NSMutableArray *vals = [NSMutableArray arrayWithCapacity:fields.count];
        for (NSTextField *f in fields) {
            NSString *escaped = [f.stringValue stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
            [vals addObject:[NSString stringWithFormat:@"'%@'", escaped]];
        }
        NSString *cols = [insertCols componentsJoinedByString:@", "];
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO \"%@\" (%@) VALUES (%@)",
                         _selectedTable, cols, [vals componentsJoinedByString:@", "]];
        [self sendMessage:@{@"messageType": @"sqliteExecute", @"version": @"1.0",
                            @"content": @{@"database": _selectedDB ?: @"", @"sql": sql}}];
    }];
}

- (void)deleteRow:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || !_selectedTable) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"确认删除";
    alert.informativeText = [NSString stringWithFormat:@"删除表 \"%@\" 中第 %ld 行数据？此操作不可撤销。", _selectedTable, (long)row + 1];
    [alert addButtonWithTitle:@"删除"];
    [alert addButtonWithTitle:@"取消"];
    alert.alertStyle = NSAlertStyleWarning;

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) return;
        // Use id column (column 0) as the row identifier for DELETE
        id rowId = _rows[row].firstObject;
        if ([rowId isKindOfClass:[NSNull class]] || !rowId) {
            _statusLabel.stringValue = @"无法获取行标识";
            return;
        }
        NSString *sql = [NSString stringWithFormat:@"DELETE FROM \"%@\" WHERE %@ = %@", _selectedTable, _columns[0], rowId];
        [self sendMessage:@{@"messageType": @"sqliteExecute", @"version": @"1.0",
                            @"content": @{@"database": _selectedDB ?: @"", @"sql": sql}}];
    }];
}

- (NSString *)formatSize:(NSNumber *)bytes {
    long long b = bytes.longLongValue;
    if (b < 1024) return [NSString stringWithFormat:@"%lld B", b];
    if (b < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", b / (1024.0 * 1024.0)];
}

@end
