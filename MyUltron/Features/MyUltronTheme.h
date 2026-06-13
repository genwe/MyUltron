//
//  MyUltronTheme.h
//  MyUltron
//
//  Shared UI constants and helpers for consistent styling across all feature VCs.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MyUltronTheme : NSObject

// ---- Fonts ----

+ (NSFont *)statusFont;          // 11pt system — status bars, small labels
+ (NSFont *)tableFont;           // 12pt system — table cells, body text
+ (NSFont *)tableBoldFont;       // 12pt bold system — column labels, key columns
+ (NSFont *)monospacedFont;      // 11pt monospaced — bundle ids, values, JSON
+ (NSFont *)sidebarFont;         // 13pt system — sidebar feature names

// ---- Colors ----

+ (NSColor *)accentColor;        // system accent (NSColor.controlAccentColor)
+ (NSColor *)statusColor;        // secondaryLabelColor
+ (NSColor *)backgroundColor;    // controlBackgroundColor
+ (NSColor *)separatorColor;     // separatorColor

// ---- Layout Constants ----

+ (CGFloat)standardMargin;       // 12pt
+ (CGFloat)tableRowHeight;       // 28pt
+ (CGFloat)statusBarHeight;      // 18pt
+ (CGFloat)sidebarRowHeight;     // 30pt

// ---- Button Helpers ----

/// Standard rounded button with systemFont 13pt
+ (NSButton *)buttonWithTitle:(NSString *)title
                       target:(id)target
                       action:(SEL)action;

/// Compact button for toolbar rows
+ (NSButton *)compactButtonWithTitle:(NSString *)title
                              target:(id)target
                              action:(SEL)action;

/// Image-only button using an SF Symbol name
+ (NSButton *)symbolButton:(NSString *)symbolName
                   tooltip:(NSString *)tooltip
                    target:(id)target
                    action:(SEL)action;

// ---- Cell Helpers ----

/// Create or reuse an NSTableCellView with a text field constrained by Auto Layout.
+ (NSTableCellView *)tableCellWithIdentifier:(NSString *)identifier
                                     inTable:(NSTableView *)tableView
                                  monospaced:(BOOL)monospaced;

@end

NS_ASSUME_NONNULL_END
