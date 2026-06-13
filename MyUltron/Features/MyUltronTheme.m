//
//  MyUltronTheme.m
//  MyUltron
//

#import "MyUltronTheme.h"

@implementation MyUltronTheme

// ---- Fonts ----

+ (NSFont *)statusFont {
    return [NSFont systemFontOfSize:11];
}

+ (NSFont *)tableFont {
    return [NSFont systemFontOfSize:12];
}

+ (NSFont *)tableBoldFont {
    return [NSFont boldSystemFontOfSize:12];
}

+ (NSFont *)monospacedFont {
    return [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
}

+ (NSFont *)sidebarFont {
    return [NSFont systemFontOfSize:13];
}

// ---- Colors ----

+ (NSColor *)accentColor {
    return [NSColor controlAccentColor];
}

+ (NSColor *)statusColor {
    return [NSColor secondaryLabelColor];
}

+ (NSColor *)backgroundColor {
    return [NSColor controlBackgroundColor];
}

+ (NSColor *)separatorColor {
    return [NSColor separatorColor];
}

// ---- Layout Constants ----

+ (CGFloat)standardMargin {
    return 12.0;
}

+ (CGFloat)tableRowHeight {
    return 28.0;
}

+ (CGFloat)statusBarHeight {
    return 18.0;
}

+ (CGFloat)sidebarRowHeight {
    return 30.0;
}

// ---- Button Helpers ----

+ (NSButton *)buttonWithTitle:(NSString *)title
                       target:(id)target
                       action:(SEL)action
{
    NSButton *btn = [NSButton buttonWithTitle:title target:target action:action];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.font = [self tableFont];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    return btn;
}

+ (NSButton *)compactButtonWithTitle:(NSString *)title
                              target:(id)target
                              action:(SEL)action
{
    NSButton *btn = [NSButton buttonWithTitle:title target:target action:action];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.font = [self statusFont];
    btn.controlSize = NSControlSizeSmall;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    return btn;
}

+ (NSButton *)symbolButton:(NSString *)symbolName
                   tooltip:(NSString *)tooltip
                    target:(id)target
                    action:(SEL)action
{
    NSImage *image = nil;
    if (@available(macOS 11.0, *)) {
        image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:tooltip];
    }
    NSButton *btn = image ? [NSButton buttonWithImage:image target:target action:action]
                          : [NSButton buttonWithTitle:symbolName target:target action:action];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.toolTip = tooltip;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    return btn;
}

// ---- Cell Helpers ----

+ (NSTableCellView *)tableCellWithIdentifier:(NSString *)identifier
                                     inTable:(NSTableView *)tableView
                                  monospaced:(BOOL)monospaced
{
    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;

        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO;
        tf.bordered = NO;
        tf.drawsBackground = NO;
        tf.font = monospaced ? [self monospacedFont] : [self tableFont];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:tf];

        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
        cell.textField = tf;
    }
    return cell;
}

@end
