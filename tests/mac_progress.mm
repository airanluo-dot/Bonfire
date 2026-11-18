#import "../macos/Presentation.h"
#include <cstdio>

int main() { @autoreleasepool {
    BFStrings *strings=[BFStrings new];
    for(NSString *language in @[@"en",@"zh-Hans"]){
        [strings setLanguage:language];
        NSString *(^t)(NSString*)=^NSString*(NSString *key){return [strings text:key arguments:@[]];};
        NSString *(^line)(NSDictionary*,BOOL)=^NSString*(NSDictionary *progress,BOOL found){
            return [strings progressSummary:progress found:found];
        };
        NSString *count=[strings text:@"ManyProgress" arguments:@[@3]];
        NSString *stamp=@"2026-11-17 19:33", *chapter=t(@"Emberbound_Part2");
        if(!chapter.length || [chapter isEqual:@"Emberbound_Part2"] ||
           ![line(@{@"count":@0},YES) isEqual:t(@"NoneProgress")] ||
           ![line(@{@"count":@0,@"persistent":@YES},NO) isEqual:t(@"PersistentOnly")] ||
           ![line(@{@"count":@1},NO) isEqual:t(@"OneProgress")] ||
           ![line(@{@"count":@3},YES) isEqual:[strings text:@"Found" arguments:@[count]]]) return 1;
        NSDictionary *saved=@{@"count":@3,@"slot":@"auto-1",@"savedLocalTime":stamp,@"chapterKey":@"Emberbound_Part2"};
        NSString *summary=line(saved,NO);
        NSDateFormatter *date=[NSDateFormatter new];
        date.locale=strings.locale;date.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
        date.dateStyle=NSDateFormatterShortStyle;date.timeStyle=NSDateFormatterShortStyle;
        NSString *local=[date stringFromDate:[NSDate dateWithTimeIntervalSince1970:1794943980]];
        if(![line(@{@"count":@3,@"savedLocalTime":@"2026-11-35 08:11"},NO) isEqual:count] ||
           ![summary containsString:count] || ![summary containsString:chapter] || ![summary containsString:local] ||
           ![summary containsString:t(@"LastSaveLabel")] || [summary containsString:t(@"Playtime")]) return 1;
        NSMutableDictionary *clock=[saved mutableCopy];
        clock[@"playtime"]=@"01:04:17";
        summary=line(clock,YES);
        if(![summary containsString:chapter] || ![summary containsString:@"01:04:17"] ||
           ![summary containsString:[strings text:@"SlotPlaytime" arguments:@[@"auto-1"]]] || [summary containsString:local]) return 1;
    }
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    std::puts("Native progress summaries in Chinese and English: OK");
    return 0;
} }
