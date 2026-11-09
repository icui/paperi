#pragma once
#include <ApplicationServices/ApplicationServices.h>
// Optional private APIs; availability is reported and failure never substitutes guessed IDs.
uint32_t paperi_window_id(AXUIElementRef element);
CFArrayRef paperi_copy_display_spaces(void) CF_RETURNS_RETAINED;
CFArrayRef paperi_copy_window_spaces(uint32_t window) CF_RETURNS_RETAINED;
int paperi_space_type(uint64_t space);
uint64_t paperi_active_space(void);
