VERSION ?= 0.3.0
PREFIX ?= /usr/local
BIN_DIR ?= build/bin
EVIDENCE_DIR ?= build/evidence
CXX = xcrun clang++
CPPFLAGS = -Isrc
CXXFLAGS = $(CPPFLAGS) -std=c++17 -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=26.0
FRAMEWORKS = -framework Foundation -framework Metal -framework MetalFX -framework AppKit -framework QuartzCore

.PHONY: all install test test-python clean clean-evidence
# The quiet runtime is the build players use; bg3mfx is its launcher.
all: $(BIN_DIR)/libBG3MetalFX.dylib $(BIN_DIR)/bg3mfx

$(BIN_DIR)/bg3mfx: src/launcher/main.m src/common/native/SupportedBuild.h | $(BIN_DIR)
	xcrun clang $(CPPFLAGS) -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=26.0 -DBG3MFX_VERSION=\"$(VERSION)\" $< \
		-framework AppKit -framework UniformTypeIdentifiers -o $@

# Player install (used by the Homebrew formula): launcher and quiet runtime only.
install: $(BIN_DIR)/libBG3MetalFX.dylib $(BIN_DIR)/bg3mfx
	install -d "$(PREFIX)/bin" "$(PREFIX)/lib/bg3mfx"
	install -m 755 $(BIN_DIR)/bg3mfx "$(PREFIX)/bin/bg3mfx"
	install -m 644 $(BIN_DIR)/libBG3MetalFX.dylib "$(PREFIX)/lib/bg3mfx/libBG3MetalFX.dylib"

$(BIN_DIR)/runtime-smoke: tests/integration/runtime_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/spatial-hook-smoke: tests/features/metalfx-spatial-upscaling/spatial_hook_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -framework AppKit -o $@

$(BIN_DIR)/prepass-trim-smoke: tests/features/depth-prepass/prepass_trim_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/temporal-hook-smoke: tests/features/metalfx-temporal-upscaling/temporal_hook_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/temporal-replay-smoke: tests/features/metalfx-temporal-upscaling/temporal_replay_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/features/metalfx-temporal-upscaling/temporal_replay_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/temporal-quality-smoke: tests/features/metalfx-temporal-upscaling/temporal_quality_smoke.mm src/features/metalfx-temporal-upscaling/TemporalUpscaler.h src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/features/metalfx-temporal-upscaling/temporal_quality_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

# Optional public-API comparison; no changes to the injected game runtime.
$(BIN_DIR)/temporal-api-compare: tests/features/metalfx-temporal-upscaling/temporal_api_compare.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< $(FRAMEWORKS) -o $@

$(BIN_DIR)/metal4-bridge-smoke: tests/common/metal4_bridge_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/temporal-jitter-smoke: tests/features/metalfx-temporal-upscaling/temporal_jitter_smoke.mm tests/features/metalfx-temporal-upscaling/temporal_jitter_wrappers.S src/features/metalfx-temporal-upscaling/TemporalJitter.mm src/features/metalfx-temporal-upscaling/TemporalJitter.S src/features/metalfx-temporal-upscaling/TemporalJitter.h src/common/native/CodePatch.mm src/common/native/CodePatch.h src/integration/menu/NativeMenu.h src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/features/metalfx-temporal-upscaling/temporal_jitter_smoke.mm src/features/metalfx-temporal-upscaling/TemporalJitter.S tests/features/metalfx-temporal-upscaling/temporal_jitter_wrappers.S -framework Foundation -o $@

$(BIN_DIR)/metalfx-smoke: tests/common/metalfx_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/common/metalfx_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/spatial-upscaler-smoke: tests/features/metalfx-spatial-upscaling/spatial_upscaler_smoke.mm src/features/metalfx-spatial-upscaling/SpatialUpscaler.mm src/features/metalfx-spatial-upscaling/SpatialUpscaler.h src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/features/metalfx-spatial-upscaling/SpatialUpscaler.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/temporal-upscaler-smoke: tests/features/metalfx-temporal-upscaling/temporal_upscaler_smoke.mm src/features/metalfx-temporal-upscaling/TemporalUpscaler.mm src/features/metalfx-temporal-upscaling/TemporalUpscaler.h src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/features/metalfx-temporal-upscaling/TemporalUpscaler.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR):
	mkdir -p "$(BIN_DIR)"

RUNTIME_SOURCES = \
	src/features/depth-prepass/DepthPrepass.mm \
	src/features/metalfx-spatial-upscaling/SpatialUpscaler.mm \
	src/features/metalfx-temporal-upscaling/TemporalUpscaler.mm \
	src/features/metalfx-temporal-upscaling/TemporalJitter.mm \
	src/features/metalfx-temporal-upscaling/TemporalJitter.S \
	src/features/metalfx-frame-generation/FrameInterpolation.mm \
	src/features/shadows/ShadowDuplicateFix.mm \
	src/features/thread-idling/ThreadIdling.mm \
	src/features/dynamic-worker-prioritization/DynamicWorkers.mm \
	src/features/lua-jump-fix/LuaJumpFix.mm \
	src/common/gpu/GPUResources.mm \
	src/common/gpu/MetalFXPipeline.mm \
	src/common/native/CodePatch.mm \
	src/integration/menu/NativeMenu.mm \
	src/integration/renderer/Trace.mm

DIAGNOSTIC_SOURCES = \
	src/features/metalfx-frame-generation/FrameLog.mm \
	src/integration/diagnostics/ServerPacingProbe.mm

RUNTIME_HEADERS = \
	src/common/native/SupportedBuild.h \
	src/features/depth-prepass/DepthPrepass.h \
	src/features/render-thread-optimizations/BindFilter.h \
	src/features/metalfx-spatial-upscaling/SpatialUpscaler.h \
	src/features/metalfx-temporal-upscaling/TemporalUpscaler.h \
	src/features/metalfx-temporal-upscaling/TemporalJitter.h \
	src/features/metalfx-frame-generation/FrameInterpolation.h \
	src/features/metalfx-frame-generation/FrameLog.h \
	src/features/shadows/ShadowDuplicateFix.h \
	src/features/thread-idling/ThreadIdling.h \
	src/features/dynamic-worker-prioritization/DynamicWorkers.h \
	src/features/lua-jump-fix/LuaJumpFix.h \
	src/common/gpu/GPUResources.h \
	src/common/gpu/MetalFXPipeline.h \
	src/common/native/CodePatch.h \
	src/integration/menu/NativeMenu.h \
	src/integration/diagnostics/ServerPacingProbe.h

$(BIN_DIR)/libBG3MetalFXTrace.dylib: $(RUNTIME_SOURCES) $(DIAGNOSTIC_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -dynamiclib $(RUNTIME_SOURCES) $(DIAGNOSTIC_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

$(BIN_DIR)/libBG3MetalFX.dylib: $(RUNTIME_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -DBG3MFX_NO_TRACE=1 -dynamiclib $(RUNTIME_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

# Same quiet feature path, with standalone fixture exports unavailable to players.
$(BIN_DIR)/libBG3MetalFXTest.dylib: $(RUNTIME_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -DBG3MFX_NO_TRACE=1 -DBG3MFX_STANDALONE_TEST_HOOKS=1 -dynamiclib $(RUNTIME_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

$(BIN_DIR)/metalfx-probe: tools/probes/metalfx_probe.m | $(BIN_DIR)
	xcrun clang -fobjc-arc -mmacosx-version-min=26.0 $< $(FRAMEWORKS) -o $@

test: $(BIN_DIR)/supported-build-smoke $(BIN_DIR)/bind-filter-smoke $(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/frame-interpolation-smoke $(BIN_DIR)/metal4-bridge-smoke $(BIN_DIR)/runtime-smoke $(BIN_DIR)/metalfx-smoke $(BIN_DIR)/temporal-quality-smoke $(BIN_DIR)/temporal-jitter-smoke $(BIN_DIR)/spatial-upscaler-smoke $(BIN_DIR)/temporal-upscaler-smoke $(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/prepass-trim-smoke $(BIN_DIR)/libBG3MetalFX.dylib $(BIN_DIR)/libBG3MetalFXTest.dylib $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/supported-build-smoke
	$(BIN_DIR)/bind-filter-smoke
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib hdr
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib hdr
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib scaled
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib scaled
	$(BIN_DIR)/frame-interpolation-smoke
	BG3MFX_TEST_DIRECT_INPUTS=1 $(BIN_DIR)/frame-interpolation-smoke
	$(BIN_DIR)/metal4-bridge-smoke
	$(BIN_DIR)/temporal-jitter-smoke
	$(BIN_DIR)/metalfx-smoke
	mkdir -p "$(EVIDENCE_DIR)"
	quality_evidence=$$(mktemp -d "$(EVIDENCE_DIR)/$$(date +%F)-temporal-quality-XXXXXX"); \
		$(BIN_DIR)/temporal-quality-smoke "$$quality_evidence/regression"
	$(BIN_DIR)/spatial-upscaler-smoke
	$(BIN_DIR)/temporal-upscaler-smoke
	BG3MFX_TEST_DIRECT_OUTPUT=1 $(BIN_DIR)/temporal-upscaler-smoke
	$(BIN_DIR)/runtime-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	BG3MFX_DEPTH_PREPASS_OPTIMIZATION=1 $(BIN_DIR)/prepass-trim-smoke $(BIN_DIR)/libBG3MetalFX.dylib expect-trim
	BG3MFX_DEPTH_PREPASS_OPTIMIZATION=1 $(BIN_DIR)/prepass-trim-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib expect-trim
	BG3MFX_DEPTH_PREPASS_OPTIMIZATION=0 $(BIN_DIR)/prepass-trim-smoke $(BIN_DIR)/libBG3MetalFX.dylib expect-full

# These exercise the development launch helper, not rendering acceptance.
test-python: $(BIN_DIR)/bg3mfx
	python3 -m unittest discover -s tests -v

clean:
	python3 tools/build/cleanup.py bin "$(BIN_DIR)" "$(EVIDENCE_DIR)"

clean-evidence:
	python3 tools/build/cleanup.py evidence "$(BIN_DIR)" "$(EVIDENCE_DIR)"

$(BIN_DIR)/frame-interpolation-smoke: tests/features/metalfx-frame-generation/frame_interpolation_smoke.mm src/features/metalfx-frame-generation/FrameInterpolation.mm src/features/metalfx-frame-generation/FrameInterpolation.h src/features/metalfx-frame-generation/FrameLog.mm src/features/metalfx-frame-generation/FrameLog.h src/common/gpu/GPUResources.mm src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/features/metalfx-frame-generation/FrameInterpolation.mm src/features/metalfx-frame-generation/FrameLog.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -Isrc -o $@

$(BIN_DIR)/frame-generation-hook-smoke: tests/features/metalfx-frame-generation/frame_generation_hook_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< $(FRAMEWORKS) -o $@

$(BIN_DIR)/bind-filter-smoke: tests/features/render-thread-optimizations/bind_filter_smoke.mm src/features/render-thread-optimizations/BindFilter.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/supported-build-smoke: tests/common/supported_build_smoke.cpp src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CPPFLAGS) -std=c++17 -O2 -Wall -Wextra $< -o $@
