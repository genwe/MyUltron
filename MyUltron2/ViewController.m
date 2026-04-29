//
//  ViewController.m
//  MyUltron2
//
//  Created by 魏根 on 2026/4/28.
//

#import "ViewController.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/house_arrest.h>
#include <libimobiledevice/afc.h>
#include <plist/plist.h>

@implementation ViewController

- (NSArray<NSString *> *)bootedIOSSimulators {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];

    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"simctl", @"list", @"devices", @"--json"];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        NSLog(@"⚠️ 模拟器检测失败: %@", launchError.localizedDescription);
        return @[];
    }

    [task waitUntilExit];

    NSData *outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
    NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
    if (task.terminationStatus != 0) {
        NSString *errorOutput = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if (errorOutput.length > 0) {
            NSLog(@"⚠️ 模拟器检测失败: %@", errorOutput);
        }
        return @[];
    }
    if (outputData.length == 0) {
        return @[];
    }

    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:outputData options:0 error:&jsonError];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (jsonError != nil) {
            NSLog(@"⚠️ 模拟器检测结果解析失败: %@", jsonError.localizedDescription);
        }
        return @[];
    }

    NSDictionary<NSString *, NSArray<NSDictionary *> *> *devicesByRuntime = json[@"devices"];
    if (![devicesByRuntime isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSMutableArray<NSString *> *simulators = [NSMutableArray array];
    [devicesByRuntime enumerateKeysAndObjectsUsingBlock:^(NSString *runtime, NSArray<NSDictionary *> *devices, BOOL *stop) {
        if (![runtime containsString:@"iOS"]) {
            return;
        }
        for (NSDictionary *device in devices) {
            if (![device isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *state = device[@"state"];
            NSString *name = device[@"name"];
            NSString *udid = device[@"udid"];
            if ([state isEqualToString:@"Booted"] && name.length > 0 && udid.length > 0) {
                [simulators addObject:[NSString stringWithFormat:@"%@ (%@)", name, udid]];
            }
        }
    }];

    return simulators;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Do any additional setup after loading the view.
    
    // 1. 同时检测已启动的 iOS 模拟器和 USB 连接的真机
    NSArray<NSString *> *bootedSimulators = [self bootedIOSSimulators];
    if (bootedSimulators.count > 0) {
        NSLog(@"✅ 检测到 %lu 个已启动的 iOS 模拟器", (unsigned long)bootedSimulators.count);
        for (NSString *simulator in bootedSimulators) {
            NSLog(@"  Simulator: %@", simulator);
        }
    } else {
        NSLog(@"ℹ️ 当前没有已启动的 iOS 模拟器");
    }

    char **devices = NULL;
    int dev_count = 0;
    idevice_error_t err = idevice_get_device_list(&devices, &dev_count);
    if (dev_count == 0) {
        NSLog(@"❌ 未检测到已连接、已信任的 iOS 设备");
        return;
    }
    if (err == IDEVICE_E_SUCCESS && dev_count > 0) {
        NSLog(@"检测到已连接、已信任的 iOS 设备");
    }
    
    const char *udid = devices[0];
    NSLog(@"✅ 设备 UDID: %s", udid);

    const char content[] = "Hello Mac Native AFC Demo\n\xe5\xb7\xb2\xe6\x88\x90\xe5\x8a\x9f\xe8\xaf\xbb\xe5\x86\x99iOS App\xe6\xb2\x99\xe7\x9b\x92";

    // 2. 创建设备连接
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX) != IDEVICE_E_SUCCESS) {
        NSLog(@"❌ 设备连接失败");
        idevice_device_list_free(devices);
        return;
    }

    // 3. 握手 lockdownd 服务
    lockdownd_client_t lckd = NULL;
    if (lockdownd_client_new_with_handshake(dev, &lckd, "MacAFC_Demo") != LOCKDOWN_E_SUCCESS) {
        NSLog(@"❌ Lockdown 握手失败，请解锁手机并重信电脑");
        idevice_free(dev);
        idevice_device_list_free(devices);
        return;
    }

    // ===================== 配置你要访问的 App BundleID =====================
    NSString *targetBundleID = @"com.tencent.xin"; // 替换为自签/调试App，AppStore应用不可访问
    const char *bid = targetBundleID.UTF8String;

    // 4. 启动 house_arrest 进入 App 私有沙盒
    house_arrest_client_t ha = NULL;
    afc_client_t afc = NULL;
    lockdownd_service_descriptor_t service = NULL;
    if (lockdownd_start_service(lckd, HOUSE_ARREST_SERVICE_NAME, &service) != LOCKDOWN_E_SUCCESS || !service) {
        NSLog(@"❌ House Arrest 服务启动失败");
        goto cleanup;
    }

    if (house_arrest_client_new(dev, service, &ha) != HOUSE_ARREST_E_SUCCESS) {
        NSLog(@"❌ House Arrest 客户端创建失败");
        goto cleanup;
    }

    if (house_arrest_send_command(ha, "VendDocuments", bid) != HOUSE_ARREST_E_SUCCESS) {
        NSLog(@"❌ 沙盒访问命令发送失败");
        goto cleanup;
    }

    plist_t result = NULL;
    if (house_arrest_get_result(ha, &result) != HOUSE_ARREST_E_SUCCESS || !result) {
        NSLog(@"❌ 沙盒访问结果读取失败");
        goto cleanup;
    }

    plist_t errorNode = plist_dict_get_item(result, "Error");
    if (errorNode != NULL) {
        char *errorText = NULL;
        plist_get_string_val(errorNode, &errorText);
        NSLog(@"❌ 沙盒访问失败: %s", errorText ?: "unknown error");
        free(errorText);
        plist_free(result);
        goto cleanup;
    }
    plist_free(result);
    NSLog(@"✅ 成功进入 App 沙盒: %@", targetBundleID);

    // 5. 从 house_arrest 挂载 AFC 文件通道
    if (afc_client_new_from_house_arrest_client(ha, &afc) != AFC_E_SUCCESS) {
        NSLog(@"❌ AFC 文件通道初始化失败");
        goto cleanup;
    }

    // 6. 列出沙盒根目录
    char **dirList = NULL;
    afc_read_directory(afc, "/", &dirList);
    NSLog(@"\n📁 沙盒根目录文件:");
    for (int i = 0; dirList[i]; i++) {
        NSLog(@"  %s", dirList[i]);
    }
    afc_dictionary_free(dirList);

    // 7. 写入测试文件到 Documents
    const char *writePath = "/Documents/mac_test.txt";
    uint64_t fileHandle = 0;

    afc_file_open(afc, writePath, AFC_FOPEN_WRONLY, &fileHandle);
    if (fileHandle != 0) {
        uint32_t writeLen = 0;
        afc_file_write(afc, fileHandle, (void *)content, (uint32_t)strlen(content), &writeLen);
        afc_file_close(afc, fileHandle);
        NSLog(@"\n✅ 文件写入成功: %s", writePath);
    } else {
        NSLog(@"\n❌ 文件写入失败");
    }

    // 8. 读取刚刚写入的文件
    afc_file_open(afc, writePath, AFC_FOPEN_RDONLY, &fileHandle);
    if (fileHandle != 0) {
        char buffer[2048] = {0};
        uint32_t readLen = 0;
        afc_file_read(afc, fileHandle, buffer, sizeof(buffer)-1, &readLen);
        NSLog(@"\n📖 读取文件内容:\n%s", buffer);
        afc_file_close(afc, fileHandle);
    }

    // 资源释放
    cleanup:
        if (afc) afc_client_free(afc);
        if (ha) house_arrest_client_free(ha);
        if (service) lockdownd_service_descriptor_free(service);
        if (lckd) lockdownd_client_free(lckd);
        if (dev) idevice_free(dev);
        idevice_device_list_free(devices);

        NSLog(@"\n🏁 全部流程结束");
}


- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}


@end
