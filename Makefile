VERSION ?= 0.5.0
PREFIX ?= /usr/local
BIN_DIR ?= build/bin
EVIDENCE_DIR ?= build/evidence
CXX = xcrun clang++
CPPFLAGS = -Isrc
CXXFLAGS = $(CPPFLAGS) -std=c++17 -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=26.0
FRAMEWORKS = -framework Foundation -framework Metal -framework MetalFX -framework AppKit -framework QuartzCore

.PHONY: hook-overhead all install test test-python clean clean-evidence
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

$(BIN_DIR)/spatial-hook-smoke: tests/features/metalfx/spatial-upscaling/spatial_hook_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -framework AppKit -o $@

$(BIN_DIR)/new-character-crash-fix-smoke: tests/features/new-character-crash-fix/new_character_crash_fix_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/temporal-hook-smoke: tests/features/metalfx/temporal-upscaling/temporal_hook_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/temporal-replay-smoke: tests/features/metalfx/temporal-upscaling/temporal_replay_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/features/metalfx/temporal-upscaling/temporal_replay_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/temporal-quality-smoke: tests/features/metalfx/temporal-upscaling/temporal_quality_smoke.mm src/features/metalfx/temporal-upscaling/TemporalUpscaler.h src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/features/metalfx/temporal-upscaling/temporal_quality_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

# Optional public-API comparison; no changes to the injected game runtime.
$(BIN_DIR)/temporal-api-compare: tests/features/metalfx/temporal-upscaling/temporal_api_compare.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< $(FRAMEWORKS) -o $@

$(BIN_DIR)/metal4-bridge-smoke: tests/common/metal4_bridge_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/temporal-jitter-smoke: tests/features/metalfx/temporal-upscaling/temporal_jitter_smoke.mm tests/features/metalfx/temporal-upscaling/temporal_jitter_wrappers.S src/features/metalfx/temporal-upscaling/TemporalJitter.mm src/features/metalfx/temporal-upscaling/TemporalJitter.S src/features/metalfx/dynamic-resolution/DynamicResolution.h src/common/native/CodePatch.mm src/common/native/CodePatch.h src/features/metalfx/MetalFX.h src/common/native/SupportedBuild.h src/common/Feature.h src/common/Notice.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/features/metalfx/temporal-upscaling/temporal_jitter_smoke.mm src/features/metalfx/temporal-upscaling/TemporalJitter.S tests/features/metalfx/temporal-upscaling/temporal_jitter_wrappers.S -framework Foundation -o $@

$(BIN_DIR)/metalfx-smoke: tests/common/metalfx_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) tests/common/metalfx_smoke.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/spatial-upscaler-smoke: tests/features/metalfx/spatial-upscaling/spatial_upscaler_smoke.mm src/features/metalfx/spatial-upscaling/SpatialUpscaler.mm src/features/metalfx/spatial-upscaling/SpatialUpscaler.h src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/features/metalfx/spatial-upscaling/SpatialUpscaler.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/temporal-upscaler-smoke: tests/features/metalfx/temporal-upscaling/temporal_upscaler_smoke.mm src/features/metalfx/temporal-upscaling/TemporalUpscaler.mm src/features/metalfx/temporal-upscaling/TemporalUpscaler.h src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm src/common/gpu/MetalFXPipeline.h src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/features/metalfx/temporal-upscaling/TemporalUpscaler.mm src/common/gpu/MetalFXPipeline.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR):
	mkdir -p "$(BIN_DIR)"

RUNTIME_SOURCES = \
	src/features/new-character-crash-fix/NewCharacterCrashFix.mm \
	src/features/render-thread-optimizations/RenderThreadOptimizations.mm \
	src/features/metalfx/spatial-upscaling/SpatialUpscaler.mm \
	src/features/metalfx/temporal-upscaling/TemporalUpscaler.mm \
	src/features/metalfx/temporal-upscaling/TemporalJitter.mm \
	src/features/metalfx/temporal-upscaling/TemporalJitter.S \
	src/features/metalfx/frame-generation/FrameInterpolation.mm \
	src/features/thread-idling/ThreadIdling.mm \
	src/features/reduce-locking/UniformSlices.mm \
	src/features/lua-jump-fix/LuaJumpFix.mm \
	src/features/ssao-blur-fix/SSAOBlurFix.mm \
	src/features/metalfx/dynamic-resolution/DynamicResolution.mm \
	src/features/improved-shadows/ImprovedShadows.mm \
	src/features/duplicate-shadow-fix/DuplicateShadowFix.mm \
	src/features/metalfx/MetalFX.mm \
	src/features/metalfx/MetalFXOptions.mm \
	src/features/metal-hud/MetalHUD.mm \
	src/features/custom-menu/CustomMenu.mm \
	src/features/custom-menu/RenderViewFocus.mm \
	src/common/gpu/GPUResources.mm \
	src/common/gpu/MetalFXPipeline.mm \
	src/common/native/CodePatch.mm \
	src/common/Notice.mm \
	src/features/custom-render-stages/CustomRenderStages.mm \
	src/features/custom-pipeline-bundles/CustomPipelineBundles.mm \
	src/features/metalfx/MetalFXRenderer.mm \
	src/features/metal-hooks/MetalHooks.mm \
	src/features/root/Root.mm
# Root.mm stays last: its constructor, which installs every feature, must run
# after the other files' static initializers (dyld runs them in link order).

DIAGNOSTIC_SOURCES = \
	src/common/EventLog.mm \
	src/features/metalfx/frame-generation/FrameLog.mm

RUNTIME_HEADERS = \
	src/common/native/SupportedBuild.h \
	src/common/Feature.h \
	src/common/EventLog.h \
	src/common/Notice.h \
	src/features/new-character-crash-fix/NewCharacterCrashFix.h \
	src/features/metal-hooks/BindFilter.h \
	src/features/metalfx/spatial-upscaling/SpatialUpscaler.h \
	src/features/metalfx/temporal-upscaling/TemporalUpscaler.h \
	src/features/metalfx/frame-generation/FrameInterpolation.h \
	src/features/metalfx/frame-generation/FrameLog.h \
	src/features/thread-idling/ThreadIdling.h \
	src/features/reduce-locking/UniformSlices.h \
	src/features/lua-jump-fix/LuaJumpFix.h \
	src/features/ssao-blur-fix/SSAOBlurFix.h \
	src/features/metalfx/dynamic-resolution/DynamicResolution.h \
	src/features/improved-shadows/ImprovedShadows.h \
	src/features/improved-shadows/ImprovedShadowsShader.h \
	src/features/duplicate-shadow-fix/DuplicateShadowFix.h \
	src/common/gpu/GPUResources.h \
	src/common/gpu/MetalFXPipeline.h \
	src/common/native/CodePatch.h \
	src/features/metalfx/MetalFX.h \
	src/features/custom-menu/CustomMenu.h \
	src/features/custom-render-stages/CustomRenderStages.h \
	src/features/custom-pipeline-bundles/CustomPipelineBundles.h src/features/custom-pipeline-bundles/PipelineRecord.h \
	src/features/custom-menu/RenderViewFocus.h \
	src/features/metal-hooks/MetalHooks.h \
	src/features/metal-hooks/MetalHooksInternal.h

$(BIN_DIR)/libBG3MetalFXTrace.dylib: $(RUNTIME_SOURCES) $(DIAGNOSTIC_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -dynamiclib $(RUNTIME_SOURCES) $(DIAGNOSTIC_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

$(BIN_DIR)/libBG3MetalFX.dylib: $(RUNTIME_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -DBG3MFX_NO_TRACE=1 -dynamiclib $(RUNTIME_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

# Same quiet feature path, with standalone fixture exports unavailable to players.
# Developer build: the quiet runtime plus dynamic resolution's controller log
# (os_log category `controller`), for measuring without the diagnostic runtime.
$(BIN_DIR)/libBG3MetalFXResolutionLog.dylib: $(RUNTIME_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -DBG3MFX_NO_TRACE=1 -DBG3MFX_RESOLUTION_LOG=1 -dynamiclib $(RUNTIME_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

$(BIN_DIR)/libBG3MetalFXTest.dylib: $(RUNTIME_SOURCES) $(RUNTIME_HEADERS) | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) -DBG3MFX_NO_TRACE=1 -DBG3MFX_STANDALONE_TEST_HOOKS=1 -dynamiclib $(RUNTIME_SOURCES) $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

# Synthetic BG3/Metal 4 bridge handshake scenarios (developer probe; several
# deliberately stall for seconds, so it is not part of make test).
$(BIN_DIR)/bridge-handshake-sim: tools/probes/bridge_handshake_sim.mm src/common/gpu/GPUResources.mm src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/common/gpu/GPUResources.mm $(FRAMEWORKS) -o $@

$(BIN_DIR)/metalfx-probe: tools/probes/metalfx_probe.m | $(BIN_DIR)
	xcrun clang -fobjc-arc -mmacosx-version-min=26.0 $< $(FRAMEWORKS) -o $@

$(BIN_DIR)/uniform-lock-sim: tools/probes/uniform_lock_sim.cpp | $(BIN_DIR)
	xcrun clang++ -std=c++17 -O2 -Wall -Wextra -mmacosx-version-min=26.0 $< -o $@

test: $(BIN_DIR)/supported-build-smoke $(BIN_DIR)/root-smoke $(BIN_DIR)/custom-render-stages-smoke $(BIN_DIR)/custom-pipeline-bundles-smoke $(BIN_DIR)/duplicate-shadow-fix-smoke $(BIN_DIR)/improved-shadows-smoke $(BIN_DIR)/native-shadows-smoke $(BIN_DIR)/ssr-history-island-smoke $(BIN_DIR)/ssao-blur-fix-smoke $(BIN_DIR)/bind-filter-smoke $(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/frame-interpolation-smoke $(BIN_DIR)/metal4-bridge-smoke $(BIN_DIR)/runtime-smoke $(BIN_DIR)/metalfx-smoke $(BIN_DIR)/temporal-quality-smoke $(BIN_DIR)/temporal-jitter-smoke $(BIN_DIR)/spatial-upscaler-smoke $(BIN_DIR)/temporal-upscaler-smoke $(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/new-character-crash-fix-smoke $(BIN_DIR)/libBG3MetalFX.dylib $(BIN_DIR)/libBG3MetalFXTest.dylib $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/supported-build-smoke
	$(BIN_DIR)/root-smoke
	$(BIN_DIR)/custom-render-stages-smoke
	$(BIN_DIR)/custom-pipeline-bundles-smoke
	$(BIN_DIR)/duplicate-shadow-fix-smoke
	$(BIN_DIR)/improved-shadows-smoke
	$(BIN_DIR)/native-shadows-smoke
	$(BIN_DIR)/ssr-history-island-smoke
	$(BIN_DIR)/ssao-blur-fix-smoke
	$(BIN_DIR)/bind-filter-smoke
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib hdr
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib hdr
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib scaled
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib scaled
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib overlays
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib overlays
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib startup-reset
	$(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib startup-reset
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
	constants_trace=$$(mktemp "$(EVIDENCE_DIR)/constants-trace-XXXXXX"); \
		BG3MFX_TRACE="$$PWD/$$constants_trace" BG3MFX_TRACE_CONSTANTS=1 $(BIN_DIR)/runtime-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib && \
		test "$$(grep -c '"event":"shaderConstants"' "$$constants_trace")" -eq 2 && rm "$$constants_trace" && \
		echo "Constant snapshots recorded without call tracing (synthetic, offscreen)."
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib no-taa
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib no-taa
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib resize
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib resize
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib tonemap
	$(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib tonemap
	BG3MFX_SKIP_FSR_TONEMAP=0 $(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib tonemap
	BG3MFX_TEST_ERRORS_STDERR=1 $(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib bad-format
	BG3MFX_TEST_ERRORS_STDERR=1 $(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib bad-format
	$(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	BG3MFX_TRACE_RENDER_CALLS=1 BG3MFX_TRACE_CONSTANTS=1 $(BIN_DIR)/temporal-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	BG3MFX_TRACE_RENDER_CALLS=1 $(BIN_DIR)/spatial-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	BG3MFX_TRACE_RENDER_CALLS=1 $(BIN_DIR)/frame-generation-hook-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib
	$(BIN_DIR)/new-character-crash-fix-smoke $(BIN_DIR)/libBG3MetalFX.dylib
	BG3MFX_TRACE_RENDER_CALLS=1 $(BIN_DIR)/new-character-crash-fix-smoke $(BIN_DIR)/libBG3MetalFXTrace.dylib expect-event

# These exercise the development launch helper, not rendering acceptance.
test-python: $(BIN_DIR)/bg3mfx
	python3 -m unittest discover -s tests -v

clean:
	python3 tools/build/cleanup.py bin "$(BIN_DIR)" "$(EVIDENCE_DIR)"

clean-evidence:
	python3 tools/build/cleanup.py evidence "$(BIN_DIR)" "$(EVIDENCE_DIR)"

$(BIN_DIR)/frame-interpolation-smoke: tests/features/metalfx/frame-generation/frame_interpolation_smoke.mm src/features/metalfx/frame-generation/FrameInterpolation.mm src/features/metalfx/frame-generation/FrameInterpolation.h src/features/metalfx/frame-generation/FrameLog.mm src/features/metalfx/frame-generation/FrameLog.h src/common/gpu/GPUResources.mm src/common/gpu/GPUResources.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< src/features/metalfx/frame-generation/FrameInterpolation.mm src/features/metalfx/frame-generation/FrameLog.mm src/common/gpu/GPUResources.mm $(FRAMEWORKS) -Isrc -o $@

$(BIN_DIR)/frame-generation-hook-smoke: tests/features/metalfx/frame-generation/frame_generation_hook_smoke.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< $(FRAMEWORKS) -o $@

$(BIN_DIR)/improved-shadows-smoke: tests/features/improved-shadows/improved_shadows_smoke.mm src/features/improved-shadows/ImprovedShadowsShader.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/native-shadows-smoke: tests/features/improved-shadows/native_shadows_smoke.mm src/features/improved-shadows/ImprovedShadows.mm src/features/improved-shadows/ImprovedShadows.h src/features/improved-shadows/ImprovedShadowsShader.h src/features/custom-pipeline-bundles/CustomPipelineBundles.h src/features/custom-pipeline-bundles/PipelineRecord.h src/features/custom-render-stages/CustomRenderStages.h src/common/Feature.h src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

# Developer probe, not part of make test: timings depend on the machine and load.
$(BIN_DIR)/hook-overhead: tools/probes/hook_overhead.mm | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

hook-overhead: $(BIN_DIR)/hook-overhead $(BIN_DIR)/libBG3MetalFX.dylib $(BIN_DIR)/libBG3MetalFXTest.dylib
	$(BIN_DIR)/hook-overhead
	$(BIN_DIR)/hook-overhead $(BIN_DIR)/libBG3MetalFX.dylib
	BG3MFX_FEATURE_RENDER_THREAD_OPTIMIZATIONS=1 BG3MFX_FEATURE_DUPLICATE_SHADOW_FIX=1 BG3MFX_FEATURE_IMPROVED_SHADOWS=1 BG3MFX_FEATURE_NEW_CHARACTER_CRASH_FIX=1 $(BIN_DIR)/hook-overhead $(BIN_DIR)/libBG3MetalFX.dylib
	BG3MFX_FEATURE_RENDER_THREAD_OPTIMIZATIONS=1 BG3MFX_FEATURE_DUPLICATE_SHADOW_FIX=1 BG3MFX_FEATURE_IMPROVED_SHADOWS=1 BG3MFX_FEATURE_NEW_CHARACTER_CRASH_FIX=1 BG3MFX_FEATURE_METALFX=1 $(BIN_DIR)/hook-overhead $(BIN_DIR)/libBG3MetalFXTest.dylib 3

$(BIN_DIR)/bind-filter-smoke: tests/features/metal-hooks/bind_filter_smoke.mm src/features/metal-hooks/BindFilter.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/root-smoke: tests/features/root/root_smoke.mm src/features/root/Root.mm src/common/Feature.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -o $@

$(BIN_DIR)/custom-render-stages-smoke: tests/features/custom-render-stages/custom_render_stages_smoke.mm src/features/custom-render-stages/CustomRenderStages.mm src/features/custom-render-stages/CustomRenderStages.h src/common/Feature.h src/common/native/CodePatch.mm src/common/native/CodePatch.h src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -o $@

$(BIN_DIR)/custom-pipeline-bundles-smoke: tests/features/custom-pipeline-bundles/custom_pipeline_bundles_smoke.mm src/features/custom-pipeline-bundles/CustomPipelineBundles.mm src/features/custom-pipeline-bundles/CustomPipelineBundles.h src/features/custom-pipeline-bundles/PipelineRecord.h src/common/native/CodePatch.mm src/common/Feature.h src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -framework Metal -o $@

$(BIN_DIR)/duplicate-shadow-fix-smoke: tests/features/duplicate-shadow-fix/duplicate_shadow_fix_smoke.mm src/features/duplicate-shadow-fix/DuplicateShadowFix.mm src/features/duplicate-shadow-fix/DuplicateShadowFix.h src/features/custom-render-stages/CustomRenderStages.mm src/features/custom-render-stages/CustomRenderStages.h src/common/Feature.h src/common/native/CodePatch.mm src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CXXFLAGS) $< -framework Foundation -o $@

$(BIN_DIR)/supported-build-smoke: tests/common/supported_build_smoke.cpp src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CPPFLAGS) -std=c++17 -O2 -Wall -Wextra $< -o $@

$(BIN_DIR)/ssr-history-island-smoke: tests/integration/ssr_history_island_smoke.cpp tests/integration/ssr_history_island_wrappers.S src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CPPFLAGS) -std=c++17 -O2 -Wall -Wextra -arch arm64 tests/integration/ssr_history_island_smoke.cpp tests/integration/ssr_history_island_wrappers.S -o $@

$(BIN_DIR)/ssao-blur-fix-smoke: tests/features/ssao-blur-fix/ssao_blur_fix_smoke.cpp tests/features/ssao-blur-fix/ssao_blur_island_wrappers.S src/common/native/SupportedBuild.h | $(BIN_DIR)
	$(CXX) $(CPPFLAGS) -std=c++17 -O2 -Wall -Wextra -arch arm64 tests/features/ssao-blur-fix/ssao_blur_fix_smoke.cpp tests/features/ssao-blur-fix/ssao_blur_island_wrappers.S -o $@
