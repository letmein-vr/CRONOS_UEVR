#include "CronosTickManager.hpp"
#include <string>

using namespace uevr;

// ==========================================================================
// Singleton
// ==========================================================================
CronosTickManager& CronosTickManager::get() {
    static CronosTickManager instance;
    return instance;
}

// ==========================================================================
// Visibility helpers
// ==========================================================================
// Calls go directly to UE's UObject::ProcessEvent — no Lua bridge, no leak.

void CronosTickManager::force_visible(API::UObject* component, bool propagate) {
    if (!component) return;
    struct SetVisParams    { bool bNewVisibility;     bool bPropagateToChildren; };
    struct SetHiddenParams { bool bNewHiddenGame;     bool bPropagateToChildren; };
    SetVisParams    vis_p   {true,  propagate};
    SetHiddenParams hidden_p{false, propagate};
    component->call_function(L"SetVisibility",   &vis_p);
    component->call_function(L"SetHiddenInGame", &hidden_p);
}

void CronosTickManager::force_hidden(API::UObject* component, bool propagate) {
    if (!component) return;
    struct SetVisParams    { bool bNewVisibility;     bool bPropagateToChildren; };
    struct SetHiddenParams { bool bNewHiddenGame;     bool bPropagateToChildren; };
    SetVisParams    vis_p   {false, propagate};
    SetHiddenParams hidden_p{true,  propagate};
    component->call_function(L"SetVisibility",   &vis_p);
    component->call_function(L"SetHiddenInGame", &hidden_p);
}

// ==========================================================================
// Cinematic / WallWalk detection
// ==========================================================================
// get_full_name() → returns std::wstring on the C++ heap, NOT UE's heap.
// No UE memory is leaked even on repeated calls.  We cache m_prev_view_target
// and only call it when the pointer changes (usually never during normal play).

bool CronosTickManager::update_cinematic_state(API::UObject* pawn) {
    auto* pc = API::get()->get_player_controller(0);
    if (!pc) return m_is_cinematic;

    // GetViewTarget() has no input params; return value is at offset 0.
    API::UObject* view_target{nullptr};
    pc->call_function(L"GetViewTarget", &view_target);

    if (view_target != m_prev_view_target) {
        m_prev_view_target = view_target;
        if (view_target) {
            // std::wstring is C++ heap — no UE FString leak
            auto name = view_target->get_full_name();
            m_is_cinematic = (name.find(L"CineCamera") != std::wstring::npos);
        } else {
            m_is_cinematic = false;
        }
    }

    // WallWalk active → treat same as cinematic (pawn body must be visible)
    if (!m_is_cinematic && pawn) {
        auto* ww = pawn->get_property<API::UObject*>(L"WallWalkComponent");
        if (ww) {
            // Blueprint bool variable; "isEnabled?" is the exact BP variable name
            m_is_cinematic = ww->get_property<bool>(L"isEnabled?");
        }
    }

    return m_is_cinematic;
}

// ==========================================================================
// Visibility enforcement
// ==========================================================================
// Mirrors exactly what main.lua's on_post_engine_tick did, now in C++.

void CronosTickManager::enforce_visibility(API::UObject* pawn, bool in_cutscene) {
    if (!pawn) return;

    // 1. Pawn body mesh: always hidden in VR; visible only during cutscenes
    auto* pawn_mesh = pawn->get_property<API::UObject*>(L"Mesh");
    if (pawn_mesh) {
        if (in_cutscene) {
            force_visible(pawn_mesh, true);
        } else {
            force_hidden(pawn_mesh, true);
        }
    }

    // During cutscenes, weapons use their native state — nothing else to do
    if (in_cutscene) return;

    // 2. Weapon gun actor + skeletal mesh
    auto* wpc = pawn->get_property<API::UObject*>(L"WeaponPlayerComponent");
    if (wpc) {
        auto* gun = wpc->get_property<API::UObject*>(L"MultiModeGun");
        if (gun) {
            // Un-hide the actor itself if the game hid it (e.g. after interactions)
            struct ActorHiddenParams { bool bNewHidden; };
            ActorHiddenParams ahp{false};
            gun->call_function(L"SetActorHiddenInGame", &ahp);

            // Force mesh component visible
            auto* mesh = gun->get_property<API::UObject*>(L"SkeletalMesh");
            if (!mesh) mesh = gun->get_property<API::UObject*>(L"Mesh");
            if (mesh) force_visible(mesh, true);
        }
    }

    // 3. Flashlight prop mesh (the hand-held torch body, not the SpotLight)
    auto* flash = pawn->get_property<API::UObject*>(L"Flashlight_Mesh");
    if (flash) force_visible(flash, true);

    // 4. Flamethrower static mesh
    auto* ft = pawn->get_property<API::UObject*>(L"FlamethrowerSM");
    if (ft) force_visible(ft, true);

    // 5. Harvester skeletal mesh
    auto* hv = pawn->get_property<API::UObject*>(L"HarvesterSK");
    if (hv) force_visible(hv, true);
}

// ==========================================================================
// Engine tick callbacks (called by CronosPlugin virtuals)
// ==========================================================================

void CronosTickManager::on_pre_engine_tick(API::UGameEngine* engine, float delta) {
    // Spotlight management moved to CronosStereoManager (stereo-rate, not tick-rate).
}

void CronosTickManager::on_post_engine_tick(API::UGameEngine* engine, float delta) {
    auto* pawn = API::get()->get_local_pawn(0);
    if (!pawn) {
        m_prev_view_target = nullptr;
        m_is_cinematic     = false;
        return;
    }

    bool in_cutscene = update_cinematic_state(pawn);
    enforce_visibility(pawn, in_cutscene);
}
