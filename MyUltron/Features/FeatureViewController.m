//
//  FeatureViewController.m
//  MyUltron
//

#import "FeatureViewController.h"

@interface FeatureViewController ()
@property (nonatomic, copy) NSString *featureName;
@end

@implementation FeatureViewController

+ (BOOL)requiresConnection { return YES; }
+ (BOOL)requiresApp      { return YES; }

- (instancetype)initWithFeatureName:(NSString *)featureName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _featureName = featureName;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = [NSString stringWithFormat:NSLocalizedString(@"%@ - 待实现", nil), self.featureName];
    label.editable = NO;
    label.bordered = NO;
    label.selectable = NO;
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor secondaryLabelColor];
    label.font = [NSFont systemFontOfSize:16];
    [label sizeToFit];

    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (void)viewDidConnect    {}
- (void)viewDidDisconnect {}
- (void)didReceiveMessage:(NSDictionary *)dict {}
- (void)didReceiveBinaryData:(NSData *)data {}

@end
