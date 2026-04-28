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

- (void)viewDidLoad {
    [super viewDidLoad];

    // Do any additional setup after loading the view.
    
    // 1. 枚举 USB 连接的 iOS 设备
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
//    NSString *targetBundleID = @"com.tencent.xin"; // 替换为自签/调试App，AppStore应用不可访问
//    const char *bid = targetBundleID.UTF8String;
//
//     4. 启动 house_arrest 进入 App 私有沙盒
//    house_arrest_client_t ha = NULL;
//    if (house_arrest_client_new(dev, lckd, bid, &ha) != HOUSE_ARREST_E_SUCCESS) {
//        NSLog(@"❌ 沙盒访问失败：仅支持【调试/自签/企业签App】，AppStore正版无权限");
//        goto cleanup;
//    }
//    NSLog(@"✅ 成功进入 App 沙盒: %@", targetBundleID);
//
//    // 5. 从 house_arrest 挂载 AFC 文件通道
//    afc_client_t afc = NULL;
//    if (afc_client_new_from_house_arrest(ha, &afc) != AFC_E_SUCCESS) {
//        NSLog(@"❌ AFC 文件通道初始化失败");
//        goto cleanup;
//    }
//
//    // 6. 列出沙盒根目录
//    char **dirList = NULL;
//    afc_read_directory(afc, "/", &dirList);
//    NSLog(@"\n📁 沙盒根目录文件:");
//    for (int i = 0; dirList[i]; i++) {
//        NSLog(@"  %s", dirList[i]);
//    }
//    afc_string_array_free(dirList);
//
//    // 7. 写入测试文件到 Documents
//    const char *writePath = "/Documents/mac_test.txt";
//    const char *content = @"Hello Mac Native AFC Demo\n已成功读写iOS App沙盒";
//    uint64_t fileHandle = 0;
//
//    afc_file_open(afc, writePath, AFC_FOPEN_WRONLY | AFC_FOPEN_CREAT, &fileHandle);
//    if (fileHandle != 0) {
//        uint32_t writeLen = 0;
//        afc_file_write(afc, fileHandle, (void *)content, (uint32_t)strlen(content), &writeLen);
//        afc_file_close(afc, fileHandle);
//        NSLog(@"\n✅ 文件写入成功: %s", writePath);
//    } else {
//        NSLog(@"\n❌ 文件写入失败");
//    }
//
//    // 8. 读取刚刚写入的文件
//    afc_file_open(afc, writePath, AFC_FOPEN_RDONLY, &fileHandle);
//    if (fileHandle != 0) {
//        char buffer[2048] = {0};
//        uint32_t readLen = 0;
//        afc_file_read(afc, fileHandle, buffer, sizeof(buffer)-1, &readLen);
//        NSLog(@"\n📖 读取文件内容:\n%s", buffer);
//        afc_file_close(afc, fileHandle);
//    }

    // 资源释放
    cleanup:
//        if (afc) afc_client_free(afc);
//        if (ha) house_arrest_client_free(ha);
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
