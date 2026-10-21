// bg3mfx: starts Steam's Baldur's Gate 3 with the BG3MFX runtime.
//
// The game is never modified. The launcher finds the Steam copy, checks that
// it is the build the runtime was validated against, and starts it through
// LaunchServices with the runtime injected (DYLD_INSERT_LIBRARIES), so BG3
// keeps its own identity and permissions. From a terminal it prints messages;
// as "BG3MFX.app" (see install-app) it has no window and shows alerts.
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include "common/native/SupportedBuild.h"

#ifndef BG3MFX_VERSION
#define BG3MFX_VERSION "dev"
#endif

static NSString *const LauncherBundleID = @"io.github.andrewtriestocode.bg3mfx";
static NSString *const GameBundleID = @"com.larian.bg3";
static NSString *const SteamBundleID = @"com.valvesoftware.steam";
static NSString *const SteamAppID = @"1086940";
// Baldur's Gate 3 4.1.1.7631656 (Steam), universal executable. The runtime's
// native hooks are specific to this build.
static NSString *const SupportedSHA256 = @BG3MFX_SUPPORTED_SHA256;
static NSString *const SupportedVersion = @BG3MFX_SUPPORTED_VERSION;
static NSString *const RememberedGameKey = @"GamePath";
static NSString *const AppName = @"BG3MFX";

static BOOL appMode;

#pragma mark - Messages

// Terminal: print. App: alert with optional buttons; returns the index chosen.
static NSInteger tell(NSString *title, NSString *detail, NSArray<NSString *> *buttons) {
    if (!appMode) {
        fprintf(stderr, "bg3mfx: %s\n%s%s", title.UTF8String, detail.length ? detail.UTF8String : "", detail.length ? "\n" : "");
        return -1;
    }
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail ?: @"";
    for (NSString *button in buttons.count ? buttons : @[@"OK"]) [alert addButtonWithTitle:button];
    return [alert runModal] - NSAlertFirstButtonReturn;
}

static void say(NSString *message) { if (!appMode) { printf("%s\n", message.UTF8String); fflush(stdout); } }

#pragma mark - Locating things

static NSString *executablePath(void) {
    uint32_t size = 0; _NSGetExecutablePath(NULL, &size);
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    if (_NSGetExecutablePath(buffer.mutableBytes, &size)) return nil;
    char resolved[PATH_MAX];
    return realpath(buffer.bytes, resolved) ? @(resolved) : nil;
}

// Installed layout: <prefix>/bin/bg3mfx and <prefix>/lib/bg3mfx/libBG3MetalFX.dylib.
static NSString *runtimePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"BG3MFX_RUNTIME"];
    if (override.length) return override;
    NSString *bin = executablePath().stringByDeletingLastPathComponent;
    return [[bin.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"lib/bg3mfx"]
        stringByAppendingPathComponent:@"libBG3MetalFX.dylib"];
}

static NSArray<NSString *> *steamLibraries(void) {
    NSString *steam = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
    NSMutableArray *libraries = [NSMutableArray arrayWithObject:steam];
    NSString *vdf = [NSString stringWithContentsOfFile:[steam stringByAppendingPathComponent:@"steamapps/libraryfolders.vdf"]
        encoding:NSUTF8StringEncoding error:nil];
    if (vdf) {
        NSRegularExpression *path = [NSRegularExpression regularExpressionWithPattern:@"\"path\"\\s+\"([^\"]+)\"" options:0 error:nil];
        for (NSTextCheckingResult *match in [path matchesInString:vdf options:0 range:NSMakeRange(0, vdf.length)]) {
            NSString *library = [[vdf substringWithRange:[match rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
            if (![libraries containsObject:library]) [libraries addObject:library];
        }
    }
    return libraries;
}

typedef NS_ENUM(NSInteger, GameStore) { GameStoreUnknown, GameStoreSteam, GameStoreAppStore, GameStoreGOG };

static NSString *gameBundleID(NSString *app) {
    return [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleIdentifier"];
}

static GameStore storeOf(NSString *app) {
    NSFileManager *files = NSFileManager.defaultManager;
    if ([files fileExistsAtPath:[app stringByAppendingPathComponent:@"Contents/_MASReceipt/receipt"]]) return GameStoreAppStore;
    if ([app.stringByStandardizingPath containsString:@"/steamapps/common/"]) return GameStoreSteam;
    for (NSString *name in [files contentsOfDirectoryAtPath:app.stringByDeletingLastPathComponent error:nil])
        if ([name hasPrefix:@"goggame-"]) return GameStoreGOG;
    for (NSString *name in [files contentsOfDirectoryAtPath:[app stringByAppendingPathComponent:@"Contents/Resources"] error:nil])
        if ([name hasPrefix:@"goggame-"]) return GameStoreGOG;
    return GameStoreUnknown;
}

static NSString *findGame(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:LauncherBundleID];
    NSString *remembered = [defaults stringForKey:RememberedGameKey];
    if (remembered && [gameBundleID(remembered) isEqualToString:GameBundleID]) return remembered;
    for (NSString *library in steamLibraries()) {
        NSString *app = [library stringByAppendingPathComponent:@"steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"];
        if ([gameBundleID(app) isEqualToString:GameBundleID]) return app;
    }
    return nil;
}

static NSString *chooseGame(void) {
    if (!appMode) return nil;
    tell(@"Baldur's Gate 3 wasn't found in your Steam libraries.",
         @"Choose \"Baldur's Gate 3.app\" in your Steam library folder. BG3MFX will remember it.", nil);
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.apple.application-bundle"]];
    panel.message = @"Choose Baldur's Gate 3.app";
    if ([panel runModal] != NSModalResponseOK) return nil;
    NSString *app = panel.URL.path;
    if (![gameBundleID(app) isEqualToString:GameBundleID]) {
        tell(@"That isn't Baldur's Gate 3.", @"Choose the game's app, usually in steamapps/common/Baldurs Gate 3.", nil);
        return nil;
    }
    [[[NSUserDefaults alloc] initWithSuiteName:LauncherBundleID] setObject:app forKey:RememberedGameKey];
    return app;
}

#pragma mark - Checks

static NSString *sha256(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    if (stream.streamStatus != NSStreamStatusOpen) return nil;
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    NSMutableData *chunk = [NSMutableData dataWithLength:4 << 20];
    NSInteger read;
    while ((read = [stream read:chunk.mutableBytes maxLength:chunk.length]) > 0) CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)read);
    [stream close];
    if (read < 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *gameExecutable(NSString *app) {
    NSString *name = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleExecutable"];
    if (!name.length || ![name.lastPathComponent isEqualToString:name]) return nil;
    return [[app stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:name];
}

static NSString *gameVersion(NSString *app) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    return info[@"CFBundleVersion"] ?: info[@"CFBundleShortVersionString"] ?: @"unknown";
}

static BOOL running(NSString *bundleID) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count > 0;
}

// Starts the game through Steam without MetalFX (normal launch, Larian launcher included).
static void playWithoutMetalFX(void) {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[@"steam://rungameid/" stringByAppendingString:SteamAppID]]];
}

static BOOL ensureSteam(BOOL dryRun) {
    if (running(SteamBundleID)) return YES;
    if (dryRun) { say(@"Steam: not running (would be started)."); return YES; }
    NSURL *steam = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:SteamBundleID];
    if (!steam) {
        tell(@"Steam isn't installed.", @"BG3MFX supports the Steam version of Baldur's Gate 3.", nil);
        return NO;
    }
    say(@"Starting Steam...");
    [NSWorkspace.sharedWorkspace openApplicationAtURL:steam configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    for (int i = 0; i < 120 && !running(SteamBundleID); ++i) [NSThread sleepForTimeInterval:0.5];
    if (!running(SteamBundleID)) {
        tell(@"Steam didn't start.", @"Start Steam, sign in, and try again.", nil);
        return NO;
    }
    // Give Steam time to sign in; the game connects to it at startup.
    [NSThread sleepForTimeInterval:10];
    return YES;
}

#pragma mark - Commands

static int launch(NSString *appOverride, BOOL dryRun) {
    NSString *app = appOverride ?: findGame() ?: chooseGame();
    if (!app) {
        if (!appMode) tell(@"Baldur's Gate 3 wasn't found in your Steam libraries.",
            @"Install it with Steam, or pass its location with --game \"/path/to/Baldur's Gate 3.app\".", nil);
        return 1;
    }
    if (![gameBundleID(app) isEqualToString:GameBundleID]) {
        tell(@"That isn't Baldur's Gate 3.", app, nil); return 1;
    }
    GameStore store = storeOf(app);
    if (store == GameStoreAppStore || store == GameStoreGOG) {
        NSString *which = store == GameStoreAppStore ? @"Mac App Store" : @"GOG";
        NSString *why = store == GameStoreAppStore
            ? @"macOS doesn't allow add-ons to be loaded into App Store apps."
            : @"Only the Steam version is supported for now.";
        tell([NSString stringWithFormat:@"The %@ version of Baldur's Gate 3 isn't supported.", which], why, nil);
        return 1;
    }
    NSString *executable = gameExecutable(app);
    NSString *expected = dryRun && NSProcessInfo.processInfo.environment[@"BG3MFX_TEST_SUPPORTED_SHA256"]
        ? NSProcessInfo.processInfo.environment[@"BG3MFX_TEST_SUPPORTED_SHA256"] : SupportedSHA256;
    say([NSString stringWithFormat:@"Game: %@ (version %@)", app, gameVersion(app)]);
    NSString *digest = executable ? sha256(executable) : nil;
    if (![digest isEqualToString:expected]) {
        NSString *detail = [NSString stringWithFormat:
            @"This copy is version %@. BG3MFX %s supports version %@. A game update usually needs a BG3MFX update.",
            gameVersion(app), BG3MFX_VERSION, SupportedVersion];
        if (appMode) {
            if (tell(@"This version of Baldur's Gate 3 isn't supported yet.", detail, @[@"Play Without MetalFX", @"Cancel"]) == 0 && !dryRun)
                playWithoutMetalFX();
        } else tell(@"This version of Baldur's Gate 3 isn't supported yet.",
                    [detail stringByAppendingString:@"\nStart the game from Steam to play without MetalFX."], nil);
        return 1;
    }
    NSString *runtime = runtimePath();
    if (![NSFileManager.defaultManager isReadableFileAtPath:runtime]) {
        tell(@"The BG3MFX runtime is missing.", [@"Reinstall BG3MFX. Expected: " stringByAppendingString:runtime], nil);
        return 1;
    }
    if (running(GameBundleID) && !dryRun) {
        tell(@"Baldur's Gate 3 is already running.", @"Quit the game, then start it with BG3MFX.", nil);
        return 1;
    }
    if (!ensureSteam(dryRun)) return 1;

    // Metal loads its HUD only when MTL_HUD_ENABLED is set at launch, so the
    // Show Metal HUD checkbox can toggle it in-game. Start hidden unless the
    // checkbox was left on.
    NSNumber *hud = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("BG3MFXMetalHUD"), (__bridge CFStringRef)GameBundleID));
    NSMutableDictionary *environment = [@{
        @"DYLD_INSERT_LIBRARIES": runtime,
        @"BG3MFX_ENABLE_METALFX": @"1",
        @"SteamAppId": SteamAppID,
        @"SteamGameId": SteamAppID,
        @"MTL_HUD_ENABLED": @"1",
    } mutableCopy];
    if (![hud isKindOfClass:NSNumber.class] || !hud.boolValue) environment[@"MTL_HUD_HIDDEN"] = @"1";
    // Features held back from this release; set the variable to 1 to try one.
    for (NSString *key in @[@"BG3MFX_CHARACTER_CREATION_CRASH_FIX", @"BG3MFX_REDUCE_LOCKING"])
        environment[key] = NSProcessInfo.processInfo.environment[key] ?: @"0";
    NSArray *arguments = @[@"-NoLauncher", @"1"];
    if (dryRun) {
        say([NSString stringWithFormat:@"Runtime: %@", runtime]);
        for (NSString *key in [environment.allKeys sortedArrayUsingSelector:@selector(compare:)])
            say([NSString stringWithFormat:@"Environment: %@=%@", key, environment[key]]);
        say([@"Arguments: " stringByAppendingString:[arguments componentsJoinedByString:@" "]]);
        say(@"Dry run: the game was not started.");
        return 0;
    }
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.environment = environment;
    configuration.arguments = arguments;
    configuration.createsNewApplicationInstance = YES;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:app] configuration:configuration
        completionHandler:^(NSRunningApplication *game, NSError *error) {
            (void)game; failure = error; dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (failure) {
        tell(@"Baldur's Gate 3 couldn't be started.", failure.localizedDescription, nil);
        return 1;
    }
    say(@"Baldur's Gate 3 is starting with MetalFX. Choose the upscaler in Options > Video.");
    return 0;
}

// Homebrew's versioned Cellar path changes on upgrade; its opt path does not.
static NSString *stableExecutable(void) {
    NSString *path = executablePath();
    NSRange cellar = [path rangeOfString:@"/Cellar/bg3mfx/"];
    if (cellar.location == NSNotFound) return path;
    NSString *prefix = [path substringToIndex:cellar.location];
    return [prefix stringByAppendingPathComponent:@"opt/bg3mfx/bin/bg3mfx"];
}

static int installApp(NSString *directory) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *folder = directory ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
    NSString *app = [folder stringByAppendingPathComponent:[AppName stringByAppendingPathExtension:@"app"]];
    NSString *macOS = [app stringByAppendingPathComponent:@"Contents/MacOS"];
    NSError *error = nil;
    if ([files fileExistsAtPath:app] && ![files removeItemAtPath:app error:&error]) {
        tell(@"Couldn't replace the existing app.", error.localizedDescription, nil); return 1;
    }
    if (![files createDirectoryAtPath:macOS withIntermediateDirectories:YES attributes:nil error:&error]) {
        tell(@"Couldn't create the app.", error.localizedDescription, nil); return 1;
    }
    NSDictionary *info = @{
        @"CFBundleIdentifier": LauncherBundleID,
        @"CFBundleName": AppName,
        @"CFBundleDisplayName": AppName,
        @"CFBundleExecutable": @"bg3mfx",
        @"CFBundlePackageType": @"APPL",
        @"CFBundleShortVersionString": @BG3MFX_VERSION,
        @"CFBundleVersion": @BG3MFX_VERSION,
        @"LSMinimumSystemVersion": @"26.0",
        @"LSApplicationCategoryType": @"public.app-category.games",
        // No Dock icon or window: the app only launches the game or shows an alert.
        @"LSUIElement": @YES,
    };
    if (![info writeToURL:[NSURL fileURLWithPath:[app stringByAppendingPathComponent:@"Contents/Info.plist"]] error:&error]) {
        tell(@"Couldn't write the app's Info.plist.", error.localizedDescription, nil); return 1;
    }
    // The app runs the installed command, so `brew upgrade` updates it too.
    NSString *target = stableExecutable();
    if (![files createSymbolicLinkAtPath:[macOS stringByAppendingPathComponent:@"bg3mfx"] withDestinationPath:target error:&error]) {
        tell(@"Couldn't link the app to bg3mfx.", error.localizedDescription, nil); return 1;
    }
    printf("Created %s\nOpen it like any app, or add it to Steam with Games > Add a Non-Steam Game to My Library.\n", app.UTF8String);
    return 0;
}

static void usage(void) {
    printf("bg3mfx %s: MetalFX upscaling and frame generation for Baldur's Gate 3 (Steam)\n\n"
           "Usage:\n"
           "  bg3mfx                 Start Baldur's Gate 3 with MetalFX\n"
           "  bg3mfx install-app     Add \"BG3MFX\" to ~/Applications\n"
           "  bg3mfx --version       Show the version\n\n"
           "Options:\n"
           "  --game PATH            Use this Baldur's Gate 3.app\n"
           "  --dry-run              Check everything, but don't start the game\n\n"
           "Steam must be running (bg3mfx starts it if needed). Choose MetalFX options in\n"
           "the game under Options > Video. Supported game version: %s.\n",
           BG3MFX_VERSION, SupportedVersion.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // The app's executable is a symlink to the installed command, so the
        // kernel reports the command's path; LaunchServices still identifies
        // the app it opened in __CFBundleIdentifier.
        appMode = [NSBundle.mainBundle.bundleIdentifier isEqualToString:LauncherBundleID] ||
            [NSProcessInfo.processInfo.environment[@"__CFBundleIdentifier"] isEqualToString:LauncherBundleID];
        if (appMode) { [NSApplication sharedApplication]; NSApp.activationPolicy = NSApplicationActivationPolicyAccessory; }
        NSString *game = nil, *destination = nil, *command = nil;
        BOOL dryRun = NO;
        for (int i = 1; i < argc; ++i) {
            NSString *argument = @(argv[i]);
            if ([argument isEqualToString:@"--version"] || [argument isEqualToString:@"-v"]) { printf("bg3mfx %s\n", BG3MFX_VERSION); return 0; }
            else if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) { usage(); return 0; }
            else if ([argument isEqualToString:@"--dry-run"]) dryRun = YES;
            else if ([argument isEqualToString:@"--game"] && i + 1 < argc) game = @(argv[++i]);
            else if ([argument isEqualToString:@"--to"] && i + 1 < argc) destination = @(argv[++i]);
            else if ([argument isEqualToString:@"install-app"] && !command) command = argument;
            else if (appMode && [argument hasPrefix:@"-psn"]) continue;
            else { fprintf(stderr, "bg3mfx: unknown argument %s (see bg3mfx --help)\n", argv[i]); return 2; }
        }
        if ([command isEqualToString:@"install-app"]) return installApp(destination);
        return launch(game, dryRun);
    }
}
