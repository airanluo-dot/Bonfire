#import "Presentation.h"

@implementation BFStrings {
    NSBundle *_strings;
}
- (void)setLanguage:(NSString*)tag {
    if([tag isEqual:@"system"])[NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
    else [NSUserDefaults.standardUserDefaults setObject:@[tag] forKey:@"AppleLanguages"];
    if([tag isEqual:@"system"]) tag=NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *language=[tag hasPrefix:@"zh"] ? @"zh-Hans" : @"en";
    _locale=[NSLocale localeWithLocaleIdentifier:language];
    _strings=[NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:language ofType:@"lproj"]];
}
- (NSString*)text:(NSString*)key arguments:(NSArray*)args {
    NSString *value=[_strings localizedStringForKey:key value:key table:@"Localizable"];
    if(!args.count)return value;
    static NSRegularExpression *slots;static dispatch_once_t once;
    dispatch_once(&once,^{slots=[NSRegularExpression regularExpressionWithPattern:@"\\{([0-9]+)\\}" options:0 error:nil];});
    NSMutableString *output=[value mutableCopy];
    for(NSTextCheckingResult *m in [[slots matchesInString:value options:0 range:NSMakeRange(0,value.length)] reverseObjectEnumerator]){
        NSUInteger index=[[value substringWithRange:[m rangeAtIndex:1]] integerValue];
        if(index<args.count)[output replaceCharactersInRange:m.range withString:[args[index] description]];
    }
    return output;
}
- (NSString*)progressSummary:(NSDictionary*)progress found:(BOOL)found {
    NSInteger count=[progress[@"count"] integerValue];
    if(!count) return [self text:[progress[@"persistent"] boolValue]?@"PersistentOnly":@"NoneProgress" arguments:@[]];

    NSString *summary=count==1?[self text:@"OneProgress" arguments:@[]]:[self text:@"ManyProgress" arguments:@[@(count)]];
    if(found) summary=[self text:@"Found" arguments:@[summary]];
    NSString *chapterKey=progress[@"chapterKey"];
    if(chapterKey.length){
        NSString *chapter=[self text:chapterKey arguments:@[]];
        NSString *detail=[self text:@"LabelValue" arguments:@[[self text:@"SaveChapter" arguments:@[]],chapter]];
        summary=[self text:@"ProgressLine" arguments:@[summary,detail]];
    }
    NSString *playtime=progress[@"playtime"], *saved=progress[@"savedLocalTime"];
    if(!playtime.length && !saved.length) return summary;
    NSString *label=[self text:playtime.length?@"Playtime":@"LastSaveLabel" arguments:@[]];
    id slot=progress[@"slot"];
    if(playtime.length && count>1 && ([slot isKindOfClass:NSNumber.class] || ([slot isKindOfClass:NSString.class] && [slot length])))
        label=[self text:@"SlotPlaytime" arguments:@[slot]];
    NSString *value=playtime;
    if(!playtime.length){
        // The game's timestamp has no time zone. Format the same clock reading in the chosen UI language.
        NSDateFormatter *date=[NSDateFormatter new];
        date.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        date.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
        date.dateFormat=@"yyyy-MM-dd HH:mm";
        NSDate *stamp=[date dateFromString:saved];
        if(!stamp || ![[date stringFromDate:stamp] isEqual:saved]) return summary;
        NSDateFormatter *display=[NSDateFormatter new];
        display.locale=self.locale;
        display.timeZone=date.timeZone;
        display.dateStyle=NSDateFormatterShortStyle;
        display.timeStyle=NSDateFormatterShortStyle;
        value=[display stringFromDate:stamp];
    }
    NSString *detail=[self text:@"LabelValue" arguments:@[label,value]];
    return [self text:@"ProgressLine" arguments:@[summary,detail]];
}
@end
@implementation BFPrefs
- (instancetype)init {
    if((self=[super init])){
        NSDictionary *d=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"Preferences"];
        _language=d[@"language"] ?: @"system"; _folder=d[@"folder"] ?: @"";
        _hidden=[NSMutableSet setWithArray:d[@"hidden"] ?: @[]];
        _folders=[NSMutableOrderedSet orderedSetWithArray:d[@"folders"] ?: @[]];
        _autoCheck=d[@"autoCheck"]?[d[@"autoCheck"] boolValue]:YES;
        _autoDownload=d[@"autoDownload"]?[d[@"autoDownload"] boolValue]:YES;
        _autoInstall=[d[@"autoInstall"] boolValue];
        NSString *version=[NSBundle.mainBundle objectForInfoDictionaryKey:@"BonfireVersion"];
        _channel=d[@"channel"]?:([version containsString:@"-"]?@"Beta":@"Stable");
        _lastCheck=d[@"lastCheck"];
    }
    return self;
}
- (NSString*)destination {
    return _folder.length?_folder:[NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject.path;
}
- (void)save {
    NSMutableDictionary *d=[@{@"language":_language,@"folder":_folder,@"hidden":_hidden.allObjects,@"folders":_folders.array,
        @"autoCheck":@(_autoCheck),@"autoDownload":@(_autoDownload),@"autoInstall":@(_autoInstall),@"channel":_channel} mutableCopy];
    if(_lastCheck)d[@"lastCheck"]=_lastCheck;
    [NSUserDefaults.standardUserDefaults setObject:d forKey:@"Preferences"];
}
@end

@interface BFActionButton:NSButton
@property(nonatomic,copy) void (^handler)(void);
@end
@implementation BFActionButton
- (void)run:(id)sender {if(_handler)_handler();}
@end
NSButton *BFButton(NSString *title,void(^action)(void)){
    BFActionButton *button=[BFActionButton buttonWithTitle:title target:nil action:@selector(run:)];
    button.target=button;button.handler=action;return button;
}
NSTextField *BFLabel(NSString *value,CGFloat size,NSFontWeight weight){
    NSTextField *label=[NSTextField wrappingLabelWithString:value ?: @""];
    label.font=[NSFont systemFontOfSize:size weight:weight];label.selectable=YES;
    return label;
}
NSStackView *BFStack(NSUserInterfaceLayoutOrientation orientation,CGFloat spacing){
    NSStackView *s=[NSStackView stackViewWithViews:@[]];s.orientation=orientation;s.spacing=spacing;
    s.alignment=orientation==NSUserInterfaceLayoutOrientationVertical?NSLayoutAttributeLeading:NSLayoutAttributeCenterY;
    s.detachesHiddenViews=NO;return s;
}
void BFFillWidth(NSStackView *stack,NSView *child){
    [stack addArrangedSubview:child];[child.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-(stack.edgeInsets.left+stack.edgeInsets.right)].active=YES;
}

@implementation BFGameGrid
- (BOOL)isFlipped{return YES;}
- (void)addTile:(NSButton*)button{[self addSubview:button];[self invalidateIntrinsicContentSize];}
- (NSSize)intrinsicContentSize{
    NSInteger columns=MAX(1,(NSInteger)(self.bounds.size.width/118));
    return NSMakeSize(NSViewNoIntrinsicMetric,MAX(1,((NSInteger)self.subviews.count+columns-1)/columns)*120);
}
- (void)setFrameSize:(NSSize)size{
    BOOL changed=self.frame.size.width!=size.width;[super setFrameSize:size];
    if(changed){[self invalidateIntrinsicContentSize];self.needsLayout=YES;}
}
- (void)layout{
    [super layout];NSInteger columns=MAX(1,(NSInteger)(self.bounds.size.width/118));NSInteger i=0;
    for(NSView *button in self.subviews){button.frame=NSMakeRect((i%columns)*118,(i/columns)*120,110,110);++i;}
}
@end
