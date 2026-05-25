//
//  DeviceScreenshotViewController.m
//  MyUltron
//
//  通过 MyUltronServer TCP 通道截取 iOS app 画面。
//  Mac → 发送 screenshot 请求 → iOS 端截屏 → PNG 二进制回传 → 显示。
//

#import "DeviceScreenshotViewController.h"
#import "../ViewController.h"
#import "../Core/MyUltronClient.h"

static NSString * const kMsgVersion = @"version";
static NSString * const kMsgType    = @"messageType";
static NSString * const kMsgContent = @"content";

@interface DeviceScreenshotViewController ()

@property (nonatomic, strong) NSImageView       *imageView;
@property (nonatomic, strong) NSButton          *captureButton;
@property (nonatomic, strong) NSButton          *saveButton;
@property (nonatomic, strong) NSTextField       *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) NSImage           *currentScreenshot;
@property (nonatomic, strong) NSLayoutConstraint *imageHeightConstraint;

@end

@implementation DeviceScreenshotViewController

#pragma mark - Init

+ (BOOL)requiresApp { return YES; }   // 需要 TCP 连接到运行中的 iOS app

- (instancetype)init {
    return [super initWithFeatureName:@"设备截屏"];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    // 不调 [super viewDidLoad]，因为我们用 setupUI 完全自定义布局，
    // 不需要 FeatureViewController 的占位 label。
    self.view.wantsLayer = YES;
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
            self.statusLabel.stringValue = @"已连接，点击截屏";
            self.captureButton.enabled = YES;
        } else {
            self.statusLabel.stringValue = @"未连接，请先在 iOS 设备上启动 App 并连接";
            self.captureButton.enabled = NO;
        }
    });
}

#pragma mark - UI Setup

- (void)setupUI {
    self.view.wantsLayer = YES;

    // ---- 截图预览区域 ----
    _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _imageView.imageScaling     = NSImageScaleProportionallyUpOrDown;
    _imageView.imageFrameStyle  = NSImageFrameGrayBezel;
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_imageView];

    // ---- 截屏按钮 ----
    _captureButton = [NSButton buttonWithTitle:@"截屏"
                                        target:self
                                        action:@selector(captureScreenshot:)];
    _captureButton.bezelStyle = NSBezelStyleRounded;
    _captureButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_captureButton];

    // ---- 保存按钮 ----
    _saveButton = [NSButton buttonWithTitle:@"保存"
                                     target:self
                                     action:@selector(saveScreenshot:)];
    _saveButton.bezelStyle = NSBezelStyleRounded;
    _saveButton.enabled = NO;
    _saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_saveButton];

    // ---- 状态标签 ----
    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable   = NO;
    _statusLabel.bordered   = NO;
    _statusLabel.selectable = NO;
    _statusLabel.backgroundColor = [NSColor clearColor];
    _statusLabel.textColor  = [NSColor secondaryLabelColor];
    _statusLabel.font       = [NSFont systemFontOfSize:12];
    _statusLabel.stringValue = @"正在检测连接…";
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
        [_imageView.topAnchor     constraintEqualToAnchor:self.view.topAnchor    constant:20],
        [_imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_imageView.bottomAnchor  constraintLessThanOrEqualToAnchor:_captureButton.topAnchor constant:-16],

        [_captureButton.topAnchor     constraintEqualToAnchor:_imageView.bottomAnchor constant:16],
        [_captureButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_statusLabel.topAnchor      constraintEqualToAnchor:_captureButton.bottomAnchor constant:12],
        [_statusLabel.centerXAnchor  constraintEqualToAnchor:self.view.centerXAnchor],

        [_spinner.leadingAnchor  constraintEqualToAnchor:_statusLabel.trailingAnchor constant:6],
        [_spinner.centerYAnchor  constraintEqualToAnchor:_statusLabel.centerYAnchor],

        [_saveButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_saveButton.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor constant:-20],
    ]];
}

#pragma mark - Screenshot Capture (TCP)

- (void)captureScreenshot:(NSButton *)sender {
    if (!self.client.isConnected) {
        self.statusLabel.stringValue = @"未连接，请先连接设备";
        return;
    }

    sender.enabled = NO;
    self.saveButton.enabled = NO;
    self.statusLabel.stringValue = @"正在截屏…";
    [self.spinner startAnimation:nil];

    NSLog(@"[ScreenshotMac] Sending screenshot request via TCP...");
    [self sendMessage:@"screenshot" content:@{}];
}

- (void)sendMessage:(NSString *)type content:(NSDictionary *)content {
    [self.client sendMessage:@{
        kMsgVersion: @"1.0",
        kMsgType:    type,
        kMsgContent: content,
    }];
}

#pragma mark - Receiving Binary Screenshot Data

/// 接收到 iOS 端回传的 PNG 二进制数据。
- (void)didReceiveBinaryData:(NSData *)data {
    NSLog(@"[ScreenshotMac] didReceiveBinaryData: %lu bytes", (unsigned long)(data ? data.length : 0));

    if (!data || data.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimation:nil];
            self.captureButton.enabled = YES;
            self.statusLabel.stringValue = @"截屏失败：收到空数据";
        });
        return;
    }

    NSImage *image = [[NSImage alloc] initWithData:data];
    NSLog(@"[ScreenshotMac] NSImage created: %@, size: %@", image, image ? NSStringFromSize(image.size) : @"nil");

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimation:nil];
        self.captureButton.enabled = YES;

        if (image) {
            self.currentScreenshot = image;
            self.imageView.image = image;
            [self.imageView setNeedsDisplay:YES];
            self.saveButton.enabled = YES;
            NSSize size = image.size;
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"截屏成功 — %.0f × %.0f 像素", size.width, size.height];
        } else {
            self.statusLabel.stringValue = @"截屏失败：无法解析图像数据";
        }
    });
}

#pragma mark - Save Screenshot

- (void)saveScreenshot:(NSButton *)sender {
    if (!self.currentScreenshot) return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title                = @"保存截屏";
    panel.nameFieldStringValue = @"Screenshot.png";
    panel.allowedFileTypes     = @[@"png", @"jpg", @"jpeg"];

    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSURL *url = panel.URL;
        NSString *ext = url.pathExtension.lowercaseString;

        CGImageRef cgImage = [self.currentScreenshot CGImageForProposedRect:NULL
                                                                    context:nil
                                                                      hints:nil];
        if (!cgImage) return;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        NSData *imageData = nil;

        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
            imageData = [rep representationUsingType:NSBitmapImageFileTypeJPEG
                                          properties:@{NSImageCompressionFactor: @0.85}];
        } else {
            imageData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                          properties:@{}];
        }

        if (imageData) {
            NSError *writeErr = nil;
            [imageData writeToURL:url options:NSDataWritingAtomic error:&writeErr];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (writeErr) {
                    self.statusLabel.stringValue =
                        [NSString stringWithFormat:@"保存失败: %@", writeErr.localizedDescription];
                } else {
                    self.statusLabel.stringValue =
                        [NSString stringWithFormat:@"已保存到 %@", url.lastPathComponent];
                }
            });
        }
    }];
}

@end
