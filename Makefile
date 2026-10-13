VERSION ?= 0.1.0
PREFIX ?= /usr/local
CXX = xcrun clang++
CXXFLAGS = -std=c++17 -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=26.0
FRAMEWORKS = -framework Foundation -framework Metal -framework MetalFX -framework AppKit -framework QuartzCore

.PHONY: all install test test-python clean
# The quiet runtime is the build players use; bg3mfx is its launcher.
all: build/libBG3MetalFX.dylib build/bg3mfx

build/bg3mfx: src/launcher/main.m | build
	xcrun clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=26.0 -DBG3MFX_VERSION=\"$(VERSION)\" $< \
		-framework AppKit -framework UniformTypeIdentifiers -o $@

# Player install (used by the Homebrew formula): launcher and quiet runtime only.
install: build/libBG3MetalFX.dylib build/bg3mfx
	install -d "$(PREFIX)/bin" "$(PREFIX)/lib/bg3mfx"
	install -m 755 build/bg3mfx "$(PREFIX)/bin/bg3mfx"
	install -m 644 build/libBG3MetalFX.dylib "$(PREFIX)/lib/bg3mfx/libBG3MetalFX.dylib"

build/runtime-smoke: tests/runtime_smoke.mm | build
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

build/spatial-hook-smoke: tests/spatial_hook_smoke.mm | build
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -framework AppKit -o $@

build/temporal-hook-smoke: tests/temporal_hook_smoke.mm | build
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

build/temporal-replay-smoke: tests/temporal_replay_smoke.mm src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) tests/temporal_replay_smoke.mm src/MetalFXPipeline.mm src/GPUResources.mm $(FRAMEWORKS) -o $@

build/temporal-quality-smoke: tests/temporal_quality_smoke.mm src/TemporalUpscaler.h src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) tests/temporal_quality_smoke.mm src/MetalFXPipeline.mm src/GPUResources.mm $(FRAMEWORKS) -o $@

# Optional public-API comparison; no changes to the injected game runtime.
build/temporal-api-compare: tests/temporal_api_compare.mm | build
	$(CXX) $(CXXFLAGS) $< $(FRAMEWORKS) -o $@

build/metal4-bridge-smoke: tests/metal4_bridge_smoke.mm src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) $< src/MetalFXPipeline.mm src/GPUResources.mm $(FRAMEWORKS) -o $@

build/native-jitter-smoke: tests/native_jitter_smoke.mm tests/native_jitter_wrappers.S src/NativeJitter.mm src/NativeJitter.S src/NativeJitter.h src/NativeMenu.h | build
	$(CXX) $(CXXFLAGS) tests/native_jitter_smoke.mm src/NativeJitter.S tests/native_jitter_wrappers.S -framework Foundation -o $@

build/metalfx-smoke: tests/metalfx_smoke.mm src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) tests/metalfx_smoke.mm src/MetalFXPipeline.mm src/GPUResources.mm $(FRAMEWORKS) -o $@

build/spatial-upscaler-smoke: tests/spatial_upscaler_smoke.mm src/SpatialUpscaler.mm src/SpatialUpscaler.h src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) $< src/SpatialUpscaler.mm src/MetalFXPipeline.mm src/GPUResources.mm $(FRAMEWORKS) -o $@

build/temporal-upscaler-smoke: tests/temporal_upscaler_smoke.mm src/TemporalUpscaler.mm src/TemporalUpscaler.h src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) $< src/TemporalUpscaler.mm src/MetalFXPipeline.mm src/GPUResources.mm $(FRAMEWORKS) -o $@

build:
	mkdir -p build

build/libBG3MetalFXTrace.dylib: src/Trace.mm src/FrameInterpolation.mm src/FrameInterpolation.h src/FrameLog.mm src/FrameLog.h src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h src/SpatialUpscaler.mm src/SpatialUpscaler.h src/TemporalUpscaler.mm src/TemporalUpscaler.h src/NativeMenu.mm src/NativeMenu.h src/NativeJitter.mm src/NativeJitter.h src/NativeJitter.S | build
	$(CXX) $(CXXFLAGS) -dynamiclib src/Trace.mm src/FrameInterpolation.mm src/FrameLog.mm src/MetalFXPipeline.mm src/GPUResources.mm src/SpatialUpscaler.mm src/TemporalUpscaler.mm src/NativeMenu.mm src/NativeJitter.mm src/NativeJitter.S $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

# Keep diagnostic and quiet runtimes as separate outputs for comparison.
build/libBG3MetalFX.dylib: src/Trace.mm src/FrameInterpolation.mm src/FrameInterpolation.h src/FrameLog.mm src/FrameLog.h src/MetalFXPipeline.mm src/GPUResources.mm src/MetalFXPipeline.h src/GPUResources.h src/SpatialUpscaler.mm src/SpatialUpscaler.h src/TemporalUpscaler.mm src/TemporalUpscaler.h src/NativeMenu.mm src/NativeMenu.h src/NativeJitter.mm src/NativeJitter.h src/NativeJitter.S | build
	$(CXX) $(CXXFLAGS) -DBG3MFX_NO_TRACE=1 -dynamiclib src/Trace.mm src/FrameInterpolation.mm src/FrameLog.mm src/MetalFXPipeline.mm src/GPUResources.mm src/SpatialUpscaler.mm src/TemporalUpscaler.mm src/NativeMenu.mm src/NativeJitter.mm src/NativeJitter.S $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

build/metalfx-probe: tools/metalfx_probe.m | build
	xcrun clang -fobjc-arc -mmacosx-version-min=26.0 $< $(FRAMEWORKS) -o $@

test: build/frame-generation-hook-smoke build/frame-interpolation-smoke build/metal4-bridge-smoke build/runtime-smoke build/metalfx-smoke build/temporal-quality-smoke build/native-jitter-smoke build/spatial-upscaler-smoke build/temporal-upscaler-smoke build/spatial-hook-smoke build/temporal-hook-smoke build/libBG3MetalFX.dylib build/libBG3MetalFXTrace.dylib
	./build/frame-generation-hook-smoke ./build/libBG3MetalFX.dylib
	./build/frame-generation-hook-smoke ./build/libBG3MetalFXTrace.dylib
	./build/frame-generation-hook-smoke ./build/libBG3MetalFX.dylib hdr
	./build/frame-generation-hook-smoke ./build/libBG3MetalFXTrace.dylib hdr
	./build/frame-generation-hook-smoke ./build/libBG3MetalFX.dylib scaled
	./build/frame-generation-hook-smoke ./build/libBG3MetalFXTrace.dylib scaled
	./build/frame-interpolation-smoke
	BG3MFX_TEST_DIRECT_INPUTS=1 ./build/frame-interpolation-smoke
	./build/metal4-bridge-smoke
	./build/native-jitter-smoke
	./build/metalfx-smoke
	./build/temporal-quality-smoke build/temporal-quality/regression
	./build/spatial-upscaler-smoke
	./build/temporal-upscaler-smoke
	BG3MFX_TEST_DIRECT_OUTPUT=1 ./build/temporal-upscaler-smoke
	./build/runtime-smoke ./build/libBG3MetalFXTrace.dylib
	./build/spatial-hook-smoke ./build/libBG3MetalFX.dylib
	./build/spatial-hook-smoke ./build/libBG3MetalFXTrace.dylib
	./build/temporal-hook-smoke ./build/libBG3MetalFX.dylib
	./build/temporal-hook-smoke ./build/libBG3MetalFXTrace.dylib

# These exercise the development launch helper, not rendering acceptance.
test-python: build/bg3mfx
	python3 -m unittest discover -s tests -v

clean:
	rm -f build/libBG3MetalFX.dylib build/libBG3MetalFXTrace.dylib build/bg3mfx build/metalfx-probe \
		build/runtime-smoke build/metalfx-smoke build/spatial-upscaler-smoke \
		build/temporal-upscaler-smoke build/spatial-hook-smoke \
		build/temporal-hook-smoke build/temporal-replay-smoke build/temporal-quality-smoke build/native-jitter-smoke build/temporal-api-compare build/metal4-bridge-smoke \
		build/frame-interpolation-smoke build/frame-generation-hook-smoke

build/frame-interpolation-smoke: tests/frame_interpolation_smoke.mm src/FrameInterpolation.mm src/FrameInterpolation.h src/FrameLog.mm src/FrameLog.h src/GPUResources.mm src/GPUResources.h | build
	$(CXX) $(CXXFLAGS) $< src/FrameInterpolation.mm src/FrameLog.mm src/GPUResources.mm $(FRAMEWORKS) -Isrc -o $@

build/frame-generation-hook-smoke: tests/frame_generation_hook_smoke.mm | build
	$(CXX) $(CXXFLAGS) $< $(FRAMEWORKS) -o $@
