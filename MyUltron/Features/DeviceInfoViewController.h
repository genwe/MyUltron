//
//  DeviceInfoViewController.h
//  MyUltron
//
//  显示选中设备的基本信息及应用列表。
//  使用 libimobiledevice 直接获取设备数据。
//

#import "FeatureViewController.h"

@interface DeviceInfoViewController : FeatureViewController

/// 由 ViewController 在创建后注入，已选中的设备 UDID。
@property (nonatomic, copy) NSString *deviceUDID;

@end
