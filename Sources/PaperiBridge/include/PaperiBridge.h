#pragma once
#include <ApplicationServices/ApplicationServices.h>
// Optional private APIs; availability is reported and failure never substitutes guessed IDs.
// FRAGILE: SkyLight (SLS*) and _AXUIElementGetWindow are private and may
// change in any macOS update; see PaperiBridge.c and SkyLightHealth.swift.
uint32_t paperi_window_id(AXUIElementRef element);
CFArrayRef paperi_copy_display_spaces(void) CF_RETURNS_RETAINED;
CFArrayRef paperi_copy_window_spaces(uint32_t window) CF_RETURNS_RETAINED;
int paperi_space_type(uint64_t space);
uint64_t paperi_active_space(void);
// Names of the private SkyLight/AX functions above that cannot be resolved.
CFArrayRef paperi_copy_missing_private_functions(void) CF_RETURNS_RETAINED;
// SLSMainConnectionID(), or 0 if unavailable.
int paperi_skylight_connection(void);
// Raw trackpad finger counts via the private MultitouchSupport framework.
// FRAGILE: may break after a macOS update; see PaperiBridge.c.
// Contact frames arrive on the framework's own thread, ahead of the derived
// session events, so readers never depend on the main thread.
// Returns the number of trackpads being observed (0 if unavailable).
int paperi_mt_start(void);
void paperi_mt_stop(void);
// Fingers touching across all observed trackpads.
int paperi_mt_fingers_down(void);
// Seconds from the first finger touching an empty trackpad to the latest
// finger landing, for the trackpad with fingers down (largest if several).
double paperi_mt_landing_spread(void);
