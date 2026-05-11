//
//  AppDelegate.m
//  MyUltron
//

#import "AppDelegate.h"

static NSString * const kPrefServerPort = @"MyUltronServerPort";

@interface AppDelegate ()
@end

@implementation AppDelegate

+ (void)initialize {
    if (self == [AppDelegate class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kPrefServerPort: @62345,
        }];
    }
}

+ (uint16_t)serverPort {
    NSInteger port = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefServerPort];
    if (port <= 0 || port > 65535) port = 62345;
    return (uint16_t)port;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [self setupSettingsMenu];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

#pragma mark - Settings Menu

- (void)setupSettingsMenu {
    NSMenu *appMenu = [[NSApplication sharedApplication] mainMenu].itemArray.firstObject.submenu;
    if (!appMenu) return;

    NSInteger quitIdx = [appMenu indexOfItemWithTitle:@"Quit MyUltron"];
    if (quitIdx < 0) quitIdx = appMenu.numberOfItems - 1;

    if (![appMenu itemAtIndex:quitIdx - 1].separatorItem) {
        [appMenu insertItem:[NSMenuItem separatorItem] atIndex:quitIdx];
        quitIdx++;
    }

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences…"
                                                   action:@selector(openSettings:)
                                            keyEquivalent:@","];
    prefs.target = nil;
    [appMenu insertItem:prefs atIndex:quitIdx - 1];
}

- (void)openSettings:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Preferences";
    alert.informativeText = @"Configure the TCP port used to connect to the iOS app.\n(Matches the port MyUltronServer listens on.)";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *portField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 120, 24)];
    portField.stringValue = [NSString stringWithFormat:@"%u", [AppDelegate serverPort]];
    portField.placeholderString = @"62345";
    alert.accessoryView = portField;

    [alert beginSheetModalForWindow:NSApp.mainWindow completionHandler:^(NSModalResponse code) {
        if (code != NSAlertFirstButtonReturn) return;
        NSInteger port = portField.stringValue.integerValue;
        if (port < 1 || port > 65535) {
            NSAlert *err = [[NSAlert alloc] init];
            err.messageText = @"Invalid Port";
            err.informativeText = @"Port must be between 1 and 65535.";
            [err runModal];
            return;
        }
        [[NSUserDefaults standardUserDefaults] setInteger:port forKey:kPrefServerPort];
    }];
}

@end
