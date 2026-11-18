#import <AppKit/AppKit.h>

@interface BFStrings : NSObject
@property(nonatomic,readonly) NSLocale *locale;
- (void)setLanguage:(NSString*)tag;
- (NSString*)text:(NSString*)key arguments:(NSArray*)arguments;
- (NSString*)progressSummary:(NSDictionary*)progress found:(BOOL)found;
@end

@interface BFPrefs : NSObject
@property(nonatomic,copy) NSString *language;
@property(nonatomic,copy) NSString *folder;
@property(nonatomic,readonly) NSString *destination;
@property(nonatomic,readonly) NSMutableSet<NSString*> *hidden;
@property(nonatomic,readonly) NSMutableOrderedSet<NSString*> *folders;
@property(nonatomic) BOOL autoCheck,autoDownload,autoInstall;
@property(nonatomic,copy) NSString *channel;
@property(nonatomic,strong) NSDate *lastCheck;
- (void)save;
@end

NSButton *BFButton(NSString *title, void(^action)(void));
NSTextField *BFLabel(NSString *value, CGFloat size, NSFontWeight weight);
NSStackView *BFStack(NSUserInterfaceLayoutOrientation orientation,CGFloat spacing);
void BFFillWidth(NSStackView *stack,NSView *child);

@interface BFGameGrid : NSView
- (void)addTile:(NSButton*)button;
@end
