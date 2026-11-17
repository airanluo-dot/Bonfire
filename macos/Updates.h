#import "Presentation.h"
@interface BFUpdates:NSObject
@property(nonatomic,copy) void (^changed)(void);
@property(nonatomic,copy) BOOL (^canInstall)(void);
@property(nonatomic,readonly) NSString *status;
@property(nonatomic,readonly) NSDictionary *candidate;
@property(nonatomic,readonly) NSURL *download;
@property(nonatomic,readonly) BOOL busy;
@property(nonatomic,readonly) BOOL installing;
@property(nonatomic,readonly) BOOL installed;
+ (NSString*)version;
- (instancetype)initWithPreferences:(BFPrefs*)preferences;
- (void)check;
- (void)downloadUpdate;
- (void)install;
- (void)applyAutomaticIfReady;
- (void)reveal;
- (void)cancel;
@end
