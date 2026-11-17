#import "Presentation.h"
#import "Updates.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <atomic>
#include <memory>

extern "C" char *bf_request(const char*,void*);
extern "C" void bf_free(void*);
using Stop=std::shared_ptr<std::atomic_bool>;
static NSDictionary *call(NSDictionary *input,Stop stop){
    NSData *json=[NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    char *raw=bf_request(text.UTF8String,stop.get());
    if(!raw)return @{@"error":@"Unexpected",@"args":@[@""]};
    NSData *result=[NSData dataWithBytes:raw length:strlen(raw)];bf_free(raw);
    return [NSJSONSerialization JSONObjectWithData:result options:0 error:nil];
}

@interface BFDocument:NSView
@end
@implementation BFDocument
- (BOOL)isFlipped{return YES;}
@end
@interface BFClip:NSClipView
@end
@implementation BFClip
- (BOOL)isFlipped{return YES;}
@end

@interface Bonfire : NSObject <NSApplicationDelegate,NSToolbarDelegate,NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate>
@end
@implementation Bonfire {
    NSWindow *_window;
    NSSplitViewController *_split;
    NSViewController *_content;
    NSTableView *_navigation;
    NSButton *_settingsButton;
    NSStackView *_page;
    NSTextField *_status;
    BFPrefs *_prefs;
    BFStrings *_strings;
    NSArray *_catalog,*_installs;
    NSDictionary *_game,*_install,*_inventory,*_preview;
    NSString *_section,*_folder,*_package,*_checksum;
    BOOL _receiving,_writing;
    NSUInteger _previewGeneration;
    Stop _screen;
    BFUpdates *_updates;
    NSStackView *_updateGroup;
}
- (NSString*)t:(NSString*)key {return [_strings text:key arguments:@[]];}
- (NSString*)format:(NSString*)key arg:(id)arg {return [_strings text:key arguments:@[arg]];}
- (NSString*)name:(NSDictionary*)game {return [self t:[@"Game_" stringByAppendingString:game[@"id"]]];}
- (void)restart {if(_screen)*_screen=true;_screen=std::make_shared<std::atomic_bool>(false);}
- (void)applicationDidFinishLaunching:(NSNotification*)note {
    _prefs=[BFPrefs new];_strings=[BFStrings new];[_strings setLanguage:_prefs.language];
    [self restart];_catalog=call(@{@"op":@"catalog"},_screen)[@"value"];
    _split=[NSSplitViewController new];
    NSViewController *side=[NSViewController new];side.view=[NSView new];_content=[NSViewController new];_content.view=[NSView new];
    NSSplitViewItem *item=[NSSplitViewItem sidebarWithViewController:side];
    item.minimumThickness=170;item.maximumThickness=270;item.canCollapse=YES;
    [_split addSplitViewItem:item];[_split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:_content]];
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,960,650) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"Bonfire";_window.delegate=self;_window.contentMinSize=NSMakeSize(650,470);_window.contentViewController=_split;
    _window.toolbarStyle=NSWindowToolbarStyleUnified;
    NSToolbar *toolbar=[[NSToolbar alloc] initWithIdentifier:@"BonfireMain"];toolbar.delegate=self;toolbar.displayMode=NSToolbarDisplayModeIconOnly;_window.toolbar=toolbar;
    [self buildSidebar:side.view];[self menu];[self enter:@"work"];
    [_window center];[_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
    _updates=[[BFUpdates alloc] initWithPreferences:_prefs];
    __weak Bonfire *weakSelf=self;
    _updates.changed=^{[weakSelf showUpdates];};
    _updates.canInstall=^BOOL{Bonfire *owner=weakSelf;return owner && !owner->_writing;};
    if(_prefs.autoCheck)[_updates check];
}
- (void)menu {
    NSMenu *bar=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[bar addItem:app];
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Bonfire"];
    [menu addItemWithTitle:[self t:@"Settings"] action:@selector(openSettings:) keyEquivalent:@","].target=self;
    [menu addItem:[NSMenuItem separatorItem]];[menu addItemWithTitle:[self t:@"HideApp"] action:@selector(hide:) keyEquivalent:@"h"];
    [menu addItemWithTitle:[self t:@"QuitApp"] action:@selector(terminate:) keyEquivalent:@"q"];app.submenu=menu;
    NSMenuItem *wi=[NSMenuItem new];[bar addItem:wi];NSMenu *wm=[[NSMenu alloc]initWithTitle:[self t:@"Window"]];
    [wm addItemWithTitle:[self t:@"Minimize"] action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [wm addItemWithTitle:[self t:@"Close"] action:@selector(performClose:) keyEquivalent:@"w"];wi.submenu=wm;NSApp.windowsMenu=wm;NSApp.mainMenu=bar;
}
- (NSArray*)toolbarAllowedItemIdentifiers:(NSToolbar*)t {return @[NSToolbarToggleSidebarItemIdentifier,NSToolbarSidebarTrackingSeparatorItemIdentifier,NSToolbarFlexibleSpaceItemIdentifier,@"Library"];}
- (NSArray*)toolbarDefaultItemIdentifiers:(NSToolbar*)t{return [self toolbarAllowedItemIdentifiers:t];}
- (NSToolbarItem*)toolbar:(NSToolbar*)t itemForItemIdentifier:(NSString*)identifier willBeInsertedIntoToolbar:(BOOL)insert {
    if(![identifier isEqual:@"Library"])return nil;
    NSToolbarItem *item=[[NSToolbarItem alloc] initWithItemIdentifier:identifier];item.target=self;item.action=@selector(goBack:);
    item.image=[NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:nil];item.label=[self t:@"ChangeGame"];item.toolTip=item.label;return item;
}
- (BOOL)validateToolbarItem:(NSToolbarItem*)item{return ![item.itemIdentifier isEqual:@"Library"] || (_game!=nil&&!_writing);}
- (void)goBack:(id)sender {if(_game&&!_writing)[self enter:_section];}
- (void)openSettings:(id)sender {if(!_writing)[self enter:@"settings"];}
- (void)buildSidebar:(NSView*)view {
    _navigation=[NSTableView new];_navigation.style=NSTableViewStyleSourceList;_navigation.headerView=nil;_navigation.rowHeight=34;
    NSTableColumn *column=[[NSTableColumn alloc]initWithIdentifier:@"section"];[_navigation addTableColumn:column];
    _navigation.dataSource=self;_navigation.delegate=self;_navigation.target=self;_navigation.action=@selector(sideClick:);
    NSScrollView *scroll=[NSScrollView new];scroll.drawsBackground=NO;scroll.documentView=_navigation;
    _settingsButton=BFButton([self t:@"Settings"],^{[self openSettings:nil];});_settingsButton.bezelStyle=NSBezelStyleAccessoryBarAction;
    _settingsButton.image=[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:nil];_settingsButton.imagePosition=NSImageLeading;
    for(NSView *v in @[scroll,_settingsButton]){[view addSubview:v];v.translatesAutoresizingMaskIntoConstraints=NO;}
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_settingsButton.topAnchor constant:-12],
        [_settingsButton.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:12],
        [_settingsButton.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-14]]];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table{return 2;}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row{
    NSString *title=[self t:row==0?@"Workbench":@"Manager"];
    NSImageView *icon=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:row==0?@"gamecontroller":@"archivebox" accessibilityDescription:nil]];
    NSStackView *line=BFStack(NSUserInterfaceLayoutOrientationHorizontal,8);[line addArrangedSubview:icon];
    NSTextField *text=BFLabel(title,13,NSFontWeightMedium);text.selectable=NO;[line addArrangedSubview:text];return line;
}
- (void)sideClick:(id)sender {NSInteger row=_navigation.clickedRow;if(row<0)row=_navigation.selectedRow;if(row>=0&&!_writing)[self enter:row==0?@"work":@"manage"];}
- (void)tableViewSelectionDidChange:(NSNotification*)n {
    NSInteger row=_navigation.selectedRow;if(row<0||_writing)return;NSString *s=row==0?@"work":@"manage";
    if(![_section isEqual:s])[self enter:s];
}
- (void)enter:(NSString*)section {
    if(_writing)return;
    [self restart];_section=section;_game=nil;_install=nil;_installs=@[];_inventory=nil;_preview=nil;_receiving=NO;_package=@"";_checksum=@"";_folder=_prefs.destination;
    BOOL settings=[section isEqual:@"settings"];
    if(settings)[_navigation deselectAll:nil];else [_navigation selectRowIndexes:[NSIndexSet indexSetWithIndex:[section isEqual:@"work"]?0:1] byExtendingSelection:NO];
    _settingsButton.title=[self t:@"Settings"];_settingsButton.state=settings?NSControlStateValueOn:NSControlStateValueOff;
    [_navigation reloadData];[_window.toolbar validateVisibleItems];if(settings)[self settings];else [self library];
}
- (void)startPage:(NSString*)title {
    _updateGroup=nil;
    NSView *view=_content.view;
    for(NSView *old in view.subviews.copy)[old removeFromSuperview];
    NSScrollView *scroll=[NSScrollView new];scroll.drawsBackground=NO;scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;
    [view addSubview:scroll];scroll.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor],[scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],[scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor]]];
    _page=BFStack(NSUserInterfaceLayoutOrientationVertical,16);_page.edgeInsets=NSEdgeInsetsMake(22,26,26,26);_page.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.contentView=[BFClip new];scroll.contentView.drawsBackground=NO;
    NSView *document=[BFDocument new];document.translatesAutoresizingMaskIntoConstraints=NO;scroll.documentView=document;
    [document addSubview:_page];
    [NSLayoutConstraint activateConstraints:@[[document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],[document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],[document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [_page.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],[_page.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],[_page.topAnchor constraintEqualToAnchor:document.topAnchor],[_page.bottomAnchor constraintEqualToAnchor:document.bottomAnchor]]];
    _window.subtitle=[self t:[_section isEqual:@"settings"]?@"Settings":[_section isEqual:@"work"]?@"Workbench":@"Manager"];

    [_page addArrangedSubview:BFLabel(title,28,NSFontWeightBold)];_status=BFLabel(@"",13,NSFontWeightRegular);
    for(NSToolbarItem *item in _window.toolbar.items)if([item.itemIdentifier isEqual:@"Library"]){item.label=[self t:@"ChangeGame"];item.toolTip=item.label;}
    [_window.toolbar validateVisibleItems];
}
- (void)library {
    [self startPage:[self t:@"AppLibrary"]];BFGameGrid *grid=[BFGameGrid new];
    for(NSDictionary *g in _catalog){
        if([_prefs.hidden containsObject:g[@"id"]])continue;
        NSButton *tile=BFButton([self name:g],^{
            [self restart];self->_game=g;
            if([self->_section isEqual:@"work"])[self find:nil];else [self timeline:nil];
        });
        tile.bordered=NO;tile.imagePosition=NSImageAbove;tile.imageScaling=NSImageScaleProportionallyDown;
        NSImage *icon=[[NSImage alloc] initWithContentsOfURL:[NSBundle.mainBundle URLForResource:g[@"id"] withExtension:@"png" subdirectory:@"Games"]];
        icon.size=NSMakeSize(72,72);tile.image=icon;[tile setAccessibilityLabel:[self name:g]];[grid addTile:tile];
    }
    if(grid.subviews.count)BFFillWidth(_page,grid);else [_page addArrangedSubview:BFLabel([self t:@"NoGames"],14,NSFontWeightRegular)];
}
- (void)perform:(NSDictionary*)parameters done:(void(^)(id result))done {
    NSMutableDictionary *request=[parameters mutableCopy];request[@"game"]=_game[@"id"];Stop stop=_screen;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSDictionary *response=call(request,stop);
        dispatch_async(dispatch_get_main_queue(),^{
            if(*stop)return;
            if(response[@"error"]){self->_status.stringValue=[self->_strings text:response[@"error"] arguments:response[@"args"]?:@[]];done(nil);}
            else done(response[@"value"]);
        });
    }});
}
- (NSString*)summary:(NSDictionary*)p found:(BOOL)found {
    NSInteger count=[p[@"count"] integerValue];if(!count)return [self t:@"NoneProgress"];
    NSString *one=[self t:@"OneProgress"];
    NSString *time=[p[@"playtime"] length]?p[@"playtime"]:[self t:@"Unknown"];
    NSString *label=count>1?[self format:@"SlotPlaytime" arg:p[@"slot"]]:[self t:@"Playtime"];
    return [_strings text:@"ProgressLine" arguments:@[found?[self format:@"Found" arg:one]:one,[_strings text:@"LabelValue" arguments:@[label,time]]]];
}
- (NSStackView*)group:(NSString*)key {
    NSBox *box=[NSBox new];box.titlePosition=NSNoTitle;box.boxType=NSBoxPrimary;NSView *inside=[NSView new];box.contentView=inside;
    NSStackView *stack=BFStack(NSUserInterfaceLayoutOrientationVertical,8);stack.translatesAutoresizingMaskIntoConstraints=NO;[inside addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:inside.leadingAnchor constant:12],[stack.trailingAnchor constraintEqualToAnchor:inside.trailingAnchor constant:-12],[stack.topAnchor constraintEqualToAnchor:inside.topAnchor constant:10],[stack.bottomAnchor constraintEqualToAnchor:inside.bottomAnchor constant:-10]]];
    [stack addArrangedSubview:BFLabel([self t:key],14,NSFontWeightSemibold)];
    [_page addArrangedSubview:box];[box.widthAnchor constraintEqualToAnchor:_page.widthAnchor constant:-52].active=YES;return stack;
}
- (void)workspace:(NSString*)message {
    [self startPage:[self name:_game]];
    NSSegmentedControl *segments=[NSSegmentedControl segmentedControlWithLabels:@[[self t:@"Extract"],[self t:@"Receive"]] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(mode:)];
    segments.selectedSegment=_receiving?1:0;[_page addArrangedSubview:segments];
    NSStackView *location=[self group:@"GameLocation"];
    if(_installs.count>1){NSPopUpButton *list=[NSPopUpButton new];[list addItemWithTitle:[self t:@"ManyInstalls"]];
        for(NSDictionary *i in _installs)[list addItemWithTitle:i[@"install"]];[list selectItemAtIndex:_install?[_installs indexOfObject:_install]+1:0];list.target=self;list.action=@selector(chooseRoot:);[location addArrangedSubview:list];
    }else [location addArrangedSubview:BFLabel(_install[@"install"]?:[self t:@"NotSelected"],13,NSFontWeightRegular)];
    if(_install)[location addArrangedSubview:BFLabel([_strings text:@"LabelValue" arguments:@[[self t:@"SaveLocation"],_install[@"save"]]],13,NSFontWeightRegular)];
    NSStackView *buttons=BFStack(NSUserInterfaceLayoutOrientationHorizontal,8);[location addArrangedSubview:buttons];
    [buttons addArrangedSubview:BFButton([self t:@"Locate"],^{[self find:nil];})];[buttons addArrangedSubview:BFButton([self t:@"ChooseInstall"],^{[self pick:YES game:YES done:^(NSString *p){[self find:p];}];})];
    if(!_receiving){
        if(_inventory)[location addArrangedSubview:BFLabel([self summary:_inventory found:YES],14,NSFontWeightMedium)];
        NSStackView *target=[self group:@"SaveTo"];[target addArrangedSubview:BFLabel(_folder,13,NSFontWeightRegular)];
        [target addArrangedSubview:BFButton([self t:@"ChooseFolder"],^{[self pick:YES game:NO done:^(NSString *p){self->_folder=p;[self workspace:@""];}];})];
    }else{
        NSStackView *file=[self group:@"Package"];[file addArrangedSubview:BFLabel(_package.length?_package:[self t:@"NotSelected"],13,NSFontWeightRegular)];
        [file addArrangedSubview:BFButton([self t:@"ChooseFile"],^{[self pick:NO game:NO done:^(NSString *p){[self preview:p];}];})];
        if(_preview)[file addArrangedSubview:BFLabel([self summary:_preview found:NO],14,NSFontWeightMedium)];
    }
    _status.stringValue=message;[_page addArrangedSubview:_status];
    NSButton *go=BFButton([self t:_receiving?@"Replace":@"Extract"],^{[self transfer];});go.bezelColor=NSColor.controlAccentColor;
    go.enabled=_install&&(_receiving?_preview!=nil:[_inventory[@"count"] integerValue]>0);[_page addArrangedSubview:go];
}
- (void)mode:(NSSegmentedControl*)sender {if(!_writing){_receiving=sender.selectedSegment==1;[self workspace:@""];}}
- (void)chooseRoot:(NSPopUpButton*)sender {if(_writing||sender.indexOfSelectedItem<1)return;[self restart];_install=_installs[sender.indexOfSelectedItem-1];_inventory=nil;[self workspace:@""];[self readInventory];}
- (void)find:(NSString*)path {
    if(_writing)return;
    [self restart];_install=nil;_installs=@[];_inventory=nil;[self workspace:[self t:@"Finding"]];
    [self perform:path?@{@"op":@"identify",@"path":path}:@{@"op":@"locate"} done:^(NSArray *found){
        if(!found)return;self->_installs=found;self->_install=found.count==1?found[0]:nil;[self workspace:self->_install?@"":[self t:found.count?@"ManyInstalls":@"NoInstall"]];
        if(self->_install)[self readInventory];
    }];
}
- (void)readInventory {
    [self perform:@{@"op":@"inventory",@"root":_install[@"root"]} done:^(id value){if(value){self->_inventory=value;[self workspace:@""];}}];
}
- (void)pick:(BOOL)folder game:(BOOL)install done:(void(^)(NSString*))done {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseDirectories=folder;panel.canChooseFiles=!folder||install;panel.allowsMultipleSelection=NO;
    if(!folder){UTType *type=[UTType typeWithFilenameExtension:_game[@"ext"]];if(type)panel.allowedContentTypes=@[type];}
    Stop stop=_screen;[panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK&&!*stop)done(panel.URL.path);}];
}
- (void)preview:(NSString*)path {
    if(_writing)return;
    NSUInteger generation=++_previewGeneration;_package=path;_preview=nil;_checksum=@"";[self workspace:[self t:@"Busy"]];
    [self perform:@{@"op":@"preview",@"path":path} done:^(NSDictionary *p){if(p && generation==self->_previewGeneration){self->_preview=p[@"progress"];self->_checksum=p[@"checksum"];[self workspace:@""];}}];
}
- (void)transfer {
    if(_writing||_updates.installing)return;
    _writing=YES;
    NSHashTable<NSControl*> *enabled=[NSHashTable weakObjectsHashTable];
    NSMutableArray<NSView*> *views=[NSMutableArray arrayWithObject:_split.view];
    while(views.count){
        NSView *view=views.lastObject;[views removeLastObject];[views addObjectsFromArray:view.subviews];
        if([view isKindOfClass:NSControl.class] && [(NSControl*)view isEnabled]){
            [enabled addObject:(NSControl*)view];[(NSControl*)view setEnabled:NO];
        }
    }
    _status.stringValue=[self t:@"Busy"];[_window.toolbar validateVisibleItems];
    NSDictionary *op=_receiving?@{@"op":@"import",@"root":_install[@"root"],@"path":_package,@"checksum":_checksum}:@{@"op":@"export",@"root":_install[@"root"],@"folder":_folder,@"title":[self name:_game]};
    [self perform:op done:^(id result){
        self->_writing=NO;for(NSControl *control in enabled)control.enabled=YES;
        [self->_window.toolbar validateVisibleItems];if(!result)return;
        NSString *folder=self->_receiving?self->_package.stringByDeletingLastPathComponent:self->_folder;
        [self->_prefs.folders addObject:folder];[self->_prefs save];
        NSString *success=self->_receiving?[self t:@"Imported"]:[self format:@"Exported" arg:result];
        if(self->_receiving)[self perform:@{@"op":@"inventory",@"root":self->_install[@"root"]} done:^(id p){if(p){self->_inventory=p;[self workspace:success];}}];
        [self workspace:success];
        [self->_updates applyAutomaticIfReady];
    }];
}
- (void)timeline:(NSString*)folder {
    [self restart];[self startPage:[self name:_game]];[_page addArrangedSubview:BFLabel([self t:@"Timeline"],18,NSFontWeightSemibold)];
    NSStackView *line=BFStack(NSUserInterfaceLayoutOrientationHorizontal,8);[_page addArrangedSubview:line];
    [line addArrangedSubview:BFButton([self t:@"Refresh"],^{[self timeline:folder];})];
    [line addArrangedSubview:BFButton([self t:@"ChooseFolder"],^{[self pick:YES game:NO done:^(NSString *p){[self timeline:p];}];})];
    if(folder){[line addArrangedSubview:BFButton([self t:@"ResetFolder"],^{[self timeline:nil];})];[_page addArrangedSubview:BFLabel(folder,13,NSFontWeightRegular)];}
    _status.stringValue=[self t:@"Loading"];[_page addArrangedSubview:_status];
    NSMutableOrderedSet *dirs=[NSMutableOrderedSet orderedSetWithObject:_prefs.destination];[dirs unionOrderedSet:_prefs.folders];
    [self perform:@{@"op":@"timeline",@"folders":folder?@[folder]:dirs.array} done:^(NSDictionary *result){
        if(!result)return;NSArray *rows=result[@"rows"];NSMutableArray *notes=[NSMutableArray array];
        if(!rows.count)[notes addObject:[self t:@"TimelineEmpty"]];
        if([result[@"skipped"] integerValue])[notes addObject:[self format:@"Skipped" arg:result[@"skipped"]]];
        self->_status.stringValue=[notes componentsJoinedByString:@"\n"];self->_status.hidden=!notes.count;
        NSDateFormatter *date=[NSDateFormatter new];date.locale=self->_strings.locale;date.dateStyle=NSDateFormatterMediumStyle;date.timeStyle=NSDateFormatterMediumStyle;
        for(NSDictionary *row in rows){
            int64_t ms=[row[@"created"] longLongValue];NSString *stamp=ms?[date stringFromDate:[NSDate dateWithTimeIntervalSince1970:ms/1000.0]]:[self t:@"NoTime"];
            NSStackView *group=BFStack(NSUserInterfaceLayoutOrientationVertical,4);[self->_page addArrangedSubview:group];
            [group addArrangedSubview:BFLabel(row[@"name"],14,NSFontWeightSemibold)];group.toolTip=row[@"path"];
            [group addArrangedSubview:BFLabel([self->_strings text:@"LabelValue" arguments:@[[self t:@"Generated"],stamp]],13,NSFontWeightRegular)];
            NSString *time=row[@"progress"][@"playtime"];[group addArrangedSubview:BFLabel([self->_strings text:@"LabelValue" arguments:@[[self t:@"Playtime"],time.length?time:[self t:@"Unknown"]]],13,NSFontWeightRegular)];
        }
    }];
}
- (void)settings {
    [self startPage:[self t:@"Settings"]];NSStackView *language=[self group:@"Language"];NSPopUpButton *select=[NSPopUpButton new];
    for(NSString *key in @[@"System",@"Chinese",@"English"])[select addItemWithTitle:[self t:key]];
    NSArray *tags=@[@"system",@"zh-Hans",@"en"];NSUInteger i=[tags indexOfObject:_prefs.language];[select selectItemAtIndex:i==NSNotFound?0:i];select.target=self;select.action=@selector(setLanguage:);[language addArrangedSubview:select];
    [language addArrangedSubview:BFLabel([self t:@"SystemLanguageNote"],12,NSFontWeightRegular)];
    NSStackView *folder=[self group:@"DefaultFolder"];[folder addArrangedSubview:BFLabel(_prefs.destination,13,NSFontWeightRegular)];
    NSStackView *buttons=BFStack(NSUserInterfaceLayoutOrientationHorizontal,8);[folder addArrangedSubview:buttons];
    [buttons addArrangedSubview:BFButton([self t:@"ChooseFolder"],^{[self pick:YES game:NO done:^(NSString *p){self->_prefs.folder=p;[self->_prefs save];[self settings];}];})];
    [buttons addArrangedSubview:BFButton([self t:@"ResetFolder"],^{self->_prefs.folder=@"";[self->_prefs save];[self settings];})];
    NSStackView *visible=[self group:@"VisibleGames"];
    for(NSDictionary *game in _catalog){
        NSButton *check=[NSButton checkboxWithTitle:[self name:game] target:self action:@selector(toggleGame:)];
        check.identifier=game[@"id"];check.state=[_prefs.hidden containsObject:game[@"id"]]?NSControlStateValueOff:NSControlStateValueOn;[visible addArrangedSubview:check];
    }
    _updateGroup=[self group:@"Updates"];[self showUpdates];
}
- (void)toggleGame:(NSButton*)sender {
    if(sender.state==NSControlStateValueOn)[_prefs.hidden removeObject:sender.identifier];else [_prefs.hidden addObject:sender.identifier];[_prefs save];
}
- (void)setLanguage:(NSPopUpButton*)sender{
    _prefs.language=@[@"system",@"zh-Hans",@"en"][sender.indexOfSelectedItem];[_prefs save];[_strings setLanguage:_prefs.language];[self menu];[self enter:@"settings"];
}
- (void)showUpdates {
    if(![_section isEqual:@"settings"]||!_updateGroup)return;
    for(NSView *view in _updateGroup.arrangedSubviews.copy)[view removeFromSuperview];
    [_updateGroup addArrangedSubview:BFLabel([self t:@"Updates"],14,NSFontWeightSemibold)];
    NSArray *keys=@[@"UpdateAutoCheck",@"UpdateAutoDownload",@"UpdateAutoInstall"];
    NSArray *properties=@[@"autoCheck",@"autoDownload",@"autoInstall"];
    for(NSUInteger i=0;i<keys.count;++i){
        NSButton *toggle=[NSButton checkboxWithTitle:[self t:keys[i]] target:self action:@selector(updateToggle:)];
        toggle.identifier=properties[i];toggle.state=[[_prefs valueForKey:properties[i]] boolValue]?NSControlStateValueOn:NSControlStateValueOff;
        [_updateGroup addArrangedSubview:toggle];
    }
    [_updateGroup addArrangedSubview:BFLabel([self t:@"UpdateChannel"],13,NSFontWeightMedium)];
    NSPopUpButton *channel=[NSPopUpButton new];[channel addItemsWithTitles:@[[self t:@"Stable"],[self t:@"Beta"]]];
    [channel selectItemAtIndex:[_prefs.channel isEqual:@"Beta"]?1:0];channel.target=self;channel.action=@selector(updateChannel:);
    channel.enabled=!_updates.installing;[_updateGroup addArrangedSubview:channel];
    [_updateGroup addArrangedSubview:BFLabel([self t:@"UpdateChannelsHelp"],13,NSFontWeightRegular)];
    NSString *mode=[self t:_updates.installed?@"Installed":@"Portable"];
    [_updateGroup addArrangedSubview:BFLabel([_strings text:@"UpdateBuild" arguments:@[BFUpdates.version,mode]],13,NSFontWeightMedium)];
    NSString *status=[_updates.status isEqual:@"UpdateAvailable"]?[self format:@"UpdateAvailable" arg:_updates.candidate[@"version"]]:[self t:_updates.status];
    [_updateGroup addArrangedSubview:BFLabel(status,13,NSFontWeightRegular)];
    if(_prefs.lastCheck){
        NSDateFormatter *date=[NSDateFormatter new];date.locale=_strings.locale;date.dateStyle=NSDateFormatterShortStyle;date.timeStyle=NSDateFormatterShortStyle;
        [_updateGroup addArrangedSubview:BFLabel([self format:@"UpdateLast" arg:[date stringFromDate:_prefs.lastCheck]],12,NSFontWeightRegular)];
    }
    NSStackView *buttons=BFStack(NSUserInterfaceLayoutOrientationHorizontal,8);[_updateGroup addArrangedSubview:buttons];
    NSButton *check=BFButton([self t:@"UpdateCheck"],^{[self->_updates check];});check.enabled=!_updates.busy;[buttons addArrangedSubview:check];
    if(!_updates.busy&&_updates.candidate){
        if(!_updates.download)[buttons addArrangedSubview:BFButton([self t:@"UpdateDownload"],^{[self->_updates downloadUpdate];})];
        else{
            [buttons addArrangedSubview:BFButton([self t:@"UpdateInstall"],^{[self->_updates install];})];
            [buttons addArrangedSubview:BFButton([self t:@"UpdateShow"],^{[self->_updates reveal];})];
        }
    }
}
- (void)updateToggle:(NSButton*)sender {
    [_prefs setValue:@(sender.state==NSControlStateValueOn) forKey:sender.identifier];[_prefs save];[_updates applyAutomaticIfReady];
}
- (void)updateChannel:(NSPopUpButton*)sender {
    _prefs.channel=sender.indexOfSelectedItem==1?@"Beta":@"Stable";[_prefs save];[_updates cancel];if(_prefs.autoCheck)[_updates check];
}


- (BOOL)windowShouldClose:(NSWindow*)w{return !_writing&&!_updates.installing;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)app{return (_writing||_updates.installing)?NSTerminateCancel:NSTerminateNow;}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app{return YES;}
@end
int main(){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];Bonfire *delegate=[Bonfire new];app.delegate=delegate;[app run];}return 0;}
