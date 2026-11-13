#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface BunnySettingsViewController
    : UIViewController <UITableViewDelegate, UITableViewDataSource>
- (instancetype)initWithVersion:(NSString *)version;
@end

#ifdef __cplusplus
extern "C" {
#endif

extern id gBridge;
void      showSettingsSheet(void);

#ifdef __cplusplus
}
#endif