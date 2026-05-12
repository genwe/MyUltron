//
//  ViewController.h
//  MyUltron
//
//  Created by 魏根 on 2026/4/28.
//

#import <Cocoa/Cocoa.h>

@class MyUltronClient;

@interface ViewController : NSViewController <NSDraggingDestination>

@property (nonatomic, strong) NSButton *deviceButton;
@property (nonatomic, strong) NSButton *appButton;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, copy) NSString *selectedUDID;
@property (nonatomic, assign) BOOL selectedIsSimulator;
@property (nonatomic, strong, readonly) MyUltronClient *client;

// Drag-and-drop install
- (void)installAppAtPath:(NSString *)path;

@end

