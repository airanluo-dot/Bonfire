#import "Presentation.h"

@implementation BFStrings {
    NSBundle *_strings;
}
- (void)setLanguage:(NSString*)tag {
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
@end
@implementation BFPrefs
- (instancetype)init {
    if((self=[super init])){
        NSDictionary *d=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"Preferences"];
        _language=d[@"language"] ?: @"system"; _folder=d[@"folder"] ?: @"";
        _hidden=[NSMutableSet setWithArray:d[@"hidden"] ?: @[]];
        _folders=[NSMutableOrderedSet orderedSetWithArray:d[@"folders"] ?: @[]];
    }
    return self;
}
- (NSString*)destination {
    return _folder.length?_folder:[NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject.path;
}
- (void)save {
    [NSUserDefaults.standardUserDefaults setObject:@{@"language":_language,@"folder":_folder,@"hidden":_hidden.allObjects,@"folders":_folders.array} forKey:@"Preferences"];
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
