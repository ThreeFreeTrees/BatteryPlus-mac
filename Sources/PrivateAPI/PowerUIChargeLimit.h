// PowerUIChargeLimit.h — direct access to the system's manual charge limit.
//
// System Settings' battery pane does not write a settings file or an SMC key: it calls
// PowerUI.framework's `PowerUISmartChargeClient` (private), which talks to powerd. That client is
// reachable from an ordinary, unentitled process — measured on macOS 27: reading the limit returns
// the real value, `setMCLLimit:error:` changes it, the system enforces it (charging holds), and
// `availableChargeLimitsWithError:` lists the valid values {80, 85, 90, 95, 100}.
//
// Being private, it is unsupported and may vanish in a future build, so every entry point reports
// a distinct failure code and the caller keeps a second route (driving the UI) for that case.
//
// Return codes: 0 ok, 1 API unavailable on this build, 2 the call failed, 3 invalid value.

#ifndef POWERUI_CHARGE_LIMIT_H
#define POWERUI_CHARGE_LIMIT_H

/// Reads the current manual charge limit into *outLimit. See codes above.
int bm_charge_limit_read(int *outLimit);

/// Sets the manual charge limit. See codes above.
int bm_charge_limit_write(int limit);

/// Copies the valid limits into outValues (up to capacity) and their count into *outCount.
int bm_charge_limit_available(int *outValues, int capacity, int *outCount);

#endif /* POWERUI_CHARGE_LIMIT_H */