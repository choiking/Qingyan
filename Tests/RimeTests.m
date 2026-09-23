#import "RimeBridge.h"
static void check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void type(LIRime *engine, const char *text) {
    for (const char *p = text; *p; p++) [engine process:*p modifiers:0];
}
int main(int argc, char **argv) { @autoreleasepool {
    check(argc == 3, @"data and user directories required");
    NSString *user = @(argv[2]);
    NSString *table = [user stringByAppendingPathComponent:@"custom_phrase.txt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:NULL];
    // Written in the format Sources/Shared/RimeCustomPhrases.swift generates.
    check([@"# test\n\u5357\u751f\u56fe\tnanshengtu\t2\n" writeToFile:table atomically:YES
        encoding:NSUTF8StringEncoding error:NULL], @"custom phrase table written");
    [LIRime startShared:@(argv[1]) user:user deploy:NO];
    LIRime *engine = [LIRime new];
    check([engine open], @"schema opens from bundled prebuilt data");
    type(engine, "nihao");
    NSArray *candidates = [engine snapshot][@"candidates"];
    check([candidates containsObject:@"你好"], @"nihao contains 你好");
    [engine process:32 modifiers:0];
    check([[engine takeCommit] isEqual:@"你好"], @"Space commits 你好");
    check([[engine rawInput] isEqual:@""], @"commit clears composition");
    type(engine, "zhongwen");
    check([[engine snapshot][@"candidates"] containsObject:@"中文"], @"whole word conversion");
    [engine process:0xff1b modifiers:0];
    check([[engine rawInput] isEqual:@""], @"Escape cancels");
    type(engine, "ni");
    NSString *second = [engine snapshot][@"candidates"][1];
    [engine select:1];
    check([[engine takeCommit] isEqual:second], @"candidate index selection");
    type(engine, "ni");
    [engine process:0xff56 modifiers:0];
    check([[engine snapshot][@"page"] intValue] == 1, @"page down");
    [engine process:0xff55 modifiers:0];
    check([[engine snapshot][@"page"] intValue] == 0, @"page up");
    [engine process:0xff08 modifiers:0];
    check([[engine rawInput] isEqual:@"n"], @"backspace edits composition");
    [engine clear];
    type(engine, "hanyu");
    check([[engine snapshot][@"candidates"] containsObject:@"汉语"], @"simplified Chinese conversion");
    [engine clear];
    type(engine, "youxiang");
    NSArray<NSString *> *pool = [engine candidatePool:20];
    check(pool.count <= 20 && pool.count > 5, @"Jev has a bounded pool beyond the visible page");
    for (NSString *word in @[@"油箱", @"邮箱", @"又想"]) {
        check([pool containsObject:word], [@"Jev candidate coverage: " stringByAppendingString:word]);
    }
    check([[engine snapshot][@"page"] intValue] == 0, @"pool lookup does not move Rime page");
    NSDictionary *beforeCoverage = [engine snapshot];
    NSArray<NSDictionary *> *details = [engine candidateDetails:20];
    check(details.count == pool.count, @"every candidate has exact Rime coverage");
    for (NSDictionary *item in details) {
        NSString *word = item[@"text"];
        if ([@[@"油箱", @"邮箱", @"又想"] containsObject:word]) {
            check([item[@"coverageEnd"] intValue] == 8 && [item[@"remainingInput"] isEqual:@""], @"full youxiang candidates cover all input");
        } else if ([@[@"游戏", @"有戏", @"右席"] containsObject:word]) {
            check([item[@"coverageEnd"] intValue] == 5 && [item[@"remainingInput"] isEqual:@"ang"], @"youxi candidates leave ang unconverted");
        } else if ([word isEqual:@"有"]) {
            check([item[@"coverageEnd"] intValue] == 3 && [item[@"remainingInput"] isEqual:@"xiang"], @"single syllable candidate leaves xiang");
        }
    }
    check([[engine snapshot] isEqual:beforeCoverage], @"coverage probing restores page, highlight, preedit and caret");
    check([[engine takeCommit] isEqual:@""], @"coverage probing never commits or learns a choice");
    check([[engine candidateDetails:20] isEqual:details], @"repeated coverage reads are stable");
    NSUInteger promoted = [pool indexOfObject:@"又想"];
    [engine selectGlobal:promoted];
    check([[engine takeCommit] isEqual:@"又想"], @"promoted Rime index commits the displayed word");
    [engine clear];
    type(engine, "youxiang");
    NSArray *partialPool = [engine candidatePool:20];
    [engine selectGlobal:[partialPool indexOfObject:@"有"]];
    NSDictionary *partialBefore = [engine snapshot];
    NSArray *partialDetails = [engine candidateDetails:20];
    check(partialDetails.count > 0, @"coverage works after a partial candidate has been selected");
    for (NSDictionary *item in partialDetails) {
        check([item[@"coverageEnd"] intValue] > 3 && [item[@"coverageEnd"] intValue] <= 8, @"coverage offsets remain relative to raw input after selected Chinese prefix");
    }
    check([[engine snapshot] isEqual:partialBefore] && [[engine takeCommit] isEqual:@""], @"reading coverage preserves selected Chinese prefix");
    [engine clear];
    type(engine, "you'xiang");
    NSArray *apostropheDetails = [engine candidateDetails:20];
    check(apostropheDetails.count > 0, @"apostrophe-delimited spelling supports coverage");
    for (NSDictionary *item in apostropheDetails) {
        if ([item[@"text"] isEqual:@"油箱"]) check([item[@"coverageEnd"] intValue] == 9, @"coverage counts actual raw input including delimiter");
    }
    [engine process:0xff56 modifiers:0];
    NSDictionary *pageBefore = [engine snapshot];
    check([engine candidateDetails:20].count > 0 && [[engine snapshot] isEqual:pageBefore], @"coverage lookup restores a nonzero page and highlight");
    [engine process:0xff51 modifiers:0];
    NSDictionary *caretBefore = [engine snapshot];
    check([engine candidateDetails:20].count == 0 && [[engine snapshot] isEqual:caretBefore], @"mid-input editing conservatively keeps native ranking");
    [engine clear];
    // These entries come from the pinned upstream Ice dictionaries, not an
    // application-maintained hotword list. Exercise the compiled translator.
    NSDictionary *modernWords = @{
        @"laodeng": @"老登", @"xianyanbao": @"显眼包",
        @"qingxujiazhi": @"情绪价值", @"songchigan": @"松弛感"
    };
    for (NSString *spelling in modernWords) {
        type(engine, spelling.UTF8String);
        check([[engine snapshot][@"candidates"] containsObject:modernWords[spelling]],
              [@"Ice vocabulary on first page: " stringByAppendingString:modernWords[spelling]]);
        [engine clear];
    }
    type(engine, "hanyu");
    LIRime *other = [LIRime new];
    check([other open], @"second client session");
    check([[other rawInput] isEqual:@""], @"client sessions do not share composition");
    check([[engine rawInput] isEqual:@"hanyu"], @"original composition preserved");
    [engine clear];
    for (NSString *spelling in @[@"hello", @"nihao", @"xian"]) {
        type(engine, spelling.UTF8String);
        check([[engine rawInput] isEqual:spelling], @"pending spelling retained before Shift");
        check([[engine takeRawInput] isEqual:spelling], @"switching to English returns exact letters without preedit spacing");
        check([[engine rawInput] isEqual:@""], @"English switch clears Rime composition");
        check([[engine takeCommit] isEqual:@""], @"English switch never commits a Chinese candidate");
        check([[engine snapshot][@"preedit"] length] == 0, @"English switch withdraws candidates");
        check([[engine takeRawInput] isEqual:@""], @"mode switching again cannot duplicate old input");
    }
    type(engine, "hellop");
    [engine process:0xff08 modifiers:0];
    check([[engine takeRawInput] isEqual:@"hello"], @"edited spelling is used when switching");
    type(engine, "nihao");
    [engine process:32 modifiers:0];
    check([[engine takeCommit] isEqual:@"你好"], @"Chinese conversion still works after mode switch reset");
    [engine clear];
    // The octagram grammar model decides these; on unigram weights alone they
    // come out as 握住在哪里 and 我的名字角力小明.
    type(engine, "wozhuzainali");
    check([[engine snapshot][@"candidates"][0] hasPrefix:@"\u6211\u4f4f\u5728"], @"grammar model prefers 我住在 over 握住");
    [engine clear];
    type(engine, "wodemingzijiaolixiaoming");
    check([[engine snapshot][@"candidates"][0] hasPrefix:@"\u6211\u7684\u540d\u5b57\u53eb"], @"grammar model prefers 叫 over 角力");
    [engine clear];
    // The user's own words outrank the dictionary, and an edited list reaches
    // open sessions only once they are invalidated.
    type(engine, "nanshengtu");
    check([[engine snapshot][@"candidates"][0] isEqual:@"\u5357\u751f\u56fe"], @"custom phrase outranks the dictionary");
    [engine clear];
    check([@"# test\n\u56fe\u5357\u751f\tnanshengtu\t2\n" writeToFile:table atomically:YES
        encoding:NSUTF8StringEncoding error:NULL], @"custom phrase table replaced");
    type(engine, "nanshengtu");
    check([[engine snapshot][@"candidates"][0] isEqual:@"\u5357\u751f\u56fe"], @"an open session keeps the list it was created with");
    [engine clear];
    [LIRime invalidateSessions];
    check([engine open], @"session is rebuilt after invalidation");
    type(engine, "nanshengtu");
    check([[engine snapshot][@"candidates"][0] isEqual:@"\u56fe\u5357\u751f"], @"an invalidated session picks up the edited list");
    [engine clear];
    puts("PASS: Ice dictionary and modern vocabulary, phrase conversion, simplified output, selection, paging, deletion, cancellation, session isolation, grammar model, custom phrases");
} }
