// Native-layout fixture only: never links or invokes BG3 functions.
#import "../src/NativeMenu.mm"
#include <cstdio>
#include <vector>
BOOL BG3MFXInstallNativeJitter(intptr_t, void (*)(NSDictionary *), NSError **) { return YES; }
static NSMutableArray *events;
static void collect(NSDictionary *value) { [events addObject:value]; }
static unsigned initCalls, applyCalls, upscaleCalls, qualityCalls;
static void fakeInit(void *) { ++initCalls; }
static void fakeApply(void *, const void *) { ++applyCalls; }
static void fakeUpscale(void *, const void *) { ++upscaleCalls; }
static void fakeQuality(void *, const void *) { ++qualityCalls; }
#define CHECK(value) do { if (!(value)) { fprintf(stderr,"failed line %d: %s\n",__LINE__,#value); return 1; } } while (0)
int main() {
    @autoreleasepool {
        events = [NSMutableArray array]; reportEvent = collect;
#ifndef BG3MFX_NO_TRACE
        for (const char *value : {"", "0", "true", "01"}) {
            setenv("BG3MFX_MENU_PROBE",value,1);
            menuProbe("disabled",nullptr,nullptr,false);
        }
        unsetenv("BG3MFX_MENU_PROBE"); menuProbe("unset",nullptr,nullptr,false);
        CHECK(events.count == 0);
#endif
        setenv("BG3MFX_MENU_PROBE","1",1);
        std::vector<uint8_t> manager(0x100), display(0xe0), aa(0xe0), upscale(0xe0), quality(0xe0), hud(0xe0), fg(0xe0);
        void *items[] = {display.data(),aa.data(),upscale.data(),quality.data(),hud.data(),fg.data()};
        field<void **>(manager.data(),0x30) = items;
        field<uint32_t>(manager.data(),0x3c) = 6;
        const uint16_t ids[] = {1,98,99,100,hudID,frameGenerationID};
        for (unsigned i=0;i<6;++i) {
            field<uint8_t>(items[i],8) = i < 4 ? 3 : 1;
            field<uint16_t>(items[i],0x88) = ids[i];
            field<uint8_t>(items[i],0x2c) = 1;
        }
        originalApplyCombo = fakeApply; originalInit = fakeInit;
        originalUpscaleCall = fakeUpscale; originalQualityCall = fakeQuality;
        // Native AA Apply must still delegate once and leave its value untouched.
        applyCombo(manager.data(),aa.data());
        // Null storage takes the existing pass-through paths, avoiding game calls.
        upscaleChanged(nullptr,upscale.data()); qualityChanged(nullptr,quality.data());
        CHECK(applyCalls == 1 && upscaleCalls == 1 && qualityCalls == 1);
        CHECK(field<int32_t>(aa.data(),0xd0) == 0);
#ifndef BG3MFX_NO_TRACE
        CHECK(events.count == 6);
        CHECK([events[0][@"phase"] isEqual:@"applyCombo"]);
        CHECK([events[1][@"phase"] isEqual:@"exit"]);
        CHECK([events[1][@"context"] isEqual:@"applyCombo"]);
        CHECK([events[0][@"controls"] count] == 6);
        CHECK([events[0][@"control"][@"id"] intValue] == 98);
        uint64_t previous = 0; double time = 0;
        for (NSDictionary *event in events) {
            CHECK([event[@"event"] isEqual:@"nativeMenuProbeCallback"]);
            CHECK([event[@"sequence"] unsignedLongLongValue] > previous);
            CHECK([event[@"monotonicSeconds"] doubleValue] >= time);
            CHECK(event[@"manager"] && event[@"item"] && event[@"mainThread"]);
            CHECK([NSJSONSerialization isValidJSONObject:event]);
            previous = [event[@"sequence"] unsignedLongLongValue];
            time = [event[@"monotonicSeconds"] doubleValue];
        }
#else
        CHECK(events.count == 0); // The flag cannot enable quiet-runtime probes.
#endif
        [events removeAllObjects];
#ifndef BG3MFX_NO_TRACE
        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:0 timestamp:0 windowNumber:0 context:nil
            characters:@"private typed text" charactersIgnoringModifiers:@"private typed text"
            isARepeat:NO keyCode:12];
        CHECK(key && probeInput(key) == key);
        CHECK(events.count == 1 && [events[0][@"event"] isEqual:@"nativeMenuProbeInput"]);
        CHECK([events[0] count] == 9 && [NSJSONSerialization isValidJSONObject:events[0]]);
        NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:events[0] options:0 error:nil]
            encoding:NSUTF8StringEncoding];
        CHECK(![json containsString:@"private typed text"] && !events[0][@"keyCode"] && !events[0][@"characters"]);
        unsetenv("BG3MFX_MENU_PROBE");
        CHECK(probeInput(key) == key && events.count == 1);
        setenv("BG3MFX_MENU_PROBE","1",1);
        [events removeAllObjects];
        setItemEnabled(aa.data(),1); // Existing enabled value: observation only.
        CHECK(events.count == 2 && [events[0][@"phase"] isEqual:@"setItemEnabled"]);
        [events removeAllObjects];
#endif
        // Exercise Init entry/return/exit on a valid non-Video options pass.
        field<uint32_t>(manager.data(),0x3c) = 0;
        menuInit(manager.data()); CHECK(initCalls == 1);
#ifndef BG3MFX_NO_TRACE
        CHECK(events.count == 4);
        CHECK([events[0][@"phase"] isEqual:@"menuInit"] && !events[0][@"controls"]);
        CHECK([events[1][@"phase"] isEqual:@"originalInitReturned"]);
        CHECK([events[2][@"event"] isEqual:@"nativeMenuDeferred"]);
        CHECK([events[3][@"phase"] isEqual:@"exit"]);
#else
        CHECK(events.count == 1 && [events[0][@"event"] isEqual:@"nativeMenuDeferred"]);
#endif
        puts("Native menu probe gating, schema, and callback delegation passed");
    }
    return 0;
}
