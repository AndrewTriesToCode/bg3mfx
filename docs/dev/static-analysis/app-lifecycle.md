# App lifecycle

This page traces how the process starts, how the engine and game come up, and
what runs each frame. Every edge marked **REA** is a direct callee that REA's
Hopper provider reported. All of them are listed in
[rea-callees.tsv](rea-callees.tsv). Edges marked **local** come from the
`objdump` call graph only. Virtual and `objc_msgSend` dispatch that is
resolved at runtime is not visible to either tool. Those gaps are marked
"(indirect)".

```text
_main ─► NSApplicationMain ─► -[AppDelegate applicationDidFinishLaunching:]
                                   │ crash reporter, launcher, user defaults
                                   ▼
                             -[AppDelegate launchGame]
                                   │ CoreLibSDM::Init, CocoaWindowManager(IApp*)
                                   │ Cocoa event pump
                                   ▼ (indirect, IApp)
     BaseApp::Start ─► BaseApp::InitEngine ─► App::InitGame ─► App::InitServer
                                                   │              └► esv::Register{Components,Systems}
                                                   ├► ecl::EocClient::Load / ConfigureECS
                                                   │                   └► ecl::RegisterSystems
                                                   └► App::CreateECS (ls/eoc/gui registration)
     per frame (main thread)            server thread
     App::Update                        ServerWorker::DoWork
       ├► ecl::GameClient::PreUpdate      ├► ls::Dispatcher::Process
       ├► ecs::EntityWorld::Update        ├► esv::GameStateMachine::Update
       │    └► SystemDependencyExecutor   ├► ecs::EntityWorld::Update
       └► net::AbstractPeer::PostUpdate   └► ls::GameClock::CapFrame
```

## 1. Process start: the Objective-C shell

| Step | Function | Evidence | What it does |
| --- | --- | --- | --- |
| Entry | `_main` `0x100b911e8` | REA | Calls `getcwd`, `strrchr`, `strdup` and `chdir` to set the working directory from the executable path, then calls `NSApplicationMain` |
| Launch | `-[AppDelegate applicationDidFinishLaunching:]` `0x100b8db1c` | REA | Reads `_NSGetArgc`/`_NSGetArgv` into an `ls::ArgumentString` and checks `NSUserDefaults` (`objectForKey:`). Also checks modifier keys (`CGEventSourceFlagsState`), then calls `enableCrashReporting`, `showCrashReporter`, `showLauncher` or `launchGame` |
| Game | `-[AppDelegate launchGame]` `0x100b8dd80` | REA | See below |

`launchGame` (REA, 71 callees) does the following:

- **Arguments and paths:** builds the command line (`OSXArgumentString::AddArg`),
  then calls `CoreLibSDM::Init(ArgumentString)` and `ls::Path::UpdateRoots`.
- **Helper process:** runs one through `NSTask` (`setLaunchPath:`,
  `setArguments:`, `launch`, `waitUntilExit`) and parses its output as a
  property list (`pipe`, `readDataToEndOfFile`, `propertyListWithData:`).
- **Disk checks:** calls `statfs` and `pathconf`.
- **Error dialogs:** uses `NSRunCriticalAlertPanel` and
  `NSRunInformationalAlertPanel`.
- **Window and app:** constructs `cocoa::CocoaWindowManager(IApp*)`, the
  window, cursor and input owner.
- **Controllers:** starts wireless controller discovery and
  `openConnectedMFiDevices`.
- **Event pump:** runs Cocoa events itself (`nextEventMatchingMask:…`,
  `sendEvent:`).
- **Shutdown:** calls `ls::StaticDataManager::Shutdown` and `_exit`.

Engine startup happens through `IApp` virtual calls from here, which is why
`BaseApp::Start` has no direct callers.

Other shell classes:
- **`cocoa::CocoaWindowManager`:** window, cursors, cursor overlay, and the
  `OpenController` overloads for IOHID and GameController devices.
- **Input devices:** `cocoa::HIDInputDevice` and `cocoa::MFIInputDevice`.
- **Views:** `LSMTLView` is the Metal view; the launcher and crash-reporter
  UIs are in Objective-C.

## 2. Engine startup (`BaseApp`)

`BaseApp::Start(ls::InitStruct*)` `0x105d0d3ac` (REA, 56 callees):

- **Files:** mounts paths and the file system (`FileSystem::SetMediaPath`,
  `DoesDirectoryExist`, `CopyFilesFromDir`), then loads the `.pak` archives
  with `PackedFileManager::LoadPackFiles`.
- **Strings:** loads localized strings with
  `TranslatedStringRepository::LoadFromContextFolder`.
- **Threads:** starts engine threads (`ThreadManager::CreateThread`,
  `RegisterDispatcher`, `RegisterThreadName`, `ls::Dispatcher`).
- **Renderer:** constructs the first Metal command buffer
  (`rf::metal::MTLRendererCommandBuffer`).

`BaseApp::InitEngine()` `0x105d13718` (REA, 31 callees):

- **Worker threads:** sets up the job system (`WorkerThreadScheduler`,
  `WorkerThreadWorker::Init`, `WorkerThreadBatch::Init`, and a bounded MPMC
  job queue).
- **Resources:** creates the resource bank (`ResourceBank`,
  `ResourceManager::FillBank`).
- **Terrain:** creates the terrain brush texture arrays.
- **Window:** builds the window title.

Other engine-level steps:
- **`BaseApp::InitAPI`:** graphics API setup.
- **`BaseApp::LoadGraphicSettingsConfig`:** graphics settings.
- **`BaseApp::InitFrameStages`:** the render pipeline (section 5).
- **Shutdown:** `BaseApp::ExitAPI` and `BaseApp::ExitEngine`.

## 3. Game startup (`App`)

`App::InitGame()` `0x100bcb908` (REA, 82 callees) creates the game's data
managers and middleware. The main groups are:

- **Data:**
  - `App::RegisterDataManagers` (158 KB, the largest App function, which
    registers every static data type)
  - `ls::GlobalTemplateManager::Initialize`
  - `ls::FileFormatIO::LoadFile`
- **Animation (Genome):**
  - `gn::GenomeManager` and `gn::GenomeTypeManager`
  - `SetupAnimationBlueprintPlugins` for `ls`, `esv`, `ik` (inverse
    kinematics) and `gr` (Granny, through `gr::FactoryGr2`)
- **Audio and video:**
  - `ww::WwiseManager` and `ls::SoundManager::HandleInitBankLoading` (Wwise)
  - `bik::BinkManager` (Bink video)
- **Physics and cloth:**
  - `ls::PhysicsSystem::InstallPhysicsDataLoader`
  - `NvClothCreateFactoryCPU` (NVIDIA NvCloth on the CPU)
- **Visuals:** `ls::ResourceManager::InstallVisualLoader` and
  `InstallGenomeAnimationManager`.
- **Rules:** `ls::thoth::shared::ConditionManager` and `Machine::Configure`
  (thoth is the condition/expression machine used by spells and rules).
- **Client:** `ecl::EocClient::Load(CommunityManager*, UIManager*)`,
  `ConfigureECS`, `SetControllerMode` and `SetKeyboardMode`.
- **Server:** `App::InitServer` (40 KB).
- **ECS:** `ecs::EntityWorld::EndRegisterPhase`, `EntityHandleGenerator::Create`,
  and the generic camera through `ls::CameraSystem::SetupGenericCamera`.

The ECS registration is split by owner:

| Registered by | Calls | Evidence |
| --- | --- | --- |
| `App::CreateECS` `0x100bd7e1c` | `ecs::EntityWorld::EntityWorld`, `ls::RegisterShared/ClientComponents`, `ls::RegisterShared/ClientSystems`, `eoc::RegisterComponents`, `eoc::RegisterComponentDependencies`, `eoc::RegisterSystems`, `gui::RegisterComponents`, `gui::RegisterSystems` | REA |
| `ecl::EocClient::ConfigureECS` | `ecl::RegisterSystems` (481 KB) | local |
| `App::InitServer` | `esv::RegisterComponents` (557 KB), `esv::RegisterSystems` (693 KB) | local |

`esv::EocServer::StartUp(eoc::ServerInit const&)` `0x1010f0d0c` (REA, 38
callees) is called from `Eoc::StartServer` and starts the server side:

- **Mods:** loads the mod and module list (`ModuleSettings::CreateModFromSettings`).
- **Replication:** registers `ecs::sync` serializers and
  `ecs::sync::RegisterMessages`.
- **Networking:** creates the network peer (`net::AbstractPeer`) and calls
  `esv::GameServer::Initialize`.
- **Lobby:** `LobbyManagerOrigins::UpdateLobbyData`.
- **Spells:** creates `eoc::spell::CastRequirementsManager` on the thoth machine.
- **State:** sets the first server game state with
  `esv::GameStateMachine::SetTargetState`.

## 4. Per-frame path

**Main thread.** `App::Update(ls::GameTime const&)` `0x100bd4758` (REA, 40
callees):

- **Client:** `ecl::GameClient::PreUpdate` runs the client game state
  machine.
- **ECS:** `ecs::EntityWorld::Update` runs the client world.
- **Network:** `net::AbstractPeer::PostUpdate`.
- **Players:** `ecl::PlayerManager::CreatePlayer` and `DestroyPlayer` (local
  and split-screen players), plus `ecl::SavegameManager::GatherSavedFilesLocal`.
- **Effects and loading:** `ls::EffectsManager::PostSceneUpdate`,
  `ls::LoadingScreenManager::Update`, and `ecl::screen_fade` requests.
- **Input:** `ls::InputManager::GetInputValue`.
- **Jobs:** `WorkerThreadScheduler::TryScheduleBatch` and `ClearBatch`.

**Server thread.** `ServerWorker::DoWork()` `0x100c8eb9c` (REA, 25 callees)
is the server loop:

- **Messages:** `ls::Dispatcher::Process`.
- **State:** `esv::GameStateMachine::Update`.
- **ECS:** `ecs::EntityWorld::Update` and `FlushECBs` on the server world.
- **Levels:** `esv::Level::DeactivateSystems`.
- **Frame pacing:** `ls::GameClock::CapFrame` caps the server frame rate.

The server is a separate world on its own thread, even in single player.
Client and server talk through the `net` and `ecs::sync` replication layers.

**ECS tick.** `ecs::EntityWorld::Update` `0x10638ec08` (REA, 9 callees):

- **Systems:** `ecs::core::SystemDependencyExecutor::ExecuteWTKernel` runs the
  system dependency graph on the worker threads.
- **Jobs:** `WorkerThreadBatch` handles flush, wait and steal, through
  `WorkerThreadScheduler::StealJob` and `ScheduleJob`.
- **Command buffers:** `FlushECBs` applies the queued entity changes.

## 5. Render pipeline setup

`App::InitFrameStages(rf::RenderView*)` (REA) calls
`BaseApp::InitFrameStages(rf::RenderView*, ls::Span<rf::AppStageType>)`. It
then inserts post-process steps (`ls::PostProcessStage::InsertStep`) and
sub-stages (`ls::RenderSubStage`), and registers tracked stages with
`rf::SceneGraph::AddTrackedAppStage` and `rf::StageGroup::AddAppStageBefore`.

`BaseApp::InitFrameStages` is 30 KB. It builds the stage list with
`rf::StageGroup::AddAppStage`. The local call graph adds `ls::CullStage`,
`ls::RenderContext` and `rf::RendererCommandBuffer::SetUseRollingBuffers`,
which Hopper's shortened procedure body leaves out. The stage classes are
listed in [systems.md](systems.md#rendering).

## 6. Game state machines

Client and server each run their own state machine, built from
`GameState*::Enter`, `Update` and `Exit` classes (335 methods in total).

| Side | States |
| --- | --- |
| Client (`ecl::GameState*`, driven by `ecl::GameClient`) | Init, InitMenu, InitNetwork, InitConnection, Menu, LoadMenu, Lobby, Join, StartServer, StartLoading, LoadModule, LoadSession, LoadLevel, StopLoading, PrepareRunning, Running, Paused, Save, SwapLevel, UnloadLevel, UnloadModule, UnloadSession, Disconnect, Idle, Exit, AnalyticsSessionEnd, Threaded |
| Server (`esv::GameStateMachine`) | Init, LoadModule, LoadSession, LoadLevel, Sync, Running, Paused, Save, ReloadStory, UnloadLevel, UnloadModule, UnloadSession, Disconnect, Exit |

The largest states by code are the server's `ReloadStory::Update` (22 KB,
which reloads Osiris story) and `Save::Enter` (11 KB), and the client's
`Running::Update` (14 KB) and `Init::Do` (5 KB).

The Running states call the following (REA):

- **Client `GameStateRunning::Update`:**
  - **Rules:** `ls::thoth::shared::Machine::Update`
  - **Player control:** `ecl::GameControl::Update` and `ecl::GameInput`
    (hover and pick)
  - **World:** `ecl::Level::Update`
  - **Selection:** `ecl::PickingHelper` and spell-cast targeting
  - **Events:** `ls::BufferedEventManager::FireEvents`
  - **Mode:** `StartRealtimeRunning`
- **Server `GameStateRunning::Update`:**
  - **Story:** `esv::StoryImplementation::FireEvents` (Osiris story events)
  - **AI:** `eoc::AiGrid::ExecuteWTKernel` and `eoc::CoverManager::Update`
  - **Party and trade:** `esv::DiplomacyManager::IncrementVote` and
    `esv::GameControl::ExecuteDealTrade`
  - **Cleanup:** `esv::EntityManager::DestroyDelayed`
  - **Scripting:** `_lua_gc` (Lua garbage collection)
