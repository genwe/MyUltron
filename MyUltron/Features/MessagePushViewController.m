//
//  MessagePushViewController.m
//  MyUltron
//
//  模拟远程推送：Mac 端编辑 aps JSON → 发送到 iOS 端 →
//  iOS 端调用 AppDelegate 的 didReceiveRemoteNotification: 方法。
//

#import "MessagePushViewController.h"
#import "../ViewController.h"
#import "../Core/MyUltronClient.h"
#import "MyUltronTheme.h"

static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

static NSString * const kDefaultPayload =
@"{\n"
@"  \"aps\": {\n"
@"    \"alert\": {\n"
@"      \"title\": \"推送标题\",\n"
@"      \"body\": \"推送内容\"\n"
@"    },\n"
@"    \"badge\": 1,\n"
@"    \"sound\": \"default\"\n"
@"  }\n"
@"}";

@interface MessagePushViewController ()

@property (nonatomic, strong) NSScrollView       *scrollView;
@property (nonatomic, strong) NSTextView         *textView;
@property (nonatomic, strong) NSButton           *sendButton;
@property (nonatomic, strong) NSTextField        *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;

@end

@implementation MessagePushViewController

#pragma mark - Init

+ (BOOL)requiresApp { return YES; }

- (instancetype)init {
    return [super initWithFeatureName:NSLocalizedString(@"消息推送", nil)];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [self setupUI];
    [self updateStatusForConnection];
}

- (void)viewDidConnect {
    [super viewDidConnect];
    [self updateStatusForConnection];
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
            self.statusLabel.stringValue = NSLocalizedString(@"已连接，编辑 JSON 后点击发送", nil);
            self.sendButton.enabled = YES;
        } else {
            self.statusLabel.stringValue = NSLocalizedString(@"未连接，请先在 iOS 设备上启动 App 并连接", nil);
            self.sendButton.enabled = NO;
        }
    });
}

#pragma mark - UI Setup

- (void)setupUI {
    // ---- 输入区域标题 ----
    NSTextField *inputLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    inputLabel.stringValue = NSLocalizedString(@"推送 Payload (JSON):", nil);
    inputLabel.editable = NO;
    inputLabel.bordered = NO;
    inputLabel.selectable = NO;
    inputLabel.backgroundColor = [NSColor clearColor];
    inputLabel.font = [MyUltronTheme tableBoldFont];
    inputLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:inputLabel];

    // ---- JSON 输入框（可滚动的多行 NSTextView） ----
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.hasVerticalScroller = YES;
    _scrollView.borderType = NSBezelBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    _textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _textView.font = [MyUltronTheme monospacedFont];
    _textView.string = kDefaultPayload;
    _textView.backgroundColor = [NSColor textBackgroundColor];
    _textView.textColor = [NSColor textColor];
    _textView.insertionPointColor = [NSColor textColor];
    _textView.automaticQuoteSubstitutionEnabled = NO;
    _textView.automaticDashSubstitutionEnabled = NO;

    _scrollView.documentView = _textView;
    [self.view addSubview:_scrollView];

    // ---- 发送按钮 ----
    _sendButton = [NSButton buttonWithTitle:NSLocalizedString(@"发送", nil)
                                     target:self
                                     action:@selector(sendPush:)];
    _sendButton.bezelStyle = NSBezelStyleRounded;
    _sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_sendButton];

    // ---- 状态标签 ----
    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO;
    _statusLabel.bordered = NO;
    _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor = [MyUltronTheme statusColor];
    _statusLabel.font = [MyUltronTheme statusFont];
    _statusLabel.stringValue = NSLocalizedString(@"正在检测连接…", nil);
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_statusLabel];

    // ---- 加载指示器 ----
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_spinner];

    // ---- Auto Layout ----
    [NSLayoutConstraint activateConstraints:@[
        [inputLabel.topAnchor     constraintEqualToAnchor:self.view.topAnchor    constant:20],
        [inputLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [inputLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_scrollView.topAnchor      constraintEqualToAnchor:inputLabel.bottomAnchor constant:8],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_scrollView.heightAnchor   constraintEqualToConstant:200],

        [_sendButton.topAnchor     constraintEqualToAnchor:_scrollView.bottomAnchor constant:16],
        [_sendButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_statusLabel.topAnchor      constraintEqualToAnchor:_sendButton.bottomAnchor constant:12],
        [_statusLabel.centerXAnchor  constraintEqualToAnchor:self.view.centerXAnchor],

        [_spinner.leadingAnchor  constraintEqualToAnchor:_statusLabel.trailingAnchor constant:6],
        [_spinner.centerYAnchor  constraintEqualToAnchor:_statusLabel.centerYAnchor],
    ]];
}

#pragma mark - Send

- (void)sendPush:(NSButton *)sender {
    if (!self.client.isConnected) {
        self.statusLabel.stringValue = NSLocalizedString(@"未连接，请先连接设备", nil);
        return;
    }

    NSString *jsonText = self.textView.string;
    if (jsonText.length == 0) {
        self.statusLabel.stringValue = NSLocalizedString(@"请输入 JSON payload", nil);
        return;
    }

    NSData *jsonData = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || ![payload isKindOfClass:[NSDictionary class]]) {
        self.statusLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"JSON 格式错误: %@", nil), error.localizedDescription];
        return;
    }

    sender.enabled = NO;
    self.statusLabel.stringValue = NSLocalizedString(@"正在发送…", nil);
    [self.spinner startAnimation:nil];

    [self sendMessage:@"messagePush" content:payload];
}

- (void)sendMessage:(NSString *)type content:(NSDictionary *)content {
    [self.client sendMessage:@{
        kMsgVersion: @"1.0",
        kMsgType:    type,
        kMsgContent: content,
    }];
}

#pragma mark - Receive Response

- (void)didReceiveMessage:(NSDictionary *)dict {
    NSString *type = dict[kMsgType];
    if (![type isEqualToString:@"messagePush"]) return;

    NSDictionary *content = dict[kMsgContent];
    BOOL success = [content[@"success"] boolValue];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimation:nil];
        self.sendButton.enabled = YES;

        if (success) {
            self.statusLabel.stringValue = NSLocalizedString(@"推送已送达 AppDelegate", nil);
        } else {
            NSString *err = content[@"error"] ?: NSLocalizedString(@"未知错误", nil);
            self.statusLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"发送失败: %@", nil), err];
        }
    });
}

@end
