#import "Presentation.h"
@interface BFUpdates:NSObject
@property(nonatomic,copy) void (^changed)(void);
@property(nonatomic,copy) void (^progressChanged)(void);
@property(nonatomic,copy) BOOL (^canInstall)(void);
@property(nonatomic,readonly) NSString *status;
@property(nonatomic,readonly) NSArray *statusArguments;
@property(nonatomic,readonly) NSDictionary *candidate;
@property(nonatomic,readonly) NSURL *download;
@property(nonatomic,readonly) double progress;
@property(nonatomic,readonly) BOOL busy, installing, installed, canCancel, needsReopen;
@property(nonatomic,readonly) NSString *retryAction;
@property(nonatomic,readonly) NSDate *retryAfter;
+ (NSString*)version;
- (instancetype)initWithPreferences:(BFPrefs*)preferences;
- (void)check;
- (void)downloadUpdate;
- (void)install;
- (void)preferencesChanged:(NSString*)key;
- (void)applyAutomaticIfReady;
- (void)reveal;
- (void)cancel;
@end
