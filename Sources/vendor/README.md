# Vendored jsi headers — React Native 0.85.3

Source: `facebook/react-native` tag `v0.85.3`
- `packages/react-native/ReactCommon/jsi/jsi/jsi.h`
- `packages/react-native/ReactCommon/jsi/jsi/jsi-inl.h`

`jsi.h` is self-contained: it only includes standard C++ headers plus
`jsi/jsi-inl.h` (which has no includes of its own). No folly, no other RN
headers are needed.

## Why these are here

Discord 353 runs React Native 0.85.3 **bridgeless**. The legacy
`RCTCxxBridge.executeApplicationScript` hook is dead on 353, so Kettu 2.0.2
injects through `-[RCTHost instance:didInitializeRuntime:]` and evaluates JS
with `jsi::Runtime::evaluateJavaScript`.

## Why the tweak does NOT call jsi methods normally

Discord does **not export** the `facebook::jsi` symbols
(verified from the Discord 353 binary's dyld export trie: the
`__ZN8facebook3jsi` subtree is absent — only `facebook::react` and
`facebook::hermes` are exported). In particular these are NOT resolvable at
runtime via dynamic lookup:

- `facebook::jsi::Value::~Value()` (`__ZN8facebook3jsi5ValueD1Ev`)
- `facebook::jsi::Buffer::~Buffer()` (`__ZN8facebook3jsi6BufferD2Ev`)

So the tweak must never construct/destroy a `jsi::Value` or a `jsi::Buffer`
subclass through the normal C++ API (the compiler would emit calls to those
out-of-line destructors and the app would crash with "Symbol not found" on
first injection). `Tweak.xm` therefore:

- calls `evaluateJavaScript` **through the Runtime vtable** (index 3 — see
  below), with a stand-in 16-byte return type whose destructor is a no-op,
  so no `jsi::Value` is ever constructed or destroyed by our code;
- passes a **layout-compatible standalone buffer** (`KettuBuffer`, NOT a
  subclass of `jsi::Buffer` — subclassing would pull in `jsi::Buffer`'s
  typeinfo/vtable references) held by a `shared_ptr` with a **no-op deleter**,
  so no `jsi::Buffer` destructor is ever called. The ~282 KB buffer leaks
  once per launch by design; that is negligible and documented in `Tweak.xm`.

## Vtable index of `evaluateJavaScript` (= 3)

Derived from `jsi.h` (RN 0.85.3) with `g++ -fdump-lang-class` on Linux
(Itanium ABI vtable layout is identical on arm64):

```
Vtable for facebook::jsi::Runtime (92 entries):
  [0] ICast::castInterface
  [1] ~Runtime (complete-object destructor)
  [2] ~Runtime (deleting destructor)
  [3] evaluateJavaScript        <- this one
  [4] prepareJavaScript
  [5] evaluatePreparedJavaScript
  [6] queueMicrotask
  ...
```

Cross-checked against the declaration order in `jsi.h` (`~Runtime`,
`evaluateJavaScript`, `prepareJavaScript`, `evaluatePreparedJavaScript`,
`queueMicrotask`, `drainMicrotasks`, `global`, `description`,
`isInspectable`, `instrumentation`, `setRuntimeDataImpl`,
`getRuntimeDataImpl`, …) — the dump matches exactly.

`jsi::Buffer` vtable: `[~Buffer D1, ~Buffer D0, size(), data()]`, so `size()`
is at index 2 and `data()` at index 3 — `KettuBuffer` declares its virtuals
in the same order.

`sizeof(facebook::jsi::Value)` is 16, `alignof` 8.

If React Native is ever updated in Discord, re-derive the index from the
matching `jsi.h` before changing anything here.
