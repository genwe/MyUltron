//
//  DeviceScreenshotViewController.m
//  MyUltron
//
//  使用 libimobiledevice 直接从 iOS 设备获取截屏。
//  通过 USB/WiFi 连接设备 → lockdown 配对 → screenshotr 服务 → 截取屏幕。
//
//  编译要求：在 Xcode Build Settings → Header Search Paths 中添加
//    $(SRCROOT)/ios_lib_arm64/include
//  并在 Link Binary With Libraries 中添加：
//    libimobiledevice.a  libimobiledevice-glue.a  libplist.a
//    libusbmuxd.a        libssl.a                  libcrypto.a
//

#import "DeviceScreenshotViewController.h"
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/screenshotr.h>

@interface DeviceScreenshotViewController ()

@property (nonatomic, strong) NSImageView       *imageView;
@property (nonatomic, strong) NSButton          *captureButton;
@property (nonatomic, strong) NSButton          *saveButton;
@property (nonatomic, strong) NSTextField       *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;

@property (nonatomic, strong) NSImage           *currentScreenshot;
@property (nonatomic, copy)   NSString          *deviceUDID;

@end

@implementation DeviceScreenshotViewController

#pragma mark - Init

+ (BOOL)requiresApp { return NO; }

- (instancetype)init {
    return [super initWithFeatureName:@"设备截屏"];
}

- (void)dealloc {
    // 确保没有任何 dangling C 指针
    _currentScreenshot = nil;
}

#pragma mark - View Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
    [self refreshDeviceStatus];
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
    _captureButton = [NSButton buttonWithTitle:@"📸 截屏"
                                        target:self
                                        action:@selector(captureScreenshot:)];
    _captureButton.bezelStyle = NSBezelStyleRounded;
    _captureButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_captureButton];

    // ---- 保存按钮 ----
    _saveButton = [NSButton buttonWithTitle:@"💾 保存"
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
    _statusLabel.stringValue = @"正在检测设备…";
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
        // 截图预览：顶部留边距，左右撑开
        [_imageView.topAnchor     constraintEqualToAnchor:self.view.topAnchor    constant:20],
        [_imageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_imageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        // 截屏按钮
        [_captureButton.topAnchor     constraintEqualToAnchor:_imageView.bottomAnchor constant:16],
        [_captureButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        // 状态标签
        [_statusLabel.topAnchor      constraintEqualToAnchor:_captureButton.bottomAnchor constant:12],
        [_statusLabel.centerXAnchor  constraintEqualToAnchor:self.view.centerXAnchor],

        // 加载指示器（状态标签右侧）
        [_spinner.leadingAnchor  constraintEqualToAnchor:_statusLabel.trailingAnchor constant:6],
        [_spinner.centerYAnchor  constraintEqualToAnchor:_statusLabel.centerYAnchor],

        // 保存按钮（底部）
        [_saveButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_saveButton.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor constant:-20],
    ]];
}

#pragma mark - Device Detection

- (void)refreshDeviceStatus {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char **devices = NULL;
        int count = 0;
        idevice_error_t ret = idevice_get_device_list(&devices, &count);

        // Extract UDID in background thread BEFORE freeing the device list
        NSString *udid = nil;
        if (ret == IDEVICE_E_SUCCESS && count > 0 && devices[0]) {
            udid = [NSString stringWithUTF8String:devices[0]];
        }

        if (devices) {
            idevice_device_list_free(devices);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!udid) {
                self.statusLabel.stringValue = @"未检测到 iOS 设备，请通过 USB 或 WiFi 连接";
                self.captureButton.enabled = NO;
                return;
            }

            self.deviceUDID = udid;
            self.statusLabel.stringValue = [NSString stringWithFormat:@"已连接: %@", udid];
            self.captureButton.enabled = YES;
        });
    });
}

#pragma mark - Screenshot Capture

- (void)captureScreenshot:(NSButton *)sender {
    sender.enabled = NO;
    self.saveButton.enabled = NO;
    self.statusLabel.stringValue = @"正在截屏…";
    [self.spinner startAnimation:nil];

    // libimobiledevice 调用均为阻塞式，放在后台线程执行
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSImage *screenshot = [self captureScreenshotFromDevice];
        NSString *errorMsg  = nil;

        if (!screenshot) {
            errorMsg = @"截屏失败，请确认设备已解锁且信任此电脑";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimation:nil];
            sender.enabled = YES;

            if (screenshot) {
                self.currentScreenshot = screenshot;
                self.imageView.image = screenshot;
                self.saveButton.enabled = YES;

                NSSize size = screenshot.size;
                self.statusLabel.stringValue = [NSString stringWithFormat:
                    @"截屏成功 — %.0f × %.0f 像素", size.width, size.height];
            } else {
                self.statusLabel.stringValue = errorMsg;
            }
        });
    });
}

/// 在后台线程调用 — 通过 libimobiledevice 获取截屏
- (nullable NSImage *)captureScreenshotFromDevice {
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    screenshotr_client_t screenshotr = NULL;
    char *imgdata = NULL;
    uint64_t imgsize = 0;
    NSImage *result = nil;

    const char *udid = self.deviceUDID.UTF8String;
    if (!udid) {
        NSLog(@"[Screenshot] 未选择设备");
        return nil;
    }

    idevice_error_t ret;
    lockdownd_error_t lerr;
    screenshotr_error_t serr;
    lockdownd_service_descriptor_t svcDesc = NULL;

    // ---- 1. 连接设备 ----
    ret = idevice_new_with_options(&device, udid,
                                   IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK);
    if (ret != IDEVICE_E_SUCCESS) {
        NSLog(@"[Screenshot] 连接设备失败: %d", ret);
        goto cleanup;
    }

    // ---- 3. 配对 & 创建 lockdown 会话 ----
    lerr = lockdownd_client_new_with_handshake(device, &lockdown, "MyUltron");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        NSLog(@"[Screenshot] lockdown 握手失败: %d — 请在设备上点击「信任」", lerr);
        goto cleanup;
    }

    // ---- 4. 启动 screenshotr 服务 ----
    lerr = lockdownd_start_service(lockdown, SCREENSHOTR_SERVICE_NAME, &svcDesc);
    if (lerr != LOCKDOWN_E_SUCCESS) {
        NSLog(@"[Screenshot] 启动截图服务失败: %d (需挂载开发者镜像)", lerr);
        goto cleanup;
    }

    // ---- 5. 连接 screenshotr ----
    serr = screenshotr_client_new(device, svcDesc, &screenshotr);
    lockdownd_service_descriptor_free(svcDesc);
    svcDesc = NULL;

    if (serr != SCREENSHOTR_E_SUCCESS) {
        NSLog(@"[Screenshot] screenshotr 连接失败: %d", serr);
        goto cleanup;
    }

    // ---- 6. 执行截屏 ----
    serr = screenshotr_take_screenshot(screenshotr, &imgdata, &imgsize);
    if (serr != SCREENSHOTR_E_SUCCESS || imgsize == 0) {
        NSLog(@"[Screenshot] 截屏失败: %d", serr);
        goto cleanup;
    }

    NSLog(@"[Screenshot] 截屏成功: %llu bytes (TIFF)", imgsize);

    // ---- 7. TIFF → NSImage ----
    {
        NSData *tiffData = [NSData dataWithBytesNoCopy:imgdata
                                                length:(NSUInteger)imgsize
                                          freeWhenDone:NO];
        result = [[NSImage alloc] initWithData:tiffData];
        if (!result) {
            NSLog(@"[Screenshot] TIFF 解析失败");
        }
    }

cleanup:
    // ---- 8. 清理资源 ----
    if (imgdata) {
        free(imgdata);
    }
    if (screenshotr) {
        screenshotr_client_free(screenshotr);
    }
    if (lockdown) {
        lockdownd_client_free(lockdown);
    }
    if (device) {
        idevice_free(device);
    }

    return result;
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

        // TIFF → target format
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
