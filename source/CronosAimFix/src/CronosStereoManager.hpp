#pragma once
#include "uevr/API.hpp"
#include <windows.h>
#include <Xinput.h>

using namespace uevr;

// ---------------------------------------------------------------------------
// CronosStereoManager
//
// Owns ALL stereo-rate and XInput logic that was previously in the Lua
// on_post_calculate_stereo_view_offset and on_xinput_get_state callbacks.
// Running these in C++ via direct ProcessEvent bypasses the UEVR Lua bridge
// entirely, eliminating the UE 5.4.4 per-callback-dispatch memory leak.
//
// Responsibilities:
//   on_post_calculate_stereo_view_offset:
//     - Updates weapon actor/mesh cache
//     - Enforces flashlight spotlight visibility (on/off toggle state)
//     - Pins spotlight to left controller via UObjectHook
//     - Applies two-handed aiming rotation using VR API + glm + 3 Kismet calls
//   on_xinput_get_state:
//     - Tracks left grip state
//     - Suppresses left grip when hand near weapon (for game-side input)
//     - Detects right-grip flashlight toggle gesture (proximity check)
//   on_pre_engine_tick (called by CronosTickManager):
//     - Resets the once-per-tick gate
//     - Runs periodic spotlight search
// ---------------------------------------------------------------------------
class CronosStereoManager {
public:
    static CronosStereoManager& get();

    void on_post_calculate_stereo_view_offset(
        UEVR_StereoRenderingDeviceHandle device,
        int view_index, float world_to_meters,
        UEVR_Vector3f* position, UEVR_Rotatorf* rotation, bool is_double);

    void on_xinput_get_state(uint32_t* retval, uint32_t user_index, XINPUT_STATE* state);

    // Called by CronosTickManager::on_pre_engine_tick
    void on_pre_engine_tick(float delta);

    // Accessors used by CronosTickManager to skip re-doing visibility work
    bool flashlight_on() const { return m_flashlight_on; }

private:
    CronosStereoManager()  = default;
    ~CronosStereoManager() = default;
    CronosStereoManager(const CronosStereoManager&)            = delete;
    CronosStereoManager& operator=(const CronosStereoManager&) = delete;

    // ── Once-per-tick gate ─────────────────────────────────────────────────
    bool m_stereo_ran_this_tick{false};
    float m_world_to_meters{100.0f};

    // ── Spotlight (ownership transferred from CronosTickManager) ───────────
    API::UObject* m_spotlight{nullptr};
    API::UObject* m_flash_shaft{nullptr};
    float         m_search_timer{3.0f}; // >interval → immediate first search
    static constexpr float SEARCH_INTERVAL = 2.0f;

    void update_spotlight_cache();
    API::UObject* search_spotlight();
    API::UObject* search_flash_shaft();
    void enforce_flashlight_visibility(); // called per-tick from stereo body

    // ── Weapon actor cache ─────────────────────────────────────────────────
    API::UObject* m_weapon_actor{nullptr};
    API::UObject* m_weapon_mesh{nullptr};
    API::UObject* m_last_gun_actor{nullptr};

    bool update_weapon_cache();
    void clear_weapon_cache();

    // ── Two-handed aiming ──────────────────────────────────────────────────
    bool m_is_two_handing{false};
    bool m_prev_is_two_handing{false};

    bool left_hand_near_right_hand() const;
    void apply_two_handed_rotation();

    // ── Kismet CDO (cached for rotation math) ─────────────────────────────
    API::UObject* m_kismet{nullptr};
    bool init_kismet();

    // ── XInput state ──────────────────────────────────────────────────────
    bool m_left_grip_down{false};
    bool m_right_grip_was_down{false};
    bool m_flashlight_on{true};
    bool m_flash_zone_overlapping{false};

    // Thresholds (in VR tracking space metres)
    static constexpr float GRIP_THRESHOLD_SQ    = 0.40f * 0.40f;  // 40 cm
    static constexpr float FLASH_ZONE_THRESH_SQ = 0.30f * 0.30f;  // 30 cm

    void update_proximity_flags();
};
