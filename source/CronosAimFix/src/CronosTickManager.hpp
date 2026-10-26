#pragma once
#include "uevr/API.hpp"

using namespace uevr;

// ---------------------------------------------------------------------------
// CronosTickManager
//
// Owns the on_pre_engine_tick and on_post_engine_tick logic that was
// previously in main.lua.  Moving it here bypasses the UEVR Lua bridge
// entirely, eliminating the UE 5.4.4 per-tick heap-allocation leak.
//
// Responsibilities:
//   on_pre_engine_tick  — find the flashlight SpotLightComponent (every 2 s)
//                         and pin it to the left hand controller.
//   on_post_engine_tick — detect cinematic / wall-walk state (cached; full
//                         name only fetched when view-target pointer changes),
//                         then enforce the correct visibility for pawn mesh,
//                         weapon, flashlight mesh, flamethrower and harvester.
// ---------------------------------------------------------------------------
class CronosTickManager {
public:
    static CronosTickManager& get();

    void on_pre_engine_tick(API::UGameEngine* engine, float delta);
    void on_post_engine_tick(API::UGameEngine* engine, float delta);

private:
    CronosTickManager()  = default;
    ~CronosTickManager() = default;
    CronosTickManager(const CronosTickManager&)            = delete;
    CronosTickManager& operator=(const CronosTickManager&) = delete;

    // --- Visibility helpers ---
    // Call UE SetVisibility + SetHiddenInGame with no Lua bridge overhead.
    void force_visible(API::UObject* component, bool propagate = true);
    void force_hidden (API::UObject* component, bool propagate = true);

    // --- Cinematic / WallWalk detection ---
    // Caches the ViewTarget pointer; only calls get_full_name() on change.
    bool update_cinematic_state(API::UObject* pawn);

    // --- Visibility enforcement ---
    void enforce_visibility(API::UObject* pawn, bool in_cutscene);

    // --- State ---
    API::UObject* m_prev_view_target{nullptr};
    bool          m_is_cinematic{false};
    // (Spotlight management moved to CronosStereoManager)
};
