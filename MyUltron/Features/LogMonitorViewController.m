//
//  LogMonitorViewController.m
//  MyUltron
//
//  通过 libimobiledevice syslog_relay 实时显示设备系统日志，
//  可按 Bundle ID / 进程名过滤。
//

#import "LogMonitorViewController.h"
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/syslog_relay.h>

@interface LogMonitorViewController () <NSTextFieldDelegate>

@property (nonatomic, strong) NSTextView   *textView;
@property (nonatomic, strong) NSTextField  *filterField;
@property (nonatomic, strong) NSButton     *startStopBtn;
@property (nonatomic, strong) NSButton     *clearBtn;
@property (nonatomic, strong) NSButton     *autoScrollBtn;
@property (nonatomic, assign) BOOL          autoScroll;
@property (nonatomic, assign) BOOL          running;
@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, copy)   NSString     *deviceUDID;

@end

@implementation LogMonitorViewController

+ (BOOL)requiresConnection { return YES; }
+ (BOOL)requiresApp      { return YES; }

- (instancetype)init {
    return [super initWithFeatureName:@"日志监控"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _autoScroll = YES;
    [self setupUI];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self stopCapture];
}

- (void)setupUI {
    CGFloat y = self.view.bounds.size.height - 12;

    // Filter field
    _filterField = [[NSTextField alloc] initWithFrame:NSMakeRect(8, y - 26, 160, 24)];
    _filterField.placeholderString = @"过滤 (bundleID)…";
    _filterField.font = [NSFont systemFontOfSize:12];
    _filterField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_filterField];

    // Start/Stop button
    _startStopBtn = [NSButton buttonWithTitle:@"▶ 开始" target:self action:@selector(toggleCapture:)];
    _startStopBtn.frame = NSMakeRect(174, y - 26, 80, 26);
    _startStopBtn.bezelStyle = NSBezelStyleRounded;
    _startStopBtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_startStopBtn];

    // Clear button
    _clearBtn = [NSButton buttonWithTitle:@"清空" target:self action:@selector(clearLog:)];
    _clearBtn.frame = NSMakeRect(260, y - 26, 60, 26);
    _clearBtn.bezelStyle = NSBezelStyleRounded;
    _clearBtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_clearBtn];

    // Auto scroll toggle
    _autoScrollBtn = [NSButton buttonWithTitle:@"自动滚屏" target:self action:@selector(toggleAutoScroll:)];
    _autoScrollBtn.frame = NSMakeRect(326, y - 26, 90, 26);
    [_autoScrollBtn setButtonType:NSButtonTypeSwitch];
    _autoScrollBtn.state = NSControlStateValueOn;
    _autoScrollBtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:_autoScrollBtn];

    // Log text view
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(8, 8, self.view.bounds.size.width - 16, y - 42)];
    sv.borderType = NSBezelBorder; sv.hasVerticalScroller = YES;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;
    [self.view addSubview:sv];

    _textView = [[NSTextView alloc] initWithFrame:sv.bounds];
    _textView.editable = NO;
    _textView.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    _textView.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1.0];
    _textView.textColor = [NSColor colorWithRed:0.4 green:1.0 blue:0.4 alpha:1.0];
    _textView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _textView.string = @"点击 ▶ 开始捕获日志\n";
    sv.documentView = _textView;
}

- (void)toggleCapture:(id)sender {
    if (_running) {
        [self stopCapture];
    } else {
        [self startCapture];
    }
}

- (void)startCapture {
    if (_running) return;
    _running = YES;
    _startStopBtn.title = @"■ 停止";
    _textView.string = @"正在连接设备…\n";

    const char *udid = _deviceUDID.UTF8String ?: "";
    NSString *filter = _filterField.stringValue;

    self.captureQueue = dispatch_queue_create("com.myultron.syslog", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.captureQueue, ^{
        idevice_t device = NULL;
        if (idevice_new_with_options(&device, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:@"[错误] 无法连接设备"]; [self stopCapture]; });
            return;
        }

        syslog_relay_client_t syslog = NULL;
        syslog_relay_error_t serr = syslog_relay_client_start_service(device, &syslog, "MyUltron");
        if (serr != SYSLOG_RELAY_E_SUCCESS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendLog:[NSString stringWithFormat:@"[错误] syslog_relay 启动失败: %d", serr]];
                [self stopCapture];
            });
            idevice_free(device);
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLog:@"[信息] 已连接，等待日志…"];
            if (filter.length > 0) [self appendLog:[NSString stringWithFormat:@"[信息] 过滤器: %@", filter]];
        });

        // Read loop
        char buf[8192];
        while (self->_running) {
            uint32_t recvd = 0;
            serr = syslog_relay_receive_with_timeout(syslog, buf, sizeof(buf) - 1, &recvd, 1000);
            if (serr != SYSLOG_RELAY_E_SUCCESS && serr != SYSLOG_RELAY_E_TIMEOUT) break;
            if (recvd == 0) continue;

            buf[recvd] = '\0';
            NSString *raw = @(buf);

            // Split by newlines and filter
            NSArray *lines = [raw componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length == 0) continue;
                if (filter.length > 0 && [trimmed rangeOfString:filter options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:trimmed]; });
            }
        }

        syslog_relay_client_free(syslog);
        idevice_free(device);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendLog:@"[信息] 日志流已断开"];
            [self stopCapture];
        });
    });
}

- (void)stopCapture {
    _running = NO;
    _startStopBtn.title = @"▶ 开始";
    _captureQueue = nil;
}

- (void)appendLog:(NSString *)line {
    NSColor *green = [NSColor colorWithRed:0.4 green:1.0 blue:0.4 alpha:1.0];
    // Keep last ~3000 lines
    NSArray *lines = [_textView.string componentsSeparatedByString:@"\n"];
    if (lines.count > 3000) {
        NSAttributedString *trimmed = [[NSAttributedString alloc]
            initWithString:[[lines subarrayWithRange:NSMakeRange(lines.count - 2500, 2500)] componentsJoinedByString:@"\n"]
            attributes:@{NSForegroundColorAttributeName: green, NSFontAttributeName: _textView.font}];
        [_textView.textStorage setAttributedString:trimmed];
    }
    NSAttributedString *as = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"\n%@", line]
        attributes:@{NSForegroundColorAttributeName: green, NSFontAttributeName: _textView.font}];
    [_textView.textStorage appendAttributedString:as];
    if (_autoScroll) [_textView scrollRangeToVisible:NSMakeRange(_textView.string.length, 0)];
}

- (void)clearLog:(id)sender {
    _textView.typingAttributes = @{NSForegroundColorAttributeName: _textView.textColor,
                                    NSFontAttributeName: _textView.font};
    _textView.string = @"";
}
- (void)toggleAutoScroll:(NSButton *)btn { _autoScroll = (btn.state == NSControlStateValueOn); }

// Auto-receive TCP log messages when connected to app
- (void)didReceiveMessage:(NSDictionary *)dict {
    if ([dict[@"messageType"] isEqualToString:@"log"]) {
        NSString *msg = dict[@"content"][@"message"];
        if (msg) dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:msg]; });
    }
}

@end
