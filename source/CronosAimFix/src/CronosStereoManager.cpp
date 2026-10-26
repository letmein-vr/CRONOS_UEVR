#include "CronosStereoManager.hpp"
#include <string>
#include <glm/glm.hpp>
#include <glm/gtc/quaternion.hpp>

using namespace uevr;

// ==========================================================================
// UE5 double-precision quaternion layout (X, Y, Z, W order — NOT w,x,y,z)
// This matches FQuat4d / FQuat in UE5's reflection param buffers.
// ==========================================================================
struct FQuatD { double X, Y, Z, W; };

// Helpers: convert between UEVR's {w,x,y,z} and glm's {w,x,y,z} (same layout)
// and UE's FQuatD {X,Y,Z,W}
static inline glm::dquat from_ue_quat(const FQuatD& q) {
    return glm::dquat(q.W, q.X, q.Y, q.Z); // glm ctor: (w, x, y, z)
}
static inline FQuatD to_ue_quat(const glm::dquat& q) {
    return FQuatD{q.x, q.y, q.z, q.w}; // UE {X,Y,Z,W}
}

// ==========================================================================
// Kismet call param structs (all double-aligned, no explicit pack needed
// except where a bool follows doubles)
// ==========================================================================

// MakeRotFromXZ(FVector X, FVector Z) -> FRotator
struct MakeRotFromXZ_P {
    UEVR_Vector3d X;           // 24 bytes
    UEVR_Vector3d Z;           // 24 bytes
    UEVR_Rotatord ReturnValue; // 24 bytes (return at end)
};
static_assert(sizeof(MakeRotFromXZ_P) == 72, "layout mismatch");

// Conv_RotatorToQuaternion(FRotator) -> FQuat4d
struct RotToQuat_P {
    UEVR_Rotatord InRot;       // 24 bytes
    FQuatD        ReturnValue; // 32 bytes
};
static_assert(sizeof(RotToQuat_P) == 56, "layout mismatch");

// Quat_Rotator(FQuat4d) -> FRotator
struct QuatToRot_P {
    FQuatD        Q;           // 32 bytes
    UEVR_Rotatord ReturnValue; // 24 bytes
};
static_assert(sizeof(QuatToRot_P) == 56, "layout mismatch");

// K2_GetActorRotation() -> FRotator  (no inputs; return is entire buffer)
// K2_SetActorRotation(FRotator, bool) -> bool
#pragma pack(push, 1)
struct SetActorRot_P {
    double Pitch, Yaw, Roll;  // FRotator = 24 bytes
    bool   bTeleport;          // 1 byte at offset 24
    bool   ReturnValue;        // 1 byte at offset 25 (ignored)
};
#pragma pack(pop)
static_assert(sizeof(SetActorRot_P) == 26, "layout mismatch");

// SetVisibility / SetHiddenInGame
struct SetVis_P    { bool bNewVisibility;   bool bPropagateToChildren; };
struct SetHidden_P { bool bNewHiddenGame;   bool bPropagateToChildren; };

// ==========================================================================
// Singleton
// ==========================================================================
CronosStereoManager& CronosStereoManager::get() {
    static CronosStereoManager instance;
    return instance;
}

// ==========================================================================
// Kismet CDO init
// ==========================================================================
bool CronosStereoManager::init_kismet() {
    if (m_kismet) return true;
    auto* cls = API::get()->find_uobject<API::UClass>(
        L"Class /Script/Engine.KismetMathLibrary");
    if (!cls) return false;
    m_kismet = cls->get_class_default_object();
    return m_kismet != nullptr;
}

// ==========================================================================
// Spotlight / flashlight cache
// ==========================================================================
API::UObject* CronosStereoManager::search_spotlight() {
    static auto* cls = API::get()->find_uobject<API::UClass>(
        L"Class /Script/Engine.SpotLightComponent");
    if (!cls) return nullptr;
    for (auto* obj : API::UObjectHook::get_objects_by_class(cls, false)) {
        if (!obj) continue;
        auto name = obj->get_full_name();
        if (name.find(L"Flashlight_BP_C") != std::wstring::npos &&
            name.compare(name.size() - 6, 6, L".Light") == 0 &&
            name.find(L"Default__") == std::wstring::npos)
            return obj;
    }
    return nullptr;
}

API::UObject* CronosStereoManager::search_flash_shaft() {
    static auto* cls = API::get()->find_uobject<API::UClass>(
        L"Class /Script/Engine.StaticMeshComponent");
    if (!cls) return nullptr;
    for (auto* obj : API::UObjectHook::get_objects_by_class(cls, false)) {
        if (!obj) continue;
        auto name = obj->get_full_name();
        if (name.find(L"CronosCharacterPlay_BP_C") != std::wstring::npos &&
            name.compare(name.size() - 14, 14, L".FlashlightShaft") != std::wstring::npos &&
            name.find(L"Default__") == std::wstring::npos)
            return obj;
    }
    return nullptr;
}

void CronosStereoManager::update_spotlight_cache() {
    // Validate existing
    if (m_spotlight && !API::UObjectHook::exists(m_spotlight)) {
        m_spotlight = nullptr;
        m_search_timer = SEARCH_INTERVAL; // trigger re-search
    }
    if (m_flash_shaft && !API::UObjectHook::exists(m_flash_shaft)) {
        m_flash_shaft = nullptr;
    }

    // Search on interval
    if (m_search_timer >= SEARCH_INTERVAL) {
        m_search_timer = 0.0f;
        if (!m_spotlight) {
            m_spotlight = search_spotlight();
            if (m_spotlight)
                API::get()->log_info("Cronos.dll: [Stereo] Found spotlight");
        }
        if (!m_flash_shaft) {
            m_flash_shaft = search_flash_shaft();
        }
    }

    // Pin spotlight to left hand every tick via UObjectHook
    if (m_spotlight) {
        auto* state = API::UObjectHook::get_or_add_motion_controller_state(m_spotlight);
        if (state) {
            state->set_hand(0);         // 0 = left hand
            state->set_permanent(true);
        }
    }
}

void CronosStereoManager::enforce_flashlight_visibility() {
    auto vis = [&](API::UObject* comp) {
        if (!comp) return;
        SetVis_P    vp{m_flashlight_on, true};
        SetHidden_P hp{!m_flashlight_on, true};
        comp->call_function(L"SetVisibility",   &vp);
        comp->call_function(L"SetHiddenInGame", &hp);
    };
    vis(m_spotlight);
    vis(m_flash_shaft);
}

// ==========================================================================
// Weapon cache
// ==========================================================================
void CronosStereoManager::clear_weapon_cache() {
    m_weapon_actor = nullptr;
    m_weapon_mesh  = nullptr;
    m_last_gun_actor = nullptr;
}

bool CronosStereoManager::update_weapon_cache() {
    auto* pawn = API::get()->get_local_pawn(0);
    if (!pawn) { clear_weapon_cache(); return false; }

    auto* wpc_ptr = pawn->get_property_data<API::UObject*>(L"WeaponPlayerComponent");
    if (!wpc_ptr || !*wpc_ptr) { clear_weapon_cache(); return false; }
    auto* wpc = *wpc_ptr;

    auto* gun_ptr = wpc->get_property_data<API::UObject*>(L"MultiModeGun");
    if (!gun_ptr || !*gun_ptr) { clear_weapon_cache(); return false; }
    auto* gun = *gun_ptr;

    if (!API::UObjectHook::exists(gun)) { clear_weapon_cache(); return false; }

    if (gun != m_last_gun_actor) {
        m_last_gun_actor  = gun;
        m_weapon_actor    = gun;
        auto* mesh_ptr    = gun->get_property_data<API::UObject*>(L"SkeletalMesh");
        if (!mesh_ptr || !*mesh_ptr)
            mesh_ptr = gun->get_property_data<API::UObject*>(L"Mesh");
        m_weapon_mesh = (mesh_ptr && *mesh_ptr) ? *mesh_ptr : nullptr;

        // Notify Lua so it can re-attach the right PMC and reload weapon profile
        API::get()->dispatch_lua_event("weapon_changed", "");
        API::get()->log_info("Cronos.dll: [Stereo] Weapon changed; event dispatched");
    }

    return m_weapon_actor != nullptr;
}

// ==========================================================================
// Proximity helpers
// ==========================================================================
bool CronosStereoManager::left_hand_near_right_hand() const {
    auto ri = API::VR::get_right_controller_index();
    auto li = API::VR::get_left_controller_index();
    auto rg = API::VR::get_grip_pose(ri);
    auto lg = API::VR::get_grip_pose(li);
    float dx = lg.position.x - rg.position.x;
    float dy = lg.position.y - rg.position.y;
    float dz = lg.position.z - rg.position.z;
    return (dx*dx + dy*dy + dz*dz) < GRIP_THRESHOLD_SQ;
}

void CronosStereoManager::update_proximity_flags() {
    auto ri = API::VR::get_right_controller_index();
    auto li = API::VR::get_left_controller_index();
    auto rg = API::VR::get_grip_pose(ri);
    auto lg = API::VR::get_grip_pose(li);
    float dx = lg.position.x - rg.position.x;
    float dy = lg.position.y - rg.position.y;
    float dz = lg.position.z - rg.position.z;
    float dist_sq = dx*dx + dy*dy + dz*dz;

    m_flash_zone_overlapping = (dist_sq < FLASH_ZONE_THRESH_SQ);

    // Update two-handing state
    bool hand_is_close   = (dist_sq < GRIP_THRESHOLD_SQ);
    bool was_two_handing = m_is_two_handing;
    m_is_two_handing = m_left_grip_down && hand_is_close && m_weapon_actor;


    if (m_is_two_handing != was_two_handing) {
        const char* ev = m_is_two_handing ? "grip_start" : "grip_stop";
        API::get()->dispatch_lua_event(ev, "");
    }
}

// ==========================================================================
// Two-handed rotation
// Uses:
//   1 × MakeRotFromXZ (Kismet)       → target rotation as FRotator
//   2 × Conv_RotatorToQuaternion     → quaternions (target + current)
//   1 × K2_GetActorRotation          → current weapon rotation
//   glm quaternion arithmetic        → delta + new quat  (zero UE calls)
//   1 × Quat_Rotator (Kismet)        → back to FRotator
//   1 × K2_SetActorRotation          → apply result
// Total: 6 UE/Kismet calls (vs. 15 via Lua bridge)
// ==========================================================================
void CronosStereoManager::apply_two_handed_rotation() {
    if (!m_weapon_actor || !init_kismet()) return;

    auto ri = API::VR::get_right_controller_index();
    auto li = API::VR::get_left_controller_index();
    auto rg = API::VR::get_grip_pose(ri);
    auto lg = API::VR::get_grip_pose(li);

    auto  standing = API::VR::get_standing_origin();
    float wtm      = m_world_to_meters;

    // Grip positions in UE world space (cm)
    glm::dvec3 right_ue = {
        standing.x + (double)rg.position.x * wtm,
        standing.y + (double)rg.position.y * wtm,
        standing.z + (double)rg.position.z * wtm
    };
    glm::dvec3 left_ue = {
        standing.x + (double)lg.position.x * wtm,
        standing.y + (double)lg.position.y * wtm,
        standing.z + (double)lg.position.z * wtm
    };

    glm::dvec3 dir = left_ue - right_ue;
    double len = glm::length(dir);
    if (len < 1.0) return; // hands too close, skip
    dir /= len;

    // --- Step 1: Kismet MakeRotFromXZ(dir, global_up) → target_rot ---
    MakeRotFromXZ_P mkp{};
    mkp.X = {dir.x, dir.y, dir.z};
    mkp.Z = {0.0, 0.0, 1.0}; // global UE up (Z axis)
    m_kismet->call_function(L"MakeRotFromXZ", &mkp);

    // --- Step 2: Conv_RotatorToQuaternion(target_rot) → target_q ---
    RotToQuat_P rqp1{};
    rqp1.InRot = mkp.ReturnValue;
    m_kismet->call_function(L"Conv_RotatorToQuaternion", &rqp1);
    glm::dquat target_q = from_ue_quat(rqp1.ReturnValue);

    // --- Step 3: Dominant hand quaternion from VR API (zero UE calls) ---
    // UEVR_Quaternionf: {float w, x, y, z} → convert to glm {w, x, y, z}
    glm::dquat dominant_q(
        rg.rotation.w, rg.rotation.x, rg.rotation.y, rg.rotation.z);

    // --- Step 4: delta_q = Inverse(dominant_q * Inverse(target_q))  ---
    glm::dquat delta_q = glm::inverse(dominant_q * glm::inverse(target_q));

    // --- Step 5: K2_GetActorRotation → current weapon rotation ---
    UEVR_Rotatord current_rot{};
    m_weapon_actor->call_function(L"K2_GetActorRotation", &current_rot);

    // --- Step 6: Conv_RotatorToQuaternion(current_rot) → current_q ---
    RotToQuat_P rqp2{};
    rqp2.InRot = current_rot;
    m_kismet->call_function(L"Conv_RotatorToQuaternion", &rqp2);
    glm::dquat current_q = from_ue_quat(rqp2.ReturnValue);

    // --- Step 7: new_q = delta_q * current_q  (pure glm, 0 UE calls) ---
    glm::dquat new_q = glm::normalize(delta_q * current_q);

    // --- Step 8: Quat_Rotator(new_q) → final_rot ---
    QuatToRot_P qrp{};
    qrp.Q = to_ue_quat(new_q);
    m_kismet->call_function(L"Quat_Rotator", &qrp);

    // --- Step 9: K2_SetActorRotation(final_rot, bTeleport=false) ---
    SetActorRot_P srp{};
    srp.Pitch    = qrp.ReturnValue.pitch;
    srp.Yaw      = qrp.ReturnValue.yaw;
    srp.Roll     = qrp.ReturnValue.roll;
    srp.bTeleport   = false;
    srp.ReturnValue = false;
    m_weapon_actor->call_function(L"K2_SetActorRotation", &srp);
}

// ==========================================================================
// on_pre_engine_tick (called by CronosTickManager each game tick)
// ==========================================================================
void CronosStereoManager::on_pre_engine_tick(float delta) {
    m_stereo_ran_this_tick = false; // reset once-per-tick gate
    m_search_timer += delta;
    update_spotlight_cache();
}

// ==========================================================================
// on_post_calculate_stereo_view_offset
// ==========================================================================
void CronosStereoManager::on_post_calculate_stereo_view_offset(
    UEVR_StereoRenderingDeviceHandle device,
    int view_index, float world_to_meters,
    UEVR_Vector3f* position, UEVR_Rotatorf* rotation, bool is_double)
{
    if (!API::VR::is_hmd_active()) return;
    m_world_to_meters = world_to_meters;

    if (view_index != 0) {
        // Native Stereo second eye: re-apply weapon rotation so it isn't
        // overridden by UEVR's mesh-relative-position update.
        if (m_is_two_handing) apply_two_handed_rotation();
        return;
    }

    // ── Gate: run body only once per game tick ─────────────────────────────
    if (m_stereo_ran_this_tick) return;
    m_stereo_ran_this_tick = true;

    // ── Update weapon cache ────────────────────────────────────────────────
    update_weapon_cache();

    // ── Update proximity flags (grip zone + flash zone) ───────────────────
    update_proximity_flags();

    // ── Flashlight visibility ─────────────────────────────────────────────
    enforce_flashlight_visibility();

    // ── Two-handed aiming ─────────────────────────────────────────────────
    if (m_is_two_handing) apply_two_handed_rotation();
}

// ==========================================================================
// on_xinput_get_state
// ==========================================================================
void CronosStereoManager::on_xinput_get_state(
    uint32_t* retval, uint32_t user_index, XINPUT_STATE* state)
{
    if (user_index != 0 || !state) return;

    constexpr WORD RB = XINPUT_GAMEPAD_RIGHT_SHOULDER; // 0x0200
    constexpr WORD LB = 0x0100;                         // left shoulder (grip)

    bool right_grip_now = (state->Gamepad.wButtons & RB) != 0;
    bool left_grip_now  = (state->Gamepad.wButtons & LB) != 0;

    // ── Flashlight toggle ──────────────────────────────────────────────────
    // Suppress right grip from reaching the game and toggle on rising edge
    // when right hand is in the flashlight zone (near left hand).
    if (right_grip_now && m_flash_zone_overlapping) {
        state->Gamepad.wButtons &= ~RB; // suppress
        if (!m_right_grip_was_down) {
            m_flashlight_on = !m_flashlight_on;
            API::get()->log_info(m_flashlight_on
                ? "Cronos.dll: [Stereo] Flashlight ON"
                : "Cronos.dll: [Stereo] Flashlight OFF");
        }
    }
    m_right_grip_was_down = right_grip_now;

    // ── Left grip tracking ─────────────────────────────────────────────────
    m_left_grip_down = left_grip_now;

    // Suppress left grip from reaching the game when hand is near the weapon,
    // so the game's melee/parry actions don't fire unintentionally while
    // the player is physically gripping the foregrip.
    if (left_grip_now && m_is_two_handing) {
        state->Gamepad.wButtons &= ~LB;
    }
}
