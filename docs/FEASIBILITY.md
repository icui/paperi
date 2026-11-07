# Native feasibility protocol

Run read-only capture while the existing manager is active. Do not grant a future live manager control over the same windows concurrently with PaperWM.

1. Save a snapshot before and after each action. Record app bundle/version, OS, visible display configuration, and whether existing PaperWM was enabled.
2. Native tabs: use Finder and a daily native-tab app. Create, select, merge, detach, close active, and close last tabs. Compare AX IDs, roles, geometry and available tab counts. Establish affirmative grouping evidence before mapping physical windows into one logical slot. Equal titles/frames are insufficient.
3. Popups: record Control Center, a context menu, a modal file sheet, and the popup that blocks current management. Observe focus changes and return to a document on the other display. Capture which roles/owners are excluded and whether management recovers. An AX timeout alone is not a proven explanation.
4. Displays: capture both displays, change primary display, move a document across monitors, switch each monitor's Space, then unplug/replug. Match display UUIDs and runtime Space IDs. Screenshots should be annotated with AppKit-vs-AX coordinate conventions.
5. Space movement: a later opt-in effect prototype must validate membership before/after transfer and follow-focus with bounded cancellation. Current tools do not transfer windows.
6. Timing: release core benchmarks measure only in-memory layout. Existing-manager command latency and physical render cadence need separate timed traces/Instruments. Do not present snapshot read time as management performance.

The AX recorder subscribes existing apps/windows, follows workspace launch/termination, and attaches newly created or focused windows. Start interactions after `recorderReady`; the requested recording duration excludes initial subscription setup. Review `subscriptionFailed` entries before interpreting missing events. Apps may reject specific notifications or be unready at launch; launch retry and reconciliation remain pending, so repeat the capture when needed. Minimize/deminimize and application hide/show notifications are requested; fullscreen changes still require snapshot comparison and must not be inferred from resize alone. Missing notifications do not establish that an action never occurred. Titles are not included in event records.

Release gates remain open until real interactions verify native tabs, popup recovery, independent displays and no-injection Space transfer. No system settings or existing Hammerspoon configuration have been changed by this increment.
