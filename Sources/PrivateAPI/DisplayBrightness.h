// DisplayBrightness.h — read/write the built-in display brightness.
//
// DisplayServices is private but answers an ordinary process on this hardware: both
// DisplayServicesGetBrightness and DisplayServicesSetBrightness work unprivileged (measured; see
// spikes/006-low-power-brightness). The app needs both because Low Power Mode dims the display by
// about one step and does not restore the original value when it is switched off again.

#ifndef DISPLAY_BRIGHTNESS_H
#define DISPLAY_BRIGHTNESS_H

/// Current brightness of the main display, 0…1, or a negative number when unavailable.
float bm_display_brightness(void);

/// Sets the main display brightness (0…1). Returns 0 on success.
int bm_set_display_brightness(float value);

#endif /* DISPLAY_BRIGHTNESS_H */