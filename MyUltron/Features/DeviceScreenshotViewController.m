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
#import "MyUltronTheme.h"

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
    return [super initWithFeatureName:NSLocalizedString(@"设备截屏", nil)];
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    // 不调 [super viewDidLoad]，因为我们用 setupUI 完全自定义布局，
    // 不需要 FeatureViewController 的占位 label。
    self.view.wantsLayer = YES;
    self.view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
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
            self.statusLabel.stringValue = NSLocalizedString(@"已连接，点击截屏", nil);
            self.captureButton.enabled = YES;
        } else {
            self.statusLabel.stringValue = NSLocalizedString(@"未连接，请先在 iOS 设备上启动 App 并连接", nil);
            self.captureButton.enabled = NO;
        }
    });
}

#pragma mark - UI Setup

- (void)setupUI {
    // ---- 截图预览区域 ----
    _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _imageView.imageScaling     = NSImageScaleProportionallyUpOrDown;
    _imageView.wantsLayer = YES;
    _imageView.layer.cornerRadius = 8;
    _imageView.layer.borderWidth = 0.5;
    _imageView.layer.borderColor = [NSColor separatorColor].CGColor;
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_imageView];

    // ---- 截屏按钮 ----
    _captureButton = [NSButton buttonWithTitle:NSLocalizedString(@"截屏", nil)
                                        target:self
                                        action:@selector(captureScreenshot:)];
    _captureButton.bezelStyle = NSBezelStyleRounded;
    _captureButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_captureButton];

    // ---- 保存按钮 ----
    _saveButton = [NSButton buttonWithTitle:NSLocalizedString(@"保存", nil)
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
    _statusLabel.textColor  = [MyUltronTheme statusColor];
    _statusLabel.font       = [MyUltronTheme statusFont];
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
    // 按钮在底部：截屏(左) 保存(右)  状态标签(中上)
    // imageView 填满上部空间
    [NSLayoutConstraint activateConstraints:@[
        [_captureButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_captureButton.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor constant:-20],

        [_saveButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_saveButton.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor constant:-20],

        [_statusLabel.bottomAnchor constraintEqualToAnchor:_captureButton.topAnchor constant:-8],
        [_statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_spinner.leadingAnchor  constraintEqualToAnchor:_statusLabel.trailingAnchor constant:6],
        [_spinner.centerYAnchor  constraintEqualToAnchor:_statusLabel.centerYAnchor],

        [_imageView.topAnchor     constraintEqualToAnchor:self.view.topAnchor constant:20],
        [_imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_imageView.bottomAnchor  constraintEqualToAnchor:_statusLabel.topAnchor constant:-8],
    ]];
}

#pragma mark - Screenshot Capture (TCP)

- (void)captureScreenshot:(NSButton *)sender {
    if (!self.client.isConnected) {
        self.statusLabel.stringValue = NSLocalizedString(@"未连接，请先连接设备", nil);
        return;
    }

    sender.enabled = NO;
    self.saveButton.enabled = NO;
    self.statusLabel.stringValue = NSLocalizedString(@"正在截屏…", nil);
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
            self.statusLabel.stringValue = NSLocalizedString(@"截屏失败：收到空数据", nil);
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
                NSLocalizedString(@"截屏成功 — %.0f × %.0f 像素", nil), size.width, size.height];
        } else {
            self.statusLabel.stringValue = NSLocalizedString(@"截屏失败：无法解析图像数据", nil);
        }
    });
}

#pragma mark - Save Screenshot

- (void)saveScreenshot:(NSButton *)sender {
    if (!self.currentScreenshot) return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title                = NSLocalizedString(@"保存截屏", nil);
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
                        [NSString stringWithFormat:NSLocalizedString(@"保存失败: %@", nil), writeErr.localizedDescription];
                } else {
                    self.statusLabel.stringValue =
                        [NSString stringWithFormat:NSLocalizedString(@"已保存到 %@", nil), url.lastPathComponent];
                }
            });
        }
    }];
}

@end
