#import "RimeBridge.h"
#include <stdlib.h>
#include "rime_api.h"

static RimeApi *api;
// Bumped by +invalidateSessions. Sessions carry the generation they were created
// in, so a session predating a word list change is replaced rather than reused.
static NSUInteger generation = 1;

static void fillTraits(RimeTraits *traits, NSString *shared, NSString *user) {
    traits->shared_data_dir = shared.UTF8String;
    traits->user_data_dir = user.UTF8String;
    traits->distribution_name = "LocalInput";
    traits->distribution_code_name = "localinput";
    traits->distribution_version = "0.1.0";
    traits->app_name = "rime.localinput";
    // Loading "plugins" is what dlopens Contents/Frameworks/rime-plugins,
    // where the octagram grammar module lives.
    static const char *modules[] = { "default", "plugins", NULL };
    traits->modules = modules;
    // Diagnostics stay opt-in: by default nothing is written anywhere.
    const char *level = getenv("LOCALINPUT_RIME_LOG_LEVEL");
    const char *directory = getenv("LOCALINPUT_RIME_LOG_DIR");
    traits->min_log_level = level ? atoi(level) : 3;
    traits->log_dir = directory ?: "";
    // Plugin dylibs carry their own glog copy that librime never initializes, so
    // without this they write INFO lines to stderr whatever the traits say.
    setenv("GLOG_minloglevel", level ?: "3", 0);
}

@implementation LIRime {
    RimeSessionId _session;
    NSUInteger _generation;
}
+ (void)startShared:(NSString *)shared user:(NSString *)user deploy:(BOOL)deploy {
    api = rime_get_api();
    RIME_STRUCT(RimeTraits, traits);
    fillTraits(&traits, shared, user);
    api->setup(&traits);
    api->initialize(&traits);
    if (deploy && api->start_maintenance(True)) api->join_maintenance_thread();
}
+ (void)invalidateSessions {
    if (!api) return;
    // Rime keeps the phrase table open while any session still uses the schema,
    // and this process holds one session per input client, so every session has
    // to go before the file is read again.
    api->cleanup_all_sessions();
    generation += 1;
}
+ (void)shutdown { if (api) api->finalize(); }
// Zero while the session is stale, so no key reaches a session built from an
// outdated word list. -open is what brings it back.
- (RimeSessionId)session { return _generation == generation ? _session : 0; }
- (BOOL)open {
    // cleanup_all_sessions has already dropped it librime-side.
    if (_session && _generation != generation) { _session = 0; }
    _generation = generation;
    if (_session) return YES;
    _session = api->create_session();
    if (!_session) return NO;
    if (!api->select_schema(_session, "luna_pinyin_simp")) {
        api->destroy_session(_session); _session = 0; return NO;
    }
    api->set_option(_session, "ascii_mode", False);
    api->set_option(_session, "simplification", True);
    return YES;
}
- (void)dealloc { RimeSessionId session = self.session; if (session) api->destroy_session(session); }
- (BOOL)process:(int)key modifiers:(int)modifiers {
    RimeSessionId session = self.session;
    return session && api->process_key(session, key, modifiers);
}
- (NSDictionary *)snapshot {
    RimeSessionId session = self.session;
    RIME_STRUCT(RimeContext, ctx);
    if (!session || !api->get_context(session, &ctx)) return @{};
    NSString *preedit = ctx.composition.preedit ? @(ctx.composition.preedit) : @"";
    NSInteger caret = preedit.length;
    if (ctx.composition.preedit) {
        size_t bytes = MIN(MAX(ctx.composition.cursor_pos, 0), strlen(ctx.composition.preedit));
        NSString *prefix = [[NSString alloc] initWithBytes:ctx.composition.preedit length:bytes encoding:NSUTF8StringEncoding];
        if (prefix) caret = prefix.length;
    }
    NSMutableArray *candidates = [NSMutableArray array];
    for (int i = 0; i < ctx.menu.num_candidates; ++i) {
        [candidates addObject:@(ctx.menu.candidates[i].text ?: "")];
    }
    NSDictionary *result = @{ @"preedit": preedit, @"caret": @(caret), @"candidates": candidates,
      @"highlight": @(ctx.menu.highlighted_candidate_index), @"page": @(ctx.menu.page_no),
      @"lastPage": @(ctx.menu.is_last_page) };
    api->free_context(&ctx);
    return result;
}
- (NSString *)takeCommit {
    RimeSessionId session = self.session;
    RIME_STRUCT(RimeCommit, commit);
    if (!session || !api->get_commit(session, &commit)) return @"";
    NSString *text = @(commit.text ?: "");
    api->free_commit(&commit);
    return text;
}
- (NSString *)rawInput {
    RimeSessionId session = self.session;
    const char *s = session ? api->get_input(session) : NULL;
    return @(s ?: "");
}
// Consume the typed spelling without selecting or learning a Chinese candidate.
- (NSString *)takeRawInput {
    NSString *text = [[self rawInput] copy];
    [self clear];
    return text;
}
- (void)clear { RimeSessionId session = self.session; if (session) api->clear_composition(session); }
- (void)commit { RimeSessionId session = self.session; if (session) api->commit_composition(session); }
- (void)select:(NSUInteger)index {
    RimeSessionId session = self.session;
    if (session) api->select_candidate_on_current_page(session, index);
}
@end
