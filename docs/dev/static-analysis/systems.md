# Game systems

This page maps every system in the executable, top-down. Sizes are code bytes
from the local function map ([systems.tsv](systems.tsv)). Hopper's per-namespace
procedure counts agree with it to within about 2% (see [README](README.md)).
The executable has 125.6 MB of code in 483k named functions. 18.7 MB of that
is static initializers, mostly type-ID registration.

## Architecture in one picture

```text
             ┌──────────────── Objective-C shell (AppDelegate, cocoa::) ────────────────┐
             │   launcher · crash reporter · window/cursor · HID/MFi input · LSMTLView  │
             └──────────────────────────────────┬───────────────────────────────────────┘
                                                │ IApp
                 App / BaseApp  (startup, config, frame stages, main loop)
        ┌──────────────────────────────┬────────┴────────────────────────────────┐
   CLIENT  ecl:: (7.1 MB)          SHARED  eoc:: (3.5 MB)                SERVER  esv:: (13.9 MB)
   presentation, input,            rules, stats, spells,                 authoritative gameplay,
   camera, sound, VFX,             AI grid, character                    story (Osiris), AI, combat,
   timelines, picking              creation, components                  inventory, saves
        │  gui:: / ui:: (5.9 MB) ── Noesis GUI (5.8 MB)                       │ ServerWorker thread
        └──────────────────────────────┬────────────────────────────────────────┘
                 ecs:: (20.0 MB)  entity world · queries · system scheduler · ecs::sync replication
                                       │
                 ls:: (36.9 MB)  engine core: containers, files/paks, resources, threads/jobs,
                 scripting (khonsu Lua, anubis, thoth), savegame, model, rendering stages,
                 visuals, physics/sound/effects front ends
                                       │
          rf:: render framework + rf::metal backend · middleware (PhysX, Wwise, Granny,
          Granite, Bink, Osiris, Lua, RakNet, PlayFab, Steam, Discord, …)
```

The game is split into client (`ecl`), server (`esv`) and shared (`eoc`)
layers. Even in single player it runs a full server on its own thread
(`ServerWorker::DoWork`), and the client sees server state through
replication.

## Size by system

| System | Code | Functions | Role |
| --- | ---: | ---: | --- |
| `ls` | 36.9 MB | 87,695 | Larian engine core ("LSLib") |
| `ecs` | 20.0 MB | 44,360 | Entity–component–system runtime and replication |
| static initializers | 18.7 MB | 211,382 | `ls::TypeId` and other registration run at load |
| `esv` | 13.9 MB | 11,065 | Server (authoritative) game logic |
| `ecl` | 7.1 MB | 6,680 | Client game logic and presentation |
| Noesis GUI | 5.8 MB | 61,126 | XAML UI middleware |
| `gui` | 4.6 MB | 10,427 | Game UI view models and UI systems (on Noesis) |
| `eoc` | 3.5 MB | 4,252 | Shared rules and components |
| PhysX | 2.9 MB | 8,453 | NVIDIA PhysX physics |
| `ui` | 1.3 MB | 9,281 | Larian Noesis integration layer |
| Wwise | 1.3 MB | 5,604 | Audiokinetic audio |
| Granite | 1.1 MB | 1,464 | Graphine virtual texturing |
| OpenSSL/LibreSSL | 0.6 MB | 2,499 | TLS and crypto |
| `gn` | 0.5 MB | 2,109 | Genome: animation blueprints and the node VM |
| `net` | 0.5 MB | 1,714 | Network peer and message layer |
| `eocnet` | 0.4 MB | 1,110 | Game network messages |
| zstd | 0.4 MB | 251 | Compression |
| `gr` | 0.4 MB | 921 | Granny animation integration |
| `rf` | 0.3 MB | 372 | Render framework and Metal backend |
| `App`, `BaseApp` | 0.4 MB | 173 | Application startup and the main loop |
| others | ~5 MB | — | See the sections below and [systems.tsv](systems.tsv) |

## Engine core: `ls::` (36.9 MB)

The largest groups by sub-namespace are:

- **Root `ls::` (20.4 MB):** containers (`DynamicArray`, `HashMap`,
  `SparseArray`, `Signal`, `Function`), files and `.pak` archives
  (`FileSystem`, `PackedFileManager`, `ModdableFilesLoader`), resources
  (`ResourceManager`, `ResourceBank`, the `Visual*` loaders), and threading
  (`ThreadManager`, `Dispatcher`, the `WorkerThread*` job system). It also
  holds the input, sound, effects, physics, camera, level, terrain, cluster,
  HLOD, light-probe, decal and fog front ends, most of which are ECS systems.
- **`ls::model` (5.1 MB):** a type-model registry (`model::Registry`, 1,046
  model types) with converters (`model::conv`), a `ppa` component and
  `model::Writer`. It is likely reflected data used for serialization and
  scripting.
- **`ls::khonsu` (4.0 MB):** the Lua binding layer (`CallApi`, `ExportApi`,
  `ClassApi`, `TypeApi`, `ErrorRegistry`, 359 Khonsu types). Most calls into
  the Lua VM come from here: about 28k from `ExportApi` and 14k from
  `CallApi`.
- **`ls::savegame` (2.9 MB):** the savegame framework, with 120 loader types.
- **`ls::anubis` (1.3 MB):** script-driven behaviour trees (`AnubisTreeRef`
  with `CallOnEnter`, `CallOnLeave`, `CallValid` and `CallSelect`;
  `anubis::System::Update` and `RunPending`), plus an event store and a
  variable registry. These run through Khonsu and Lua.
- **`ls::thoth` (0.2 MB):** the condition and expression machine
  (`thoth::shared::Machine`, `ConditionManager`). It is configured in
  `App::InitGame` and used by spell cast requirements.

`ls` also registers 78 ECS systems. Examples are `RenderFrameSystem`,
`VisualSystem`, the `VisualStream*` systems, `CullSystem`, `OcclusionSystem`,
`LightSystem`, `LightProbeSystem`, `DecalSystem`, `FogVolumeSystem`,
`HLODSystem`, `InstancingSystem`, `TransformSystem`, `TextureCache`, the
`Sound*` systems, `PhysicsECSSystem`, `AnimationBlueprintSystem`,
`EffectsManager`, `ClusterSystem` and `TerrainVisualLoaderSystem`.

## ECS runtime: `ecs::` (20.0 MB)

- **Root (11.0 MB):**
  - **World:** `EntityWorld` handles registration, `Update`, `FlushECBs` and
    components. Entity command buffers queue structural changes and apply
    them in `FlushECBs`.
  - **Queries:** query iterators and views, with 4,842 registered queries.
  - **Scheduling:** `core::SystemDependencyExecutor` runs systems on the
    worker threads.
- **`ecs::sync` (3.7 MB):** client–server replication (582 replicated types,
  component serializers and `EntityReplicationAuthority`).
- **`ecs::legacy` (2.5 MB):** `ImmediateWorldCache`, a compatibility path for
  older object code.

| Registry (from `ls::TypeId<T, Context>`) | Count |
| --- | ---: |
| ECS components (checked / unchecked) | 2,107 / 2,652 |
| One-frame (event) components | 540 |
| ECS systems | 934 |
| ECS queries | 4,842 |
| `ls::model` types | 1,046 |
| Replicated types (`ecs::sync`) | 582 |
| Khonsu (Lua) types | 359 |
| Savegame loader types | 120 |
| Immutable data types (`ImmutableDataHeadmaster`) | 121 |
| Legacy object types | 69 |
| Network protocols (`net::AbstractPeer`) | 90 |
| UI systems (`ui::UISystemsContext`) | 29 |

The ECS systems break down by namespace as follows: `esv` 471, `ecl` 311,
`ls` 78, `gui` 52, `phx` 10, `eoc` 7, `navcloud` 3, `ffx` 1 and `gr` 1. The
components break down as `esv` 938, `eoc` 761, `ecl` 563, `ls` 321, `gui` 38
and `navcloud` 22 (see
[ecs-components-by-namespace.tsv](ecs-components-by-namespace.tsv)). The
full system list is in [ecs-systems.txt](ecs-systems.txt).

## Gameplay

### Server: `esv::` (13.9 MB, 471 systems, 938 components)

This is the authoritative simulation.

- **Largest sub-namespaces:** `spell_cast`, `inventory`, `status`,
  `character_creation`, `sight`, `functor`, `party`, `spell_state`, `combat`,
  `interrupt`, `sound`, `ai`, `hotbar`, `script`, `ftb`,
  `crowds`, `replication`, `death`, `camp`, `relation` and `ownership`.
- **Most systems:** `inventory` (24), `tutorial` (15), `unsheath` (15), `ai`
  (14), `interrupt` (11), `crowds` and `script` (10 each), `item` (9),
  `escort`, `photo_mode`, `pickup`, `stats`, `status` and `trade` (8 each),
  and `combat` (7).
- **Systems in the namespace root (98):**
  - **Character and items:** `CharacterManager`, `ItemManager`,
    `InventorySystem`
  - **Movement:** `MovementSystem`, `PathingSystem`, `FallingSystem`,
    `GravitySystem`
  - **Rules and stats:** `RPGStatsSystem`, `BoostSystem`, `PassiveSystem`,
    `RollSystem`, `FeatSystem`
  - **Combat objects:** `ProjectileManager`, `EffectManager`,
    `EnvironmentalStatusManager`
  - **Narrative:** `DialogSystem`, `CrimeHandler`, `GameOverSystem`,
    `RewardManager`
  - **Persistence and modules:** `SaveSystem`, `LevelInstanceSaveSystem`,
    `ModuleLoadSystem`, `SessionLoadSystem`
  - **Replication:** `NetEntityManager`, `DeadReckoningSystem`,
    `LevelInstanceReplicationSystem`
  - **Other:** `GameAnalyticsSystem`, `AnubisExecutor`, and more
- **Story:**
  - `esv::StoryImplementation` fires Osiris events.
  - `osi::OsirisManager` handles `InitStory`, `SynchWithStory`,
    `FireBufferedNotifications` and the event buffer.
  - The story VM itself is in `libOsiris.dylib`, which is imported through
    `COsiArgumentDesc` and related symbols. `esv` makes about 2.4k direct
    calls into `osi`.
- **Server-wide managers:**
  - **Networking and lobby:** `GameServer`, `EocServer`, `LobbyManagerOrigins`
  - **Party and trade:** `DiplomacyManager`, `GameControl` (trade, portals)
  - **Other:** `ListeningManager`, `EntityManager`, `PlanParser` (AI plans)

### Client: `ecl::` (7.1 MB, 311 systems, 563 components)

This is presentation and local control.

- **Largest sub-namespaces:** `sound`, `character_creation`, `spell_cast`,
  `spell_preview`, `camera`, `crowds`, `animation`, `timeline`, `screen_fade`,
  `invisibility`, `hit` and `lariannet`.
- **Most systems:** `dummy` (23, alongside the `TimelineDummy*` systems), `sound` (22),
  `photo_mode` (20), `camera` (12), `splitscreen` (9), `timeline` (9),
  `crowds` (6), `item` (5) and `mod` (5).
- **Systems in the namespace root (84):**
  - **Camera:** `CameraSystem`, `CameraSplineSystem`
  - **Visuals:** `EquipmentVisualsSystem`, `OutlineSystem`,
    `SeeThroughSystem`, `ShroudManager`, `SurfaceManager`, `TerrainManager`,
    `AtmosphereManager`, `CharacterLightSystem`, `SurfaceLightSystem`
  - **Audio:** `MusicManager`, the `Sound*` systems, `GameplaySoundSystem`
  - **Timelines:** about ten `Timeline*` systems for cutscenes and dialog
  - **Other:** `PickingHelperManager`, `LEDSystem`
- **Control:**
  - `ecl::EocClient` handles load, input events, controller and keyboard
    modes, and quit.
  - `ecl::GameClient` runs the client state machine (see
    [app-lifecycle.md](app-lifecycle.md#6-game-state-machines)).
  - `ecl::GameControl` and `ecl::GameInput` handle player commands, hover
    and pick.
  - `ecl::PlayerManager` manages local and split-screen players.

### Shared rules: `eoc::` (3.5 MB, 761 components)

This is shared rules and data, used by both client and server.

- **Contents:** `character_creation`, `stats`, `spell`, `spell_cast`, `party`,
  `aigrid`, `notification`, `active_roll`, `ruleset`, `action_resource`,
  `roll`, `inventory`, `interrupt`, `lightbar_haptics`, `spatial_grid` and
  `photo_mode`.
- **Registration:** `eoc::RegisterComponents` is 425 KB.
- **AI and tactics:** `eoc::AiGrid` (with a worker-thread kernel) and
  `eoc::CoverManager`.
- **Stats data:** comes from `RPGStats` (treasure tables and stat files),
  `DivinityStatsSystem` and `CRPGStats_*`.

### Other gameplay modules

| Module | Role |
| --- | --- |
| `navcloud` (3 systems, 22 components) | Navigation: regions, obstacles, pathfinding searches, navmesh generation |
| `LSDialogs` | Dialog trees: `DialogManager`, `DialogInstance` state and flag collections |
| `aspk` | Timeline and keyframe property data (`TimelineConstructor`) |
| `ik`, `fx` | Inverse kinematics nodes; facial animation actor state (`fx::actor_state`, with `FaceFXSDM`) |
| `phx` (10 systems) | PhysX integration: shapes, ragdolls, the cluster simulation toggle |
| `gn`, `gr` | Genome animation blueprints (logic and array nodes, compiler) and the Granny animation nodes |

## UI: `gui::`, `ui::` and Noesis (11.7 MB)

- **`gui::` (4.6 MB, 52 systems):**
  - **View models:** game UI view models (`vmcharacter`, `vmplayer`,
    `vmpassive`, `vmgamedata`, …), tooltips and stat descriptions, hotbar,
    containers, alchemy, camp and rest, and the context menu.
  - **Mods and multiplayer:** the mod list and ordering, crossplay, and
    split-screen systems.
  - **Session UIs:** character creation and photo mode.
- **`ui::` (1.3 MB):** `NoesisUIManager`, the UI state machine, and the
  `deferred`, `collections`, `converters` and `brushes` sub-namespaces.
- **Noesis GUI (5.8 MB):** the XAML runtime. `gui` makes about 14k direct
  calls into Noesis and `ui` about 6.9k.

## Scripting

There are three script layers:

1. **Lua 5.x** (`_lua_*`, 0.08 MB of VM code). It is driven by `ls::khonsu`.
   The server calls `_lua_gc` from `esv::GameStateRunning::Update`.
2. **Osiris story** in `libOsiris.dylib`, run through `osi::OsirisManager`
   and `esv::StoryImplementation`.
3. **Anubis behaviour trees** and **thoth conditions**, running on Khonsu
   and Lua.

## Networking and online services

| Layer | Contents |
| --- | --- |
| `net` | `AbstractPeer` (90 protocols), message factory, profile manager, community manager |
| `eocnet` | Game messages (surface, dialog, game-control and lobby messages; `RegisterMessages`) |
| `ecs::sync` | Entity replication over `net` |
| RakNet | Transport, through `RakNet::RakPeer` |
| `lsnet` | Larian online API (HTTP and websocket): lobbies, matchmaking, friends, cloud saves |
| `lnb` | LarianNet front end: platform friends, matchmaking manager |
| `stm`, Steamworks | Steam stats, matchmaking, cloud, avatars, virtual keyboard (`libsteam_api.dylib`) |
| PlayFab | Core, Services and Party frameworks (crossplay and party) |
| Discord | `discord_game_sdk.dylib` |
| mod.io | In-game mod browser (`ugc`) |
| libcurl, libwebsockets, OpenSSL | HTTP, websocket and TLS stacks |

## Rendering

- **`rf::` (0.3 MB):** the render framework. Its main classes are
  `rf::metal` (146 functions, the Metal backend), `IAppStage`, `StageGroup`,
  `SceneGraph`, `RenderFrame` and `OffscreenRenderFrame`, `RenderView`,
  `RendererCommandBuffer`, `CameraController`, `GPUDevice`,
  `GlobalRenderTargetManager` and `GraphicSettings`.
- **Render stages:** they live in `ls` and `ecl`, and are put together by
  `BaseApp::InitFrameStages` and `App::InitFrameStages`:
  - **Culling:** `CullStage`, `ShadowCullStage`, `LocalLightShadowCullStage`,
    `VistaShadowCullStage`, `PreVertexProcessingCullStage`,
    `TextureCullStage`, `ecl::SurfaceCullStage`
  - **Geometry:** `VertexProcessingStage`, `DeferredBufferStage`,
    `VelocityRenderStage`, `DecalRenderStage` (and the deferred decal
    sub-stages)
  - **Shadows:** `CascadedShadowBufferStage`, `CascadedShadowMaskStage`,
    `LocalLightShadowStage`, `ShadowTileAssignmentStage`
  - **Lighting:** `ClusteredAssignmentStage`, `LightingRenderStage`,
    `LightingCombineRenderStage`, `SSAOStage`, `SSRStage`
  - **Sky and transparency:** `SkyRenderStage`, `VolumetricCloudsRenderStage`,
    `AlphaRenderStage`, `UnlitRenderStage`, `EmissiveRenderStage`
  - **Effects:** `FxRenderPrepareStage`, `FxRenderUpdateStage`
  - **Virtual textures:** `VtResolveRenderStage`
  - **Post and UI:** `PostProcessStage` (DOF and others), `GameUIRenderStage`,
    `CombineUIRenderStage`
  - **Client-specific:** `ecl::OutlineRenderStage`, `ecl::RegionRoomRenderStage`,
    and the `ecl::Surface*` stages
- **Virtual texturing:** `vt::GraniteManager` drives Granite: feedback,
  begin-frame and tile files.
- **Occlusion culling:** Masked Occlusion Culling, on the CPU.

This page only places the renderer within the rest of the game. It does not
cover the Metal API surface or the shader catalogue.

## Audio and video

- **Wwise:** `ww::WwiseManager`, `ls::SoundManager` and the `Sound*` ECS
  systems for routing, occlusion, materials and attachment.
- **Codecs:** Opus and Ogg/Vorbis.
- **Video:** Bink 2, through `bik::BinkManager` and `libBink2Mac.dylib`.

## Startup modules (`*SDM`)

There are 22 `<Name>SDM::Init` and `Shutdown` pairs. Each brings up one
module: `CoreLibSDM`, `GameEngineSDM`, `RenderFrameworkSDM`, `PhysXSDM`,
`WwiseBindingSDM`, `GrannyBindingSDM`, `NoesisGUIBindingSDM`,
`KhonsuBindingSDM`, `CocoaBindingSDM`, `GenomeSDM`, `GenomeFunctionSDM`,
`GenomeStateMachineSDM`, `IKSDM`, `FaceFXSDM`, `LSDialogsSDM`, `GameNetSDM`,
`EocNetSDM`, `EocSharedSDM`, `EocClientSDM`, `EocServerSDM`,
`EocServerMonitorSDM` and `AllSparkCoreSDM`. `CoreLibSDM::Init(ArgumentString)`
is called directly from `-[AppDelegate launchGame]` (REA).

## Third-party libraries in the executable

Besides the libraries above, the executable contains:

- **Compression:** zstd, LZ4, zlib/minizip and BitKnit
- **Images:** libwebp and libpng
- **XML:** expat and tinyxml2
- **Crash reporting:** PLCrashReporter
- **NVIDIA:** NvCloth (`NvClothCreateFactoryCPU`)
- **Animation:** Granny 3D
- **Runtime:** libc++

The bundled dynamic libraries are `libsteam_api`, `discord_game_sdk`,
`libBink2Mac`, `libOsiris`, `HttpClient`, and the PlayFab Core, Services and
Party frameworks.

## How the systems call each other

These are direct calls between systems, excluding calls into functions of 64
bytes or less:

| Calls | From → To |
| ---: | --- |
| 73.6k | `esv` → `ls` |
| 68.7k | `ecs` → `ls` |
| 42.7k | `ecl` → `ls` |
| 32.6k | `ls` → Lua (through `ls::khonsu`) |
| 23.3k | `esv` → `ecs` |
| 20.6k | `gui` → `ls` |
| 20.1k | `eoc` → `ls` |
| 14.0k | `gui` → Noesis |
| 10.6k | `ecl` → `ecs` |
| 8.6k | `ls` → `ecs` |
| 7.3k | `gui` → `ui` |
| 6.9k | `ui` → Noesis |
| 6.8k | `esv` → `eoc` |
| 3.9k | `ls` → `rf` |
| 2.8k | `ecl` → `eoc` |
| 2.4k | `esv` → `osi` |

The dependency direction is consistent. The game layers (`esv`, `ecl`, `eoc`,
`gui`) sit on `ecs` and `ls`, and only `ls` talks to the render framework.
There are no direct `ecl`↔`esv` calls at all, in either direction. The two
sides communicate only through `net`, `eocnet` and `ecs::sync`.
