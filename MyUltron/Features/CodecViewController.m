//
//  CodecViewController.m
//  MyUltron
//
//  Local codec tools — URL encode/decode, Base64 encode/decode, MD5 hash.
//

#import "CodecViewController.h"
#import <CommonCrypto/CommonDigest.h>

@interface CodecViewController ()
@property (nonatomic, strong) NSTextView    *inputView;
@property (nonatomic, strong) NSTextView    *outputView;
@property (nonatomic, strong) NSPopUpButton *operationPopup;
@property (nonatomic, strong) NSButton      *executeBtn;
@property (nonatomic, strong) NSButton      *aCopyBtn;
@property (nonatomic, strong) NSButton      *swapBtn;
@end

@implementation CodecViewController

+ (BOOL)requiresConnection { return NO; }

- (instancetype)init {
    return [super initWithFeatureName:@"编解码"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildUI];
}

#pragma mark - UI

- (void)buildUI {
    CGFloat margin = 12;
    CGFloat w = self.view.bounds.size.width - margin * 2;
    CGFloat halfH = (self.view.bounds.size.height - 70) / 2;

    // ---- Toolbar ----
    self.operationPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(margin, self.view.bounds.size.height - 36, 160, 24)];
    [self.operationPopup addItemsWithTitles:@[@"URL Encode", @"URL Decode",
                                               @"Base64 Encode", @"Base64 Decode",
                                               @"MD5"]];
    self.operationPopup.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:self.operationPopup];

    self.executeBtn = [self btn:@"Execute" x:NSMaxX(self.operationPopup.frame)+8
                               y:self.view.bounds.size.height-36 action:@selector(execute:)];
    self.swapBtn    = [self btn:@"⇅ Swap" x:NSMaxX(self.executeBtn.frame)+8
                               y:self.view.bounds.size.height-36 action:@selector(swapInputOutput:)];
    self.aCopyBtn    = [self btn:@"Copy" x:NSMaxX(self.swapBtn.frame)+8
                               y:self.view.bounds.size.height-36 action:@selector(copyOutput:)];

    // ---- Input ----
    NSTextField *inLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, self.view.bounds.size.height - 68, 200, 18)];
    inLabel.editable = NO; inLabel.bordered = NO; inLabel.drawsBackground = NO;
    inLabel.stringValue = @"Input:";
    inLabel.font = [NSFont boldSystemFontOfSize:12];
    inLabel.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:inLabel];

    NSScrollView *inScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(margin, margin + halfH + 14, w, halfH)];
    inScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;
    inScroll.borderType = NSBezelBorder;
    inScroll.hasVerticalScroller = YES;

    self.inputView = [[NSTextView alloc] initWithFrame:inScroll.bounds];
    self.inputView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.inputView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    inScroll.documentView = self.inputView;
    [self.view addSubview:inScroll];

    // ---- Output ----
    NSTextField *outLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(margin, margin + halfH - 6, 200, 18)];
    outLabel.editable = NO; outLabel.bordered = NO; outLabel.drawsBackground = NO;
    outLabel.stringValue = @"Output:";
    outLabel.font = [NSFont boldSystemFontOfSize:12];
    outLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [self.view addSubview:outLabel];

    NSScrollView *outScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(margin, margin, w, halfH)];
    outScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMaxYMargin;
    outScroll.borderType = NSBezelBorder;
    outScroll.hasVerticalScroller = YES;

    self.outputView = [[NSTextView alloc] initWithFrame:outScroll.bounds];
    self.outputView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.outputView.editable = NO;
    self.outputView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    outScroll.documentView = self.outputView;
    [self.view addSubview:outScroll];
}

- (NSButton *)btn:(NSString *)title x:(CGFloat)x y:(CGFloat)y action:(SEL)sel {
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, 80, 26)];
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.target = self;
    b.action = sel;
    b.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:b];
    return b;
}

#pragma mark - Actions

- (void)execute:(id)sender {
    NSString *input = self.inputView.string;
    if (input.length == 0) return;

    NSString *title = self.operationPopup.selectedItem.title;
    NSString *result = @"";

    if ([title isEqualToString:@"URL Encode"]) {
        result = [self urlEncode:input];
    } else if ([title isEqualToString:@"URL Decode"]) {
        result = [self urlDecode:input];
    } else if ([title isEqualToString:@"Base64 Encode"]) {
        result = [self base64Encode:input];
    } else if ([title isEqualToString:@"Base64 Decode"]) {
        result = [self base64Decode:input];
    } else if ([title isEqualToString:@"MD5"]) {
        result = [self md5:input];
    }

    self.outputView.string = result ?: @"";
}

- (void)swapInputOutput:(id)sender {
    NSString *tmp = self.inputView.string;
    self.inputView.string = self.outputView.string;
    self.outputView.string = tmp;
}

- (void)copyOutput:(id)sender {
    NSString *s = self.outputView.string;
    if (s.length == 0) return;
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:s forType:NSPasteboardTypeString];
}

#pragma mark - Codec

- (NSString *)urlEncode:(NSString *)s {
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    // Also encode &, =, ?, etc. that URLQueryAllowedCharacterSet leaves unencoded
    NSMutableCharacterSet *strict = [allowed mutableCopy];
    [strict removeCharactersInString:@"&=$+?/"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:strict];
}

- (NSString *)urlDecode:(NSString *)s {
    return [s stringByRemovingPercentEncoding];
}

- (NSString *)base64Encode:(NSString *)s {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    return [data base64EncodedStringWithOptions:0];
}

- (NSString *)base64Decode:(NSString *)s {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:s options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[Invalid Base64]";
}

- (NSString *)md5:(NSString *)s {
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

@end
