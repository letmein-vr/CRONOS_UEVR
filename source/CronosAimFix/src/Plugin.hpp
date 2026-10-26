#pragma once

#include <windows.h>

#include <memory>
#include "uevr/API.hpp"
#include "uevr/Plugin.hpp"
#include <glm/glm.hpp>
#include <utility/PointerHook.hpp>
#include "CronosTickManager.hpp"
#include "CronosStereoManager.hpp"

#define PLUGIN_LOG_ONCE(...) { \
    static bool _logged_ = false; \
    if (!_logged_) { \
        _logged_ = true; \
        API::get()->log_info(__VA_ARGS__); \
    } }

#define PLUGIN_LOG_ONCE_ERROR(...) { \
    static bool _logged_ = false; \
    if (!_logged_) { \
        _logged_ = true; \
        API::get()->log_error(__VA_ARGS__); \
    } }

// Global accessor for plugin.
class CronosPlugin;
extern std::unique_ptr<CronosPlugin> g_plugin;

class CronosPlugin : public uevr::Plugin {
public:
    CronosPlugin() = default;
    virtual ~CronosPlugin();

    void on_initialize() override;
    void on_pre_engine_tick(uevr::API::UGameEngine* engine, float delta) override;
    void on_post_engine_tick(uevr::API::UGameEngine* engine, float delta) override;
    void on_post_calculate_stereo_view_offset(
        UEVR_StereoRenderingDeviceHandle device,
        int view_index, float world_to_meters,
        UEVR_Vector3f* position, UEVR_Rotatorf* rotation, bool is_double) override;
    void on_xinput_get_state(uint32_t* retval, uint32_t user_index, XINPUT_STATE* state) override;

private:
    void hook_traceshotfromscreen_fn();
    
    void SetGunAdjustValuesFromConfig(const std::filesystem::path& ConfigFile);

    using TraceShotFromScreenFn =
        void*(*)(uevr::API::UObject*, UEVR_Vector3d*, UEVR_Vector3d*, void*, void*, int, int);

    static void* on_get_traceshotfromscreen_internal(
        TraceShotFromScreenFn original_fn,
        uevr::API::UObject* trace_component,
        UEVR_Vector3d* from_vec,
        UEVR_Vector3d* to_vec,
        void* a4,
        void* a5,
        int a6,
        int a7,
        bool is_projectile = false
    );

    // Dedicated hook redirect for base class
    static void* on_get_traceshotfromscreen_base(
        uevr::API::UObject* trace_component,
        UEVR_Vector3d* from_vec,
        UEVR_Vector3d* to_vec,
        void* a4,
        void* a5,
        int a6,
        int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, false);
    }

    // Dedicated hook redirect for shotgun subclass
    static void* on_get_traceshotfromscreen_spreadgun(
        uevr::API::UObject* trace_component,
        UEVR_Vector3d* from_vec,
        UEVR_Vector3d* to_vec,
        void* a4,
        void* a5,
        int a6,
        int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_spreadgun_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, false);
    }

    // Dedicated hook redirect for projectile subclass (mines)
    static void* on_get_traceshotfromscreen_projectile(
        uevr::API::UObject* trace_component,
        UEVR_Vector3d* from_vec,
        UEVR_Vector3d* to_vec,
        void* a4,
        void* a5,
        int a6,
        int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_projectile_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, true);
    }

    // Dedicated hook redirect for grenade subclass (CronosWeaponFireComponent)
    static void* on_get_traceshotfromscreen_grenade(
        uevr::API::UObject* trace_component,
        UEVR_Vector3d* from_vec,
        UEVR_Vector3d* to_vec,
        void* a4,
        void* a5,
        int a6,
        int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_grenade_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, true);
    }

    // Dedicated hook redirects for weapon trace subclasses that have their own vtables
    static void* on_get_traceshotfromscreen_smartgun(
        uevr::API::UObject* trace_component, UEVR_Vector3d* from_vec, UEVR_Vector3d* to_vec,
        void* a4, void* a5, int a6, int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_smartgun_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, false);
    }

    static void* on_get_traceshotfromscreen_annihilator(
        uevr::API::UObject* trace_component, UEVR_Vector3d* from_vec, UEVR_Vector3d* to_vec,
        void* a4, void* a5, int a6, int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_annihilator_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, false);
    }

    static void* on_get_traceshotfromscreen_energyemitter(
        uevr::API::UObject* trace_component, UEVR_Vector3d* from_vec, UEVR_Vector3d* to_vec,
        void* a4, void* a5, int a6, int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_energyemitter_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, false);
    }

    static void* on_get_traceshotfromscreen_flamethrower(
        uevr::API::UObject* trace_component, UEVR_Vector3d* from_vec, UEVR_Vector3d* to_vec,
        void* a4, void* a5, int a6, int a7
    ) {
        return on_get_traceshotfromscreen_internal(m_traceshotfromscreen_flamethrower_hook_fn, trace_component, from_vec, to_vec, a4, a5, a6, a7, false);
    }

    // Hook for BTWeaponModeTraceComponent (base — covers AutoGun, HeavyRifle, GravityGun, Rerouter, etc.)
    int32_t m_traceshotfromscreen_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_hook_fn{};

    // Hook for BTSpreadGunTraceComponent (shotgun subclass — needs its own vtable hook)
    int32_t m_traceshotfromscreen_spreadgun_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_spreadgun_hook_fn{};

    // Hook for BTWeaponModeProjectileTraceComponent (mines subclass)
    int32_t m_traceshotfromscreen_projectile_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_projectile_hook_fn{};

    // Hook for CronosWeaponFireComponent (grenades base)
    int32_t m_traceshotfromscreen_grenade_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_grenade_hook_fn{};

    // Hooks for weapon trace subclasses that were previously unhooked and traced
    // from the third-person camera behind the player
    int32_t m_traceshotfromscreen_smartgun_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_smartgun_hook_fn{};

    int32_t m_traceshotfromscreen_annihilator_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_annihilator_hook_fn{};

    int32_t m_traceshotfromscreen_energyemitter_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_energyemitter_hook_fn{};

    int32_t m_traceshotfromscreen_flamethrower_hook_id{};
    inline static TraceShotFromScreenFn m_traceshotfromscreen_flamethrower_hook_fn{};
};
