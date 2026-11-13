#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import <jsi/jsi.h>

#import "Fonts.h"
#import "LoaderConfig.h"
#import "Logger.h"
#import "Settings.h"
#import "Themes.h"
#import "Utils.h"

@class RCTInstance;

static NSURL         *source;
static NSString      *bunnyPatchesBundlePath;
static NSURL         *pyoncordDirectory;
static LoaderConfig  *loaderConfig;
static NSTimeInterval shakeStartTime = 0;
static BOOL           isShaking      = NO;
// Defined with C linkage: Settings.h declares it inside extern "C" so the
// ObjC sources (Settings.m, Utils.m) link against the plain _gBridge symbol.
extern "C" id gBridge = nil;

#pragma mark - Bridgeless JS evaluation (Discord 353 / RN 0.85.3)
//
// Discord 353 runs React Native 0.85.3 BRIDGELESS. The legacy
// RCTCxxBridge.executeApplicationScript hook is dead on 353 (that method is
// never called for the main bundle), so 2.0.2 injects through
// -[RCTHost instance:didInitializeRuntime:], which RN calls on the JS thread
// AFTER the Hermes runtime is created and BEFORE the main bundle loads
// (RCTInstance.mm _start: delegate callback at L852, _loadJSBundle at L868).
// That is the exact same ordering the old bridge hook had.
//
// Discord does NOT export facebook::jsi symbols (verified from the 353
// binary's dyld export trie: no __ZN8facebook3jsi subtree), so this file
// must never construct/destroy a jsi::Value or a jsi::Buffer through the
// normal C++ API — the compiler would emit calls to the out-of-line
// Value::~Value() / Buffer::~Buffer(), which cannot resolve at runtime.
// Instead:
//  * evaluateJavaScript is called THROUGH THE RUNTIME VTABLE (index 3,
//    derived from RN 0.85.3 jsi.h via g++ -fdump-lang-class; see
//    Sources/vendor/README.md). The return type is a stand-in 16-byte struct
//    with a no-op destructor, so no jsi::Value is ever constructed or
//    destroyed by our code. The 16 bytes are abandoned (one JS reference
//    leaks per eval — negligible; scripts normally return undefined).
//  * The JS is carried in KettuBuffer, a STANDALONE class whose vtable
//    layout matches jsi::Buffer ([dtor, dtor, size(), data()] — size at
//    index 2, data at index 3). It is NOT a subclass of jsi::Buffer
//    (subclassing would pull in jsi::Buffer's typeinfo). It is held by a
//    shared_ptr with a NO-OP deleter, so it is never destroyed (the ~282 KB
//    buffer leaks once per launch by design) and Buffer::~Buffer() is never
//    needed.
//  * The call itself is ABI-exact for arm64 (AAPCS64): sret in x8, this in
//    x0, buffer in x1, sourceURL in x2. KettuEvalResult is 16 bytes with a
//    user-declared (non-trivial) destructor, so the compiler passes its
//    address as the hidden sret pointer in x8 — the same register Hermes's
//    evaluateJavaScript expects.

// Stand-in for the jsi::Value returned by evaluateJavaScript.
// Same size (16 bytes, verified from jsi.h) and non-trivial (user-declared
// destructor) so the compiler uses the sret convention, but the destructor
// is a no-op defined here, so no jsi::Value destructor is ever called.
struct KettuEvalResult {
    unsigned char data[sizeof(facebook::jsi::Value)];
    ~KettuEvalResult() {}
};

// Layout-compatible with facebook::jsi::Buffer. NOT a subclass (see above).
// Virtual order must stay [dtor, size(), data()] so size() is at vtable
// index 2 and data() at index 3, exactly like jsi::Buffer.
class KettuBuffer {
public:
    explicit KettuBuffer(std::string s) : s_(std::move(s)) {}
    virtual ~KettuBuffer() {}
    virtual size_t size() const { return s_.size(); }
    virtual const uint8_t *data() const
    {
        return reinterpret_cast<const uint8_t *>(s_.data());
    }

private:
    std::string s_;
};

// evaluateJavaScript vtable slot — INDEX 1 (corrected 2026-11-13, round 3).
// The vendored RN 0.85.3 jsi.h says [0]=castInterface, [1]=~D1, [2]=~D0,
// [3]=evaluateJavaScript — but the SHIPPED hermesvm was built against the
// newer RN-main jsi hierarchy (Runtime : IRuntime : ICast, destructors
// last). Verified from the binary itself (hermesvm __ZTVN...HermesRuntimeImplE
// @ 0x1fcce0, vptr +16): [0]=castInterface, [1]=evaluateJavaScript,
// [2]=prepareJavaScript, [3]=evaluatePreparedJavaScript, destructors at
// [109]/[110]. Slot 3 was evaluatePreparedJavaScript — calling it with a
// Buffer shared_ptr made it treat our 32-byte KettuBuffer as a
// PreparedJavaScript (OOB read at +0x38 + atomic refcount RMW on garbage),
// which is the 2.0.2 launch crash. NEVER trust the vendored header's layout
// again without checking the shipped binary.
#define KETTU_EVAL_VTABLE_INDEX 1

typedef KettuEvalResult (*KettuEvalFn)(
    void *runtime,
    const std::shared_ptr<const facebook::jsi::Buffer> *buffer,
    const std::string *sourceURL);

// Probe helper (2.0.3): write a small text file into Documents/pyoncord so
// the on-device result can be read back with WQ Files. BunnyLog only goes
// to the system log, which we cannot read — files are the only channel.
static void kettuProbeWrite(NSString *name, NSString *content)
{
    NSURL *dir = pyoncordDirectory;
    if (!dir) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            dir = [[NSURL fileURLWithPath:paths[0]] URLByAppendingPathComponent:@"pyoncord"];
        }
    }
    if (!dir) {
        return;
    }
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSURL *url = [dir URLByAppendingPathComponent:name];
    [content writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Returns @"ok" on success, or a short failure reason (@"null-input",
// @"null-vtable", @"null-eval-slot", @"exception: <what>",
// @"unknown-exception"). Callers ignore the return value except the 2.0.3
// probe gate, which writes it to eval-result.txt.
static NSString *kettuEvalJS(void *runtimePtr, NSData *jsData, NSString *sourceURL)
{
    if (!runtimePtr || !jsData || jsData.length == 0) {
        return @"null-input";
    }

    std::string js((const char *)jsData.bytes, (size_t)jsData.length);
    std::string url = sourceURL ? [sourceURL UTF8String] : "kettu";

    // The buffer is intentionally leaked (no-op deleter): destroying it
    // would call facebook::jsi::Buffer::~Buffer(), which Discord does not
    // export. One ~282 KB leak per launch.
    auto *rawBuf = new KettuBuffer(std::move(js));
    const facebook::jsi::Buffer *asJsiBuffer =
        reinterpret_cast<const facebook::jsi::Buffer *>(rawBuf);
    std::shared_ptr<const facebook::jsi::Buffer> shared(
        asJsiBuffer, [](const facebook::jsi::Buffer *) {});

    void **vtable = *reinterpret_cast<void ***>(runtimePtr);
    if (!vtable) {
        BunnyLog(@"Kettu bridgeless eval: null runtime vtable");
        return @"null-vtable";
    }

    auto evalFn = reinterpret_cast<KettuEvalFn>(vtable[KETTU_EVAL_VTABLE_INDEX]);
    if (!evalFn) {
        BunnyLog(@"Kettu bridgeless eval: null evaluateJavaScript slot");
        return @"null-eval-slot";
    }

    // C++ exceptions (e.g. a JS error surfacing as jsi::JSError, which is a
    // std::exception) must be caught here — letting one escape through the
    // ObjC method would crash. what() is inline in jsi.h, so it is safe to
    // call on the caught exception.
    try {
        // The returned KettuEvalResult is abandoned on purpose: its
        // destructor is a no-op, so the jsi::Value bytes Hermes wrote into
        // it are simply left alone (never destroyed, never interpreted).
        KettuEvalResult result = evalFn(runtimePtr, &shared, &url);
        (void)result;
        return @"ok";
    } catch (const std::exception &e) {
        BunnyLog(@"Kettu bridgeless eval failed (%@): %s", sourceURL, e.what());
        return [NSString stringWithFormat:@"exception: %s", e.what()];
    } catch (...) {
        BunnyLog(@"Kettu bridgeless eval failed (%@): unknown C++ exception", sourceURL);
        return @"unknown-exception";
    }
}

// Per-instance injection guard (associated object on the RCTInstance).
// A reload creates a NEW RCTInstance, so the flag resets naturally and the
// new runtime gets injected again. The legacy bridge hook never fires on
// 353, so there is no cross-path double injection.
static const void *kKettuBridgelessInjectedKey = &kKettuBridgelessInjectedKey;

%hook RCTHost

- (void)instance:(RCTInstance *)instance didInitializeRuntime:(facebook::jsi::Runtime &)runtime
{
    // Let Discord's own runtime-delegate setup run first.
    %orig;

    // 2.0.3 PROBE: write marker files into Documents/pyoncord so the
    // on-device result is readable with WQ Files (BunnyLog is not).
    // The files present after a crash tell us exactly how far the hook got:
    //   bridgeless-hook-entered.txt -> hook attached and fired
    //   vtable-slots.txt            -> runtime vtable read (slots 0-7)
    //   eval-result.txt             -> trivial eval (1+1) outcome
    //   probe-ok.txt                -> trivial eval passed, full injection started
    //   bridgeless-injected.txt     -> full injection finished
    kettuProbeWrite(@"bridgeless-hook-entered.txt",
                    [NSString stringWithFormat:@"hook fired\ninstance=%p runtime=%p\n",
                                               instance, (void *)&runtime]);

    void *runtimePtr = (void *)&runtime;

    // Dump the runtime vtable slots WITHOUT calling anything: if slot 3 is
    // not evaluateJavaScript, the pointer values here let us re-derive the
    // right index from the binary instead of guessing.
    void **runtimeVtable = runtimePtr ? *(void ***)runtimePtr : NULL;
    if (runtimeVtable) {
        NSMutableString *slots = [NSMutableString
            stringWithFormat:@"runtime=%p vtable=%p\n", runtimePtr, runtimeVtable];
        for (int i = 0; i < 8; i++) {
            [slots appendFormat:@"slot[%d]=%p\n", i, runtimeVtable[i]];
        }
        kettuProbeWrite(@"vtable-slots.txt", slots);
    } else {
        kettuProbeWrite(@"vtable-slots.txt", @"null vtable\n");
        return;
    }

    // This fires on the JS thread, before the main bundle loads — the same
    // ordering the old RCTCxxBridge hook had on the bridge.
    if (objc_getAssociatedObject(instance, kKettuBridgelessInjectedKey)) {
        BunnyLog(@"Kettu already injected for this instance, skipping");
        return;
    }

    // PROBE GATE: try a trivial script first. If the vtable call itself is
    // broken (wrong index / wrong calling convention), the app dies here and
    // eval-result.txt is never written — that alone is the diagnosis. If it
    // throws (caught), skip the real injection and leave the app alive.
    NSString *probeStatus = kettuEvalJS(runtimePtr,
                                        [@"1+1" dataUsingEncoding:NSUTF8StringEncoding],
                                        @"kettu-probe");
    kettuProbeWrite(@"eval-result.txt",
                    [NSString stringWithFormat:@"trivial eval (1+1): %@\n",
                                               probeStatus ?: @"(nil)"]);
    if (![probeStatus isEqualToString:@"ok"]) {
        BunnyLog(@"Kettu probe: trivial eval failed (%@), skipping injection", probeStatus);
        return;
    }
    kettuProbeWrite(@"probe-ok.txt",
                    @"trivial eval succeeded; proceeding to full injection\n");


    NSBundle *bunnyPatchesBundle = [NSBundle bundleWithPath:bunnyPatchesBundlePath];
    if (!bunnyPatchesBundle)
    {
        BunnyLog(@"Failed to load BunnyPatches bundle from path: %@", bunnyPatchesBundlePath);
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return;
    }

    NSURL *patchPath = [bunnyPatchesBundle URLForResource:@"payload-base" withExtension:@"js"];
    if (!patchPath)
    {
        BunnyLog(@"Failed to find payload-base.js in bundle");
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return;
    }

    NSData *patchData = [NSData dataWithContentsOfURL:patchPath];
    BunnyLog(@"Injecting loader (bridgeless)");
    kettuEvalJS(runtimePtr, patchData, @"kettu");

    __block NSData *bundle =
        [NSData dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]];

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    NSURL *bundleUrl;
    if (loaderConfig.customLoadUrlEnabled && loaderConfig.customLoadUrl)
    {
        bundleUrl = loaderConfig.customLoadUrl;
        BunnyLog(@"Using custom load URL: %@", bundleUrl.absoluteString);
    }
    else
    {
        // KETTU MINIMAL (max5 diagnostic): default bundle is stock Kettu, no plugins baked in.
        // MAX bundle remains loadable on demand via Load Custom Bundle (see KETTU-353-FIX.md §10).
        // Stock upstream fallback was:
        // https://codeberg.org/cocobo1/Kettu/raw/branch/dist/kettu.min.js
        bundleUrl = [NSURL
            URLWithString:@"https://dolanexeee.github.io/kettu-max/bundle/kettu-notoast-r8.min.js"];
        BunnyLog(@"Using default bundle URL: %@", bundleUrl.absoluteString);
    }

    NSMutableURLRequest *bundleRequest =
        [NSMutableURLRequest requestWithURL:bundleUrl
                                cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                            timeoutInterval:3.0];

    NSString *bundleEtag = [NSString
        stringWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"etag.txt"]
                       encoding:NSUTF8StringEncoding
                          error:nil];
    if (bundleEtag && bundle)
    {
        [bundleRequest setValue:bundleEtag forHTTPHeaderField:@"If-None-Match"];
    }

    NSURLSession *session            = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    __block BOOL  downloadSuccessful = NO;

    [[session
        dataTaskWithRequest:bundleRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              if ([response isKindOfClass:[NSHTTPURLResponse class]])
              {
                  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                  if (httpResponse.statusCode == 200 && data && data.length > 0)
                  {
                      bundle             = data;
                      downloadSuccessful = YES;
                      [bundle
                          writeToURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]
                          atomically:YES];

                      NSString *etag = [httpResponse.allHeaderFields objectForKey:@"Etag"];
                      if (etag)
                      {
                          [etag
                              writeToURL:[pyoncordDirectory URLByAppendingPathComponent:@"etag.txt"]
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:nil];
                      }

                      BunnyLog(@"Bundle download successful, cleaning up backup");
                      cleanupBundleBackup();
                  }
                  else if (httpResponse.statusCode == 304)
                  {
                      BunnyLog(@"Bundle not modified (304), cleaning up backup");
                      downloadSuccessful = YES;
                      cleanupBundleBackup();
                  }
                  else
                  {
                      BunnyLog(@"Bundle download failed with status: %ld",
                               (long) httpResponse.statusCode);
                  }
              }
              else if (error)
              {
                  BunnyLog(@"Bundle download error: %@", error.localizedDescription);
              }

              if (!downloadSuccessful && !bundle)
              {
                  BunnyLog(@"No bundle available, attempting to restore from backup");
                  if (restoreBundleFromBackup())
                  {
                      bundle = [NSData
                          dataWithContentsOfURL:[pyoncordDirectory
                                                    URLByAppendingPathComponent:@"bundle.js"]];
                      if (bundle)
                      {
                          BunnyLog(@"Successfully restored bundle from backup");
                      }
                  }
                  else
                  {
                      BunnyLog(@"Failed to restore bundle from backup");
                  }
              }

              dispatch_group_leave(group);
          }] resume];

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSData *themeData =
        [NSData dataWithContentsOfURL:[pyoncordDirectory
                                          URLByAppendingPathComponent:@"current-theme.json"]];
    if (themeData)
    {
        NSError      *jsonError;
        NSDictionary *themeDict = [NSJSONSerialization JSONObjectWithData:themeData
                                                                  options:0
                                                                    error:&jsonError];
        if (!jsonError)
        {
            BunnyLog(@"Loading theme data...");
            if (themeDict[@"data"])
            {
                NSDictionary *data = themeDict[@"data"];
                if (data[@"semanticColors"] && data[@"rawColors"])
                {
                    BunnyLog(@"Initializing theme colors from theme data");
                    initializeThemeColors(data[@"semanticColors"], data[@"rawColors"]);
                }
            }

            NSString *jsCode =
                [NSString stringWithFormat:@"globalThis.__PYON_LOADER__.storedTheme=%@",
                                           [[NSString alloc] initWithData:themeData
                                                                 encoding:NSUTF8StringEncoding]];
            kettuEvalJS(runtimePtr, [jsCode dataUsingEncoding:NSUTF8StringEncoding], @"kettu");
        }
        else
        {
            BunnyLog(@"Error parsing theme JSON: %@", jsonError);
        }
    }
    else
    {
        BunnyLog(@"No theme data found at path: %@",
                 [pyoncordDirectory URLByAppendingPathComponent:@"current-theme.json"]);
    }

    NSData *fontData = [NSData
        dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"fonts.json"]];
    if (fontData)
    {
        NSError      *jsonError;
        NSDictionary *fontDict = [NSJSONSerialization JSONObjectWithData:fontData
                                                                 options:0
                                                                   error:&jsonError];
        if (!jsonError && fontDict[@"main"])
        {
            BunnyLog(@"Found font configuration, applying...");
            patchFonts(fontDict[@"main"], fontDict[@"name"]);
        }
    }

    if (bundle)
    {
        BunnyLog(@"Executing JS bundle (bridgeless)");
        kettuEvalJS(runtimePtr, bundle, @"kettu");
    }
    else
    {
        BunnyLog(@"ERROR: No bundle available to execute!");
        showErrorAlert(
            @"Bundle Error",
            @"Failed to load bundle. Please check your internet connection and restart the app.",
            nil);
    }

    NSURL *preloadsDirectory = [pyoncordDirectory URLByAppendingPathComponent:@"preloads"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:preloadsDirectory.path])
    {
        NSError *error = nil;
        NSArray *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtURL:preloadsDirectory
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                               error:&error];
        if (!error)
        {
            for (NSURL *fileURL in contents)
            {
                if ([[fileURL pathExtension] isEqualToString:@"js"])
                {
                    BunnyLog(@"Executing preload JS file %@", fileURL.absoluteString);
                    NSData *data = [NSData dataWithContentsOfURL:fileURL];
                    if (data)
                    {
                        kettuEvalJS(runtimePtr, data, @"kettu");
                    }
                }
            }
        }
        else
        {
            BunnyLog(@"Error reading contents of preloads directory");
        }
    }

    objc_setAssociatedObject(instance, kKettuBridgelessInjectedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BunnyLog(@"Kettu bridgeless injection complete");
    kettuProbeWrite(@"bridgeless-injected.txt", @"full injection complete\n");
}

%end

%hook RCTCxxBridge

- (void)executeApplicationScript:(NSData *)script url:(NSURL *)url async:(BOOL)async
{
    if (![url.absoluteString containsString:@"main.jsbundle"])
    {
        return %orig;
    }

    gBridge = self;
    BunnyLog(@"Stored bridge reference: %@", gBridge);

    NSBundle *bunnyPatchesBundle = [NSBundle bundleWithPath:bunnyPatchesBundlePath];
    if (!bunnyPatchesBundle)
    {
        BunnyLog(@"Failed to load BunnyPatches bundle from path: %@", bunnyPatchesBundlePath);
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return %orig;
    }

    NSURL *patchPath = [bunnyPatchesBundle URLForResource:@"payload-base" withExtension:@"js"];
    if (!patchPath)
    {
        BunnyLog(@"Failed to find payload-base.js in bundle");
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return %orig;
    }

    NSData *patchData = [NSData dataWithContentsOfURL:patchPath];
    BunnyLog(@"Injecting loader");
    %orig(patchData, source, YES);

    __block NSData *bundle =
        [NSData dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]];

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    NSURL *bundleUrl;
    if (loaderConfig.customLoadUrlEnabled && loaderConfig.customLoadUrl)
    {
        bundleUrl = loaderConfig.customLoadUrl;
        BunnyLog(@"Using custom load URL: %@", bundleUrl.absoluteString);
    }
    else
    {
        // KETTU MINIMAL (max5 diagnostic): default bundle is stock Kettu, no plugins baked in.
        // MAX bundle remains loadable on demand via Load Custom Bundle (see KETTU-353-FIX.md §10).
        // Stock upstream fallback was:
        // https://codeberg.org/cocobo1/Kettu/raw/branch/dist/kettu.min.js
        bundleUrl = [NSURL
            URLWithString:@"https://dolanexeee.github.io/kettu-max/bundle/kettu-notoast-r8.min.js"];
        BunnyLog(@"Using default bundle URL: %@", bundleUrl.absoluteString);
    }

    NSMutableURLRequest *bundleRequest =
        [NSMutableURLRequest requestWithURL:bundleUrl
                                cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                            timeoutInterval:3.0];

    NSString *bundleEtag = [NSString
        stringWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"etag.txt"]
                       encoding:NSUTF8StringEncoding
                          error:nil];
    if (bundleEtag && bundle)
    {
        [bundleRequest setValue:bundleEtag forHTTPHeaderField:@"If-None-Match"];
    }

    NSURLSession *session            = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    __block BOOL  downloadSuccessful = NO;

    [[session
        dataTaskWithRequest:bundleRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              if ([response isKindOfClass:[NSHTTPURLResponse class]])
              {
                  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                  if (httpResponse.statusCode == 200 && data && data.length > 0)
                  {
                      bundle             = data;
                      downloadSuccessful = YES;
                      [bundle
                          writeToURL:[pyoncordDirectory URLByAppendingPathComponent:@"bundle.js"]
                          atomically:YES];

                      NSString *etag = [httpResponse.allHeaderFields objectForKey:@"Etag"];
                      if (etag)
                      {
                          [etag
                              writeToURL:[pyoncordDirectory URLByAppendingPathComponent:@"etag.txt"]
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:nil];
                      }

                      BunnyLog(@"Bundle download successful, cleaning up backup");
                      cleanupBundleBackup();
                  }
                  else if (httpResponse.statusCode == 304)
                  {
                      BunnyLog(@"Bundle not modified (304), cleaning up backup");
                      downloadSuccessful = YES;
                      cleanupBundleBackup();
                  }
                  else
                  {
                      BunnyLog(@"Bundle download failed with status: %ld",
                               (long) httpResponse.statusCode);
                  }
              }
              else if (error)
              {
                  BunnyLog(@"Bundle download error: %@", error.localizedDescription);
              }

              if (!downloadSuccessful && !bundle)
              {
                  BunnyLog(@"No bundle available, attempting to restore from backup");
                  if (restoreBundleFromBackup())
                  {
                      bundle = [NSData
                          dataWithContentsOfURL:[pyoncordDirectory
                                                    URLByAppendingPathComponent:@"bundle.js"]];
                      if (bundle)
                      {
                          BunnyLog(@"Successfully restored bundle from backup");
                      }
                  }
                  else
                  {
                      BunnyLog(@"Failed to restore bundle from backup");
                  }
              }

              dispatch_group_leave(group);
          }] resume];

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSData *themeData =
        [NSData dataWithContentsOfURL:[pyoncordDirectory
                                          URLByAppendingPathComponent:@"current-theme.json"]];
    if (themeData)
    {
        NSError      *jsonError;
        NSDictionary *themeDict = [NSJSONSerialization JSONObjectWithData:themeData
                                                                  options:0
                                                                    error:&jsonError];
        if (!jsonError)
        {
            BunnyLog(@"Loading theme data...");
            if (themeDict[@"data"])
            {
                NSDictionary *data = themeDict[@"data"];
                if (data[@"semanticColors"] && data[@"rawColors"])
                {
                    BunnyLog(@"Initializing theme colors from theme data");
                    initializeThemeColors(data[@"semanticColors"], data[@"rawColors"]);
                }
            }

            NSString *jsCode =
                [NSString stringWithFormat:@"globalThis.__PYON_LOADER__.storedTheme=%@",
                                           [[NSString alloc] initWithData:themeData
                                                                 encoding:NSUTF8StringEncoding]];
            %orig([jsCode dataUsingEncoding:NSUTF8StringEncoding], source, async);
        }
        else
        {
            BunnyLog(@"Error parsing theme JSON: %@", jsonError);
        }
    }
    else
    {
        BunnyLog(@"No theme data found at path: %@",
                 [pyoncordDirectory URLByAppendingPathComponent:@"current-theme.json"]);
    }

    NSData *fontData = [NSData
        dataWithContentsOfURL:[pyoncordDirectory URLByAppendingPathComponent:@"fonts.json"]];
    if (fontData)
    {
        NSError      *jsonError;
        NSDictionary *fontDict = [NSJSONSerialization JSONObjectWithData:fontData
                                                                 options:0
                                                                   error:&jsonError];
        if (!jsonError && fontDict[@"main"])
        {
            BunnyLog(@"Found font configuration, applying...");
            patchFonts(fontDict[@"main"], fontDict[@"name"]);
        }
    }

    if (bundle)
    {
        BunnyLog(@"Executing JS bundle");
        %orig(bundle, source, async);
    }
    else
    {
        BunnyLog(@"ERROR: No bundle available to execute!");
        showErrorAlert(
            @"Bundle Error",
            @"Failed to load bundle. Please check your internet connection and restart the app.",
            nil);
    }

    NSURL *preloadsDirectory = [pyoncordDirectory URLByAppendingPathComponent:@"preloads"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:preloadsDirectory.path])
    {
        NSError *error = nil;
        NSArray *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtURL:preloadsDirectory
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                               error:&error];
        if (!error)
        {
            for (NSURL *fileURL in contents)
            {
                if ([[fileURL pathExtension] isEqualToString:@"js"])
                {
                    BunnyLog(@"Executing preload JS file %@", fileURL.absoluteString);
                    NSData *data = [NSData dataWithContentsOfURL:fileURL];
                    if (data)
                    {
                        %orig(data, source, async);
                    }
                }
            }
        }
        else
        {
            BunnyLog(@"Error reading contents of preloads directory");
        }
    }

    %orig(script, url, async);
}

%end

%hook UIWindow

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake)
    {
        isShaking      = YES;
        shakeStartTime = [[NSDate date] timeIntervalSince1970];
    }
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake && isShaking)
    {
        NSTimeInterval currentTime   = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval shakeDuration = currentTime - shakeStartTime;

        if (shakeDuration >= 0.5 && shakeDuration <= 2.0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{ showSettingsSheet(); });
        }
        isShaking = NO;
    }
    %orig;
}

%end

%ctor
{
    @autoreleasepool
    {
        source = [NSURL URLWithString:@"kettu"];

        NSString *install_prefix = @"/var/jb";
        isJailbroken             = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];
        BOOL jbPathExists        = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];

        NSString *bundlePath =
            [NSString stringWithFormat:@"%@/Library/Application Support/BunnyResources.bundle",
                                       install_prefix];
        BunnyLog(@"Is jailbroken: %d", isJailbroken);
        BunnyLog(@"Bundle path for jailbroken: %@", bundlePath);

        NSString *jailedPath = [[NSBundle mainBundle].bundleURL.path
            stringByAppendingPathComponent:@"BunnyResources.bundle"];
        BunnyLog(@"Bundle path for jailed: %@", jailedPath);

        bunnyPatchesBundlePath = isJailbroken ? bundlePath : jailedPath;
        BunnyLog(@"Selected bundle path: %@", bunnyPatchesBundlePath);

        BOOL bundleExists =
            [[NSFileManager defaultManager] fileExistsAtPath:bunnyPatchesBundlePath];
        BunnyLog(@"Bundle exists at path: %d", bundleExists);

        if (jbPathExists)
        {
            BunnyLog(@"Jailbreak path exists, attempting to load bundle from: %@", bundlePath);

            BOOL      bundleExists = [[NSFileManager defaultManager] fileExistsAtPath:bundlePath];
            NSBundle *testBundle   = [NSBundle bundleWithPath:bundlePath];

            if (bundleExists && testBundle)
            {
                bunnyPatchesBundlePath = bundlePath;
                BunnyLog(@"Successfully loaded bundle from jailbroken path");
            }
            else
            {
                BunnyLog(@"Bundle not found or invalid at jailbroken path, falling back to jailed");
                bunnyPatchesBundlePath = jailedPath;
            }
        }
        else
        {
            BunnyLog(@"Not jailbroken, using jailed bundle path");
            bunnyPatchesBundlePath = jailedPath;
        }

        BunnyLog(@"Selected bundle path: %@", bunnyPatchesBundlePath);

        NSBundle *bunnyPatchesBundle = [NSBundle bundleWithPath:bunnyPatchesBundlePath];
        if (!bunnyPatchesBundle)
        {
            BunnyLog(@"Failed to load bunnyPatches bundle from any path");
            BunnyLog(@"  Jailbroken path: %@", bundlePath);

            bunnyPatchesBundlePath = nil;
        }
        else
        {
            BunnyLog(@"Bundle loaded successfully");
            NSError *error = nil;
            NSArray *bundleContents =
                [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bunnyPatchesBundlePath
                                                                    error:&error];
            if (error)
            {
                BunnyLog(@"Error listing bundle contents: %@", error);
            }
            else
            {
                BunnyLog(@"Bundle contents: %@", bundleContents);
            }
        }

        pyoncordDirectory = getPyoncordDirectory();
        loaderConfig      = [[LoaderConfig alloc] init];
        [loaderConfig loadConfig];

        %init;
    }
}
