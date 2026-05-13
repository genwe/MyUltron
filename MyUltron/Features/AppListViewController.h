//
//  AppListViewController.h
//  MyUltron
//
//  显示选中设备的应用列表（名称、Bundle ID、版本）。
//  使用 libimobiledevice 的 installation_proxy 获取数据。
//

#import "FeatureViewController.h"

@interface AppListViewController : FeatureViewController

/// 由 ViewController 在创建后注入，已选中的设备 UDID。
@property (nonatomic, copy) NSString *deviceUDID;

@end
