#include <iostream>
#include <fstream>
#include <string>
#include <filesystem>
#include <vector>

#include <utility/Scan.hpp>
#include <utility/Module.hpp>
#include <utility/String.hpp>

#include "Plugin.hpp"

using namespace uevr;

#define MAX_DEBUG_MESSAGE_SIZE 2048
bool g_DebugEnabled = false;
double g_AdjustValueV = 0;
double g_AdjustValueH = 0;

static void DebugPrint(const char* Format, ...)
{
  char FormattedMessage[MAX_DEBUG_MESSAGE_SIZE];    
  va_list ArgPtr = NULL;  
  
  if(g_DebugEnabled)    
  {        
    /* Generate the formatted debug message. */        
    va_start(ArgPtr, Format);        
    vsprintf(FormattedMessage, Format, ArgPtr);        
    va_end(ArgPtr); 
    
    printf(FormattedMessage);
  }
}

std::unique_ptr<CronosPlugin> g_plugin = std::make_unique<CronosPlugin>();

CronosPlugin::~CronosPlugin() {
}

void CronosPlugin::on_initialize() {
    PLUGIN_LOG_ONCE("CronosPlugin::on_initialize()");

    // Get the persistent directory
    std::filesystem::path config_file = API::get()->get_persistent_dir() / "plugins" / "Cronos.txt";
    std::filesystem::path debug_file = API::get()->get_persistent_dir() / "debug";
    
    SetGunAdjustValuesFromConfig(config_file);
    API::get()->log_info("Cronos.dll: using config file value for gun adjust v:%f h:%f", g_AdjustValueV, g_AdjustValueH);

    // Check if the file exists
    g_DebugEnabled = std::filesystem::exists(debug_file);
    
    if (g_DebugEnabled) {
        AllocConsole();
        freopen("CONOUT$", "w", stdout);
        DebugPrint("Hello console!");
    }

    hook_traceshotfromscreen_fn();
}

// The tick/stereo managers duplicate what the Lua profile already does
// (scripts/hands.lua, scripts/two_handed_integration.lua): spotlight pinning,
// two-handed rotation, flashlight toggle, grip suppression and visibility
// forcing. Running both makes them fight, so they are disabled here and the
// plugin is aim-fix only.
void CronosPlugin::on_pre_engine_tick(uevr::API::UGameEngine* engine, float delta) {
}

void CronosPlugin::on_post_engine_tick(uevr::API::UGameEngine* engine, float delta) {
}

void CronosPlugin::on_post_calculate_stereo_view_offset(
    UEVR_StereoRenderingDeviceHandle device,
    int view_index, float world_to_meters,
    UEVR_Vector3f* position, UEVR_Rotatorf* rotation, bool is_double)
{
}

void CronosPlugin::on_xinput_get_state(
    uint32_t* retval, uint32_t user_index, XINPUT_STATE* state)
{
}

// Find virtual function and hook it.
// Scans the Blueprint thunk to find the real native vtable slot, then registers an inline hook.
int32_t hook_vtable_fn(std::wstring_view class_name, std::wstring_view fn_name, void* destination, void** original) {
    auto obj = (API::UClass*)API::get()->find_uobject(class_name);

    if (obj == nullptr) {
        PLUGIN_LOG_ONCE_ERROR("Failed to find %ls", class_name.data());
        return -1;
    }

    auto fn = obj->find_function(fn_name);

    if (fn == nullptr) {
        PLUGIN_LOG_ONCE_ERROR("Failed to find %ls", fn_name.data());
        return -1;
    }

    auto thunk = fn->get_native_function();

    if (thunk == nullptr) {
        PLUGIN_LOG_ONCE_ERROR("Failed to get thunk wrapper");
        return -1;
    }

    PLUGIN_LOG_ONCE("%ls thunk: 0x%p", fn_name.data(), thunk);

    auto default_object = obj->get_class_default_object();

    if (default_object == nullptr) {
        PLUGIN_LOG_ONCE_ERROR("Failed to get default object");
        return -1;
    }

    auto insn = utility::scan_disasm((uintptr_t)thunk, 0x1000, "48 8B B0 ? ? ? ?");

    if (!insn) {
        PLUGIN_LOG_ONCE_ERROR("Failed to find the instruction");
        return -1;
    }

    auto offset = *(int32_t*)(*insn + 3);

    auto vtable = *(uintptr_t**)default_object;
    auto real_fn = vtable[offset / sizeof(void*)];

    PLUGIN_LOG_ONCE("Real %ls: 0x%p (index: %d, offset 0x%X)", fn_name.data(), real_fn, offset / sizeof(void*), offset);

    return API::get()->param()->functions->register_inline_hook((void*)real_fn, (void*)destination, original);
}

// Hook TraceShotFromScreen on both the base class AND the shotgun subclass.
//
// Why two hooks?
// BTSpreadGunTraceComponent (shotgun) is a subclass of BTWeaponModeTraceComponent.
// Even though it inherits TraceShotFromScreen without overriding it, the subclass has
// its own separate vtable in memory. hook_vtable_fn reads the vtable from the class
// default object, so hooking the base class only patches calls dispatched through
// the base vtable. Calls dispatched through the subclass vtable remain unhooked.
// Registering an inline hook against the same underlying function a second time is
// safe — kananlib/UEVR chains the hooks correctly.
void CronosPlugin::hook_traceshotfromscreen_fn() {

    // Base class — covers: AutoGun, HeavyRifle, GravityGun, Rerouter, and any other
    //              weapon whose container uses BTWeaponModeTraceComponent directly.
    m_traceshotfromscreen_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTWeaponModeTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_base,
        (void**)&m_traceshotfromscreen_hook_fn
    );

    // Shotgun subclass — BTSpreadGunTraceComponent (SpreadGun / DoubleBarrell).
    // Hooks the same destination function; stores its own original pointer in case
    // the vtable slot resolves to a different compiled address.
    m_traceshotfromscreen_spreadgun_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTSpreadGunTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_spreadgun,
        (void**)&m_traceshotfromscreen_spreadgun_hook_fn
    );

    if (m_traceshotfromscreen_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTWeaponModeTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_hook_id);
    }
    if (m_traceshotfromscreen_spreadgun_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTSpreadGunTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_spreadgun_hook_id);
    }
    
    m_traceshotfromscreen_projectile_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTWeaponModeProjectileTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_projectile,
        (void**)&m_traceshotfromscreen_projectile_hook_fn
    );
    if (m_traceshotfromscreen_projectile_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTWeaponModeProjectileTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_projectile_hook_id);
    }

    m_traceshotfromscreen_grenade_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.CronosWeaponFireComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_grenade,
        (void**)&m_traceshotfromscreen_grenade_hook_fn
    );
    if (m_traceshotfromscreen_grenade_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked CronosWeaponFireComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_grenade_hook_id);
    }

    // Trace subclasses with their own vtables. Unhooked, these traced from the
    // third-person camera behind the player instead of from the barrel.
    m_traceshotfromscreen_smartgun_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTSmartGunTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_smartgun,
        (void**)&m_traceshotfromscreen_smartgun_hook_fn
    );
    if (m_traceshotfromscreen_smartgun_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTSmartGunTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_smartgun_hook_id);
    }

    m_traceshotfromscreen_annihilator_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTAnnihilatorTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_annihilator,
        (void**)&m_traceshotfromscreen_annihilator_hook_fn
    );
    if (m_traceshotfromscreen_annihilator_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTAnnihilatorTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_annihilator_hook_id);
    }

    m_traceshotfromscreen_energyemitter_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTEnergyEmitterTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_energyemitter,
        (void**)&m_traceshotfromscreen_energyemitter_hook_fn
    );
    if (m_traceshotfromscreen_energyemitter_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTEnergyEmitterTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_energyemitter_hook_id);
    }

    m_traceshotfromscreen_flamethrower_hook_id = hook_vtable_fn(
        L"Class /Script/Cronos.BTFlamethrowerTraceComponent",
        L"TraceShotFromScreen",
        on_get_traceshotfromscreen_flamethrower,
        (void**)&m_traceshotfromscreen_flamethrower_hook_fn
    );
    if (m_traceshotfromscreen_flamethrower_hook_id >= 0) {
        API::get()->log_info("Cronos.dll: hooked BTFlamethrowerTraceComponent::TraceShotFromScreen (id=%d)", m_traceshotfromscreen_flamethrower_hook_id);
    }
}

// Finds the in-world MotionControllerComponent UEVR drives for the right hand
// (the Lua profile creates it; MotionSource == "Right"). Cached until destroyed.
static API::UObject* find_right_controller_component() {
    static API::UObject* cached = nullptr;
    if (cached != nullptr && API::UObjectHook::exists(cached)) {
        return cached;
    }
    cached = nullptr;

    static auto controller_class = API::get()->find_uobject<API::UClass>(L"Class /Script/HeadMountedDisplay.MotionControllerComponent");
    if (controller_class == nullptr) {
        return nullptr;
    }

    for (auto obj : API::UObjectHook::get_objects_by_class(controller_class, false)) {
        if (obj == nullptr || obj->get_full_name().find(L"Default__") != std::wstring::npos) {
            continue;
        }
        const auto source = obj->get_property_data<API::FName>(L"MotionSource");
        if (source != nullptr && source->to_string() == L"Right") {
            cached = obj;
            break;
        }
    }
    return cached;
}

// Internal weapon trace replacement.
// Intercepts TraceShotFromScreen before the game processes it.
// Replaces the from/to ray vectors with barrel-aligned world-space values.
void* CronosPlugin::on_get_traceshotfromscreen_internal(TraceShotFromScreenFn original_fn, uevr::API::UObject* trace_component, UEVR_Vector3d* from_vec, UEVR_Vector3d* to_vec, void* a4, void* a5, int a6, int a7, bool is_projectile) {
    
    auto weapon_container = trace_component->get_property<API::UObject*>(L"OwnerContainer");
    
    API::UObject* weapon = nullptr;
    if (weapon_container != nullptr) {
        weapon = weapon_container->get_property<API::UObject*>(L"OwnerWeapon");
    } else {
        // Fallback for classes like CronosWeaponFireComponent that don't have OwnerContainer
        trace_component->call_function(L"GetOwner", &weapon);
    }
    
    API::UObject* muzzlepoint_component = nullptr;
    if (weapon != nullptr) {
        muzzlepoint_component = weapon->get_property<API::UObject*>(L"MuzzlePoint");
        
        // Throwables like Grenades/Mines don't have a MuzzlePoint, they are just held in the hand.
        // Fall back to RootComponent!
        if (muzzlepoint_component == nullptr) {
            muzzlepoint_component = weapon->get_property<API::UObject*>(L"RootComponent");
        }
        
        const auto weapon_name = weapon->get_full_name();
        DebugPrint("Current Weapon: %ls\n", weapon_name.c_str());
    }

    if (muzzlepoint_component != nullptr) {
        PLUGIN_LOG_ONCE("MuzzlePoint: 0x%p", muzzlepoint_component);

        UEVR_Vector3d location_params;
        muzzlepoint_component->call_function(L"K2_GetComponentLocation", &location_params);

        DebugPrint("Current to: %f, %f, %f\n", to_vec->x, to_vec->y, to_vec->z);

        auto root_component = weapon->get_property<API::UObject*>(L"RootComponent");

        // ── Throwable path: throw from the right controller, along where it points ──
        // Uses the in-world right MotionControllerComponent that UEVR drives, so the
        // pose is already in game world space. (The raw OpenXR aim pose is in
        // tracking space and can't be added to the standing origin unrotated.)
        auto right_controller = is_projectile ? find_right_controller_component() : nullptr;
        if (right_controller != nullptr) {
            UEVR_Vector3d controller_location{};
            UEVR_Vector3d controller_forward{};
            right_controller->call_function(L"K2_GetComponentLocation", &controller_location);
            right_controller->call_function(L"GetForwardVector", &controller_forward);

            from_vec->x = controller_location.x;
            from_vec->y = controller_location.y;
            from_vec->z = controller_location.z;

            const double scaler = 8192.0;
            to_vec->x = from_vec->x + (controller_forward.x * scaler);
            to_vec->y = from_vec->y + (controller_forward.y * scaler) - g_AdjustValueH;
            to_vec->z = from_vec->z + (controller_forward.z * scaler) - g_AdjustValueV;

            DebugPrint("[Projectile] Controller From: %f, %f, %f -> To: %f, %f, %f\n",
                from_vec->x, from_vec->y, from_vec->z,
                to_vec->x,   to_vec->y,   to_vec->z);
        }
        // ── Normal weapon path: use the weapon mesh forward vector ──
        else if (root_component != nullptr) {
            PLUGIN_LOG_ONCE("Root: 0x%p", root_component);
            
            struct RotateAngleAxis
            {
                UEVR_Vector3d       InVect;
                float               AngleDeg;
                UEVR_Vector3d       Axis;
                UEVR_Vector3d       Result;
            } rotateaxis;

            RotateAngleAxis rotate_params;
            static auto kismet_math_library_c = API::get()->find_uobject<API::UClass>(L"Class /Script/Engine.KismetMathLibrary");
            static auto kismet_math_library = kismet_math_library_c->get_class_default_object();

            UEVR_Vector3d forward_params;
            root_component->call_function(L"GetForwardVector", &forward_params);

            rotate_params.InVect = forward_params;
            rotate_params.AngleDeg = 90.0f;
            root_component->call_function(L"GetUpVector", &rotate_params.Axis);
            kismet_math_library->call_function(L"RotateAngleAxis", &rotate_params);

            forward_params = rotate_params.Result;

            double scaler = 8192.0;           

            from_vec->x = location_params.x;
            from_vec->y = location_params.y;
            from_vec->z = location_params.z;

            DebugPrint("New From: %f, %f, %f", from_vec->x, from_vec->y, from_vec->z);

            to_vec->x = location_params.x + (forward_params.x * scaler);
            to_vec->y = location_params.y + (forward_params.y * scaler) - g_AdjustValueH; // left/right is Y
            to_vec->z = location_params.z + (forward_params.z * scaler) - g_AdjustValueV; // up/down is Z
            
            DebugPrint("New To: %f, %f, %f", to_vec->x, to_vec->y, to_vec->z);
        }
    }

    // Call the specific original function pointer that was passed to us from the hook redirect.
    if (original_fn == nullptr) {
        PLUGIN_LOG_ONCE_ERROR("Fatal: original_fn is null!");
        return nullptr;
    }

    // Make sure the player is in ActorsToIgnore (a5, TArray<AActor*>).
    // The game only excludes the player when the gun is attached under the pawn.
    // In VR the gun hangs off the motion controller, and some traces start behind
    // the shot origin (shotgun pellets start 200 cm back), so without this the
    // shot hits the player's own capsule.
    // The game resizes/frees this array itself, so it must stay game-owned: append
    // in place and grow it with the game's FMalloc, never swap in our own buffer.
    struct TArrayRaw { API::UObject** data; int32_t num; int32_t max; };

    auto pawn = API::get()->get_local_pawn(0);
    if (pawn != nullptr && a5 != nullptr) {
        const auto arr = (TArrayRaw*)a5;
        bool has_pawn = false;
        for (int32_t i = 0; i < arr->num; ++i) {
            if (arr->data[i] == pawn) {
                has_pawn = true;
                break;
            }
        }

        if (!has_pawn) {
            if (arr->num >= arr->max) {
                const int32_t new_max = arr->max > 0 ? arr->max * 2 : 4;
                const auto new_data = (API::UObject**)API::FMalloc::get()->realloc(arr->data, new_max * sizeof(API::UObject*));
                if (new_data != nullptr) {
                    arr->data = new_data;
                    arr->max = new_max;
                }
            }
            if (arr->num < arr->max) {
                arr->data[arr->num++] = pawn;
            }
        }
    }

    auto result = original_fn(trace_component, from_vec, to_vec, a4, a5, a6, a7);
    PLUGIN_LOG_ONCE("Result: 0x%p", result);

    return result;
}


//*********************************************************************************************
// Reads plugins/Cronos.txt and parses GunAdjustV and GunAdjustH float values.
//*********************************************************************************************
void CronosPlugin::SetGunAdjustValuesFromConfig(const std::filesystem::path& ConfigFile) {
    if (!std::filesystem::exists(ConfigFile)) {
        g_AdjustValueV = 0.0;
        g_AdjustValueH = 0.0;
        return;
    }

    std::ifstream file(ConfigFile);
    std::string line;

    while (std::getline(file, line)) {
        // Trim leading and trailing spaces
        line.erase(0, line.find_first_not_of(" \t"));
        line.erase(line.find_last_not_of(" \t") + 1);

        // Skip comments and blank lines
        if (line.empty() || line[0] == '#') {
            continue;
        }

        if (line.rfind("GunAdjustV=", 0) == 0) {
            std::string value_str = line.substr(11);
            char* end_ptr = nullptr;
            float value = std::strtof(value_str.c_str(), &end_ptr);
            if (end_ptr != value_str.c_str() && *end_ptr == '\0') {
                g_AdjustValueV = value;
            } else {
                g_AdjustValueV = 0.0;
            }
        }
        
        if (line.rfind("GunAdjustH=", 0) == 0) {
            std::string value_str = line.substr(11);
            char* end_ptr = nullptr;
            float value = std::strtof(value_str.c_str(), &end_ptr);
            if (end_ptr != value_str.c_str() && *end_ptr == '\0') {
                g_AdjustValueH = value;
            } else {
                g_AdjustValueH = 0.0;
            }
        }
    }
}
