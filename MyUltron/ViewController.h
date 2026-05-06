//
//  ViewController.h
//  MyUltron
//
//  Created by 魏根 on 2026/4/28.
//

#import <Cocoa/Cocoa.h>

@interface ViewController : NSViewController

@property (nonatomic, strong) NSButton *deviceButton;
@property (nonatomic, strong) NSButton *appButton;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, copy) NSString *selectedUDID;
@property (nonatomic, assign) BOOL selectedIsSimulator;

@end

