#import "RimeBridge.h"

static void check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void type(LIRime *engine, NSString *input) {
    for (NSUInteger i = 0; i < input.length; i++) [engine process:[input characterAtIndex:i] modifiers:0];
}
int main(int argc, char **argv) { @autoreleasepool {
    check(argc == 3, @"shared and fresh user directory required");
    [LIRime startShared:@(argv[1]) user:@(argv[2]) deploy:NO];
    LIRime *full = [LIRime new], *doublePinyin = [LIRime new];
    check([full open], @"legacy open still selects full pinyin");
    type(full, @"nihao");
    check([doublePinyin openSchema:@"double_pinyin_flypy"], @"bundled Xiaohe schema opens");
    NSDictionary *examples = @{@"nihc": @"你好", @"vswf": @"中文", @"nv": @"女", @"er": @"儿"};
    for (NSString *input in examples) {
        type(doublePinyin, input);
        check([[doublePinyin candidatePool:20] containsObject:examples[input]],
              [@"double-pinyin decoding: " stringByAppendingString:input]);
        [doublePinyin clear];
    }
    type(doublePinyin, @"ni'hc");
    NSArray *choices = [doublePinyin candidatePool:20];
    NSUInteger hello = [choices indexOfObject:@"你好"];
    check(hello != NSNotFound, @"apostrophe syllable separator works");
    [doublePinyin selectGlobal:hello];
    check([[doublePinyin takeCommit] isEqual:@"你好"], @"candidate selection commits Chinese");
    check([[full rawInput] isEqual:@"nihao"], @"other client's full-pinyin composition survives");
    type(doublePinyin, @"nihc");
    [doublePinyin process:0xff08 modifiers:0];
    check([[doublePinyin rawInput] isEqual:@"nih"], @"backspace edits raw double-pinyin codes");
    check([doublePinyin openSchema:@"double_pinyin_flypy"] && [[doublePinyin rawInput] isEqual:@"nih"],
          @"reopening the same scheme keeps composition");
    check([doublePinyin openSchema:@"luna_pinyin_simp"], @"switch back to full pinyin");
    check([[doublePinyin takeCommit] isEqual:@""] && [[doublePinyin rawInput] isEqual:@""],
          @"switching never commits or reinterprets stale raw codes");
    type(doublePinyin, @"nihao");
    [doublePinyin process:32 modifiers:0];
    check([[doublePinyin takeCommit] isEqual:@"你好"], @"full-pinyin conversion still works after switching");
    check(![doublePinyin openSchema:@"../../missing"], @"unknown scheme cannot select arbitrary config");
    check([[full rawInput] isEqual:@"nihao"], @"invalid scheme does not disturb other sessions");
    [LIRime invalidateSessions];
    check([full open] && [doublePinyin openSchema:@"double_pinyin_flypy"], @"both layouts reopen after vocabulary changes");
    type(doublePinyin, @"nihc");
    check([[doublePinyin takeRawInput] isEqual:@"nihc"] && [[doublePinyin takeCommit] isEqual:@""],
          @"switching to English preserves exact double-pinyin keys without committing Chinese");
    full = nil; doublePinyin = nil;
    [LIRime shutdown];
    puts("PASS: real Xiaohe double-pinyin decoding, selection, separators, editing, layout switching and client isolation");
}}
