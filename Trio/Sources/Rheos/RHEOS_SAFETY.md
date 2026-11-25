# Rheos safety boundary

Rheos is a learning layer in this fork. Trio remains the insulin app. Medtrum and Libre stay on Trio's existing device managers. Rheos never opens a pump or CGM session.

The hourly fit reads Trio's saved BG target schedule (the middle of each low/high slot) and does not write it. There is no fixed 110 mg/dL anchor in that path. The per-day factor step defaults to 0.05 and cannot be saved above 0.10. The same-day context nudge defaults to 0.10 and cannot be saved above 0.20.

The chat prefers Apple's on-device Foundation Models framework on iOS 26 when Apple Intelligence is available. Otherwise it can call an OpenAI-compatible endpoint with a key the user types into Rheos settings. That key is stored in the Keychain and is not in the repository. If neither is available, the reply is the local report summary. Parsed `[[suggestion]]` blocks become notes only after a tap. The chat cannot dose or change limits.

## Shadow, Core ML, and presets

Schatten computes hourly basal, ISF and carb-ratio factors and a glucose forecast. Those numbers are logged and shown. They are not written into the profile until Scharf is on, and switching to Scharf shows a preview that has to be confirmed.

The first Scharf day moves a factor by at most the setting between 10% and 20% (default 15%). Later days may use a larger step (default 25%, at most 40%). The band is still 0.70–1.20 intersected with the live autosens min/max. Autosens then works on the profile Rheos already scaled, so at apply time the product is capped as well (`RheosAutosensCap`): Rheos basal factor × autosens ratio, and autosens ratio ÷ Rheos ISF factor, stay inside autosens min/max. A factor of 1 is always allowed. The carb ratio is not capped, autosens does not touch it.

Basal and ISF no longer learn from the same error. A glucose value with absorbing carbs teaches neither (it belongs to the carb ratio). With IOB of at least 1 U it is a correction and teaches ISF. Otherwise it teaches basal. The carb ratio also compares each meal's share of bolus insulin (meal bolus ÷ meal bolus plus the SMBs of the first three hours) with the person's usual share, so a time of day that needs more SMB than usual gets a stronger ratio. A bolus entered as a fixed percentage on purpose does not count against the ratio.

Basal also learns from what the pump delivered (`RheosDeliveredBasal`). In a quiet hour (no carbs for 4 hours, 8 after a fat-protein meal, no bolus for 3 hours, glucose within 70–180 and moving less than 15 mg/dL) the insulin delivered there (scheduled basal where no temp ran, the temps, and SMBs) is what that hour needed. Its ratio to the scheduled rate replaces the glucose-level estimate for that hour when at least 5 days qualify and the older and newer half of those days agree within 0.15. The result is still clamped to the band, stepped per day, and needs the walk-forward check before Scharf applies it. Temps are now stored with rate and duration, zero temps included.

The dosing model is a small on-device temporal network. A ridge regression runs beside it in shadow and both forecast errors are shown in the weekly comparison. Rheos uses whichever of those two has the lower error, and only when that error beats the hourly median. Otherwise the median factors stay. Weights are stored in `rheos-state.json` and trained only on this dataset.

Heart rate, resting heart rate, HRV, respiratory rate, oxygen, wrist temperature, steps, active energy, workout minutes and sleep are recorded. A per-signal check can propose one of them in Rheos Vorschläge. It enters the dosing features only after a yes. A no, or no answer, leaves it out. Core ML only packages those already accepted channels. Rheos still does not deliver a bolus. SMB and UAM see only the profile values from `RheosProfileHook`.

Confirming Sport, Showtime or Krank in Scharf starts a Trio override or temp target that already has that name, through `AdjustmentManager`. In Schatten the same tap is only logged. If the name is missing, Rheos says so and does not invent a percentage or a target. There is no ketone reminder. When the saved duration ends, Rheos asks once whether to extend it.

A Sunday weekly notification exists and is off until the switch in Rheos settings is on.

The weekly comparison is a shadow score: Rheos forecast error against the glucose that happened, distance from 100 mg/dL, actual insulin, and the mean shadow basal factor. It is not a counterfactual of the other system.

An optional photo estimate needs the same Keychain key as the chat and a network connection. Offline, the carb screen keeps whatever was typed. Saving the meal uses Trio's existing fat/protein entry. Calories sent to Apple Health are 4 kcal/g carbohydrate, 9 kcal/g fat and 4 kcal/g protein, and only when that write is allowed. Carbs, fat and protein were already written.

iCloud Drive still copies `rheos-state.json` only when the installed profile already has the ubiquity container. This branch does not add that entitlement, so the Browser Build keeps signing. The local file in Application Support remains the copy that survives an update of this bundle id.

## Basal file, wake window, and cloud text

A learned hourly basal schedule is only a proposal until you tap to adopt it. That tap writes Trio's basal profile and, when a pump is connected, asks Trio to sync it. Rheos does not write the file by itself. A clock-bound morning rise stays inside that proposal. A wake-bound rise can raise basal and lower ISF inside the band for up to two hours after waking, and only after one confirmation. Trio's SMB delivers any extra insulin. The window can be switched off, and Rheos asks again only if the dawn-versus-wake pattern changes. Schatten logs the window and does not apply it.

When Dynamic ISF is on (`useNewFormula`), the applied Rheos ISF factor stays 1 and only basal and carb ratio can move. A persistent agreement between the Rheos basal factor and Autosens is shown as a warning. Autosens itself is not changed.

Sensor gaps, the two hours after them, six hours after a recorded patch change, compression lows, and a high that is not falling are left out of learning. Glucose alarms are unchanged.

Cloud text is off until the Cloud-Auswertung switch is on. With the switch and a Keychain key, chat, meal text, photos and the learning report use the cloud model first, then Apple's on-device model, then the local text. The prompt is the summary, not the raw glucose list. Dosing and the network stay on the device. Speech recognition for the microphone button stays on the device. The usage strings are in Info.plist. No entitlement was added.

## Absorption, sport, UAM, and Trio settings

Rheos can learn how fast a meal rises at each time of day and suggest a smaller immediate share of Trio's own bolus percentage. That suggestion is copied into the bolus field only after a confirmation in Scharf. Schatten logs the units it would have given immediately and the SMB units that followed. Rheos does not change the bolus percentage, Max SMB, Max IOB, SMB, UAM, Autosens, targets, or Dynamic ISF.

A rise with no meal asks on the phone and the watch. Late digestion is attached to the earlier meal, creates no meal entry and no extra bolus, and keeps a nighttime Rheos correction from increasing insulin. SMB and UAM are not switched. Sport learned from Apple Health workouts can suggest the saved Sport preset ahead of the usual time, including a note about a later or nighttime drop. It does not invent a target. A morning night-pattern note is shown before a basal-profile change is accepted.

## Steps, lie-in, and heart rate

Live step windows, a lie-in check, and a Karvonen heart-rate guard are logged only. The numbers follow Tim Street's Boost defaults and are named in `RheosActivity.swift`. They do not change basal, ISF, carb ratio, targets, or a bolus. A movement note when IOB is already high is a hint, not a reduction.

## What can change insulin

Only while the in-app mode is **Scharf**, and only after the hourly model has enough data and passes walk-forward.

The single call site is `OpenAPS.createProfiles` in `Trio/Sources/APS/OpenAPS/OpenAPS.swift`. It asks `RheosProfileHook.applying` for copies of the basal schedule, ISF schedule and carb-ratio schedule, then passes those copies into the existing `ProfileGenerator`. The user's settings files (`basal_profile.json`, `insulin_sensitivities.json`, `carb_ratios.json`, `preferences.json`, `settings.json`) are not written.

`ProfileGenerator` still copies SMB flags, UAM, max SMB minutes, max IOB and autosens min/max from the **unchanged** preferences. Determine-basal, the dosing engine, temp basal and SMB/UAM are not edited. They see the scaled profile the same way they see any other profile, so late-night SMB/UAM corrections keep working. Rheos does not issue a bolus and has no pump command.

Aus (the default) and Schatten return the original schedules, so the generated profile matches Trio without Rheos.

## Bounds

- Default multipliers: **0.7–1.2**, the same numbers as Trio's default autosens min/max.
- The settings screen can change the band.
- At apply time the band is the intersection with the autosens min/max Trio is already using for that loop. Rheos cannot widen them.
- A change moves at most the configured daily step (default 0.05) once per calendar day, starting from 1.0.
- A scaled basal rate is not raised above the user's max basal. An ISF that was at least 5 mg/dL per unit is not taken below 5, and a carb ratio that was inside 1–150 stays inside that range, because Trio rejects profiles outside those bounds.
- When a scale is actually applied, the runtime profile passed to the algorithm is expanded to 24 hourly entries so each hour uses its own factor. The files the user edits in the profile editors are not rewritten. Aus and Schatten keep the original schedule shape.
- If data are thin, walk-forward fails, or autosens is pinned at 1 (basal testing), the factors stay 1 and the reason is stored.

## What still needs a tap

A snack note, a meal name, Urlaub, Fasten and Alkohol stay notes. Confirming Sport, Showtime or Krank stores the note and then asks Trio to start a saved override or temp target with that exact name. If that preset does not exist, nothing is activated and no percentage is invented. Nothing in that path delivers a bolus or edits max IOB, max basal, max bolus or autosens limits.

Meal outcomes can be marked as seen. That writes a flag in the Rheos log only.

The chat stub answers from the on-device report. It has no network client. Body data never becomes an insulin number.

## Suggestions that do not dose

Trio already has high and low glucose alarms, a forecasted-low alarm, and an oref “carbs required” alarm. The Statistics screen already shows TITR (70–140), TIR against the user’s limits, and CV. Pump history already has a site-change event, and a rewind can reset autosens. Rheos does not replace any of those.

Rheos adds only notes and local notifications whose identifiers start with `rheos.suggestion.`:

- high glucose that is not falling despite insulin → check ketones and the Medtrum patch
- a night-time drop that bounces back is left out of learning; that detection does not mute Trio's low alarms
- a body-site log compares glucose after each patch change the user records
- a 7-day text report for the diabetes team
- a 30-minute hypo extrapolation whose carb grams come only from past treatments that were followed by a recovery
- an optional alcohol note that can mention a temp target the user would set in Trio

None of these write insulin, carbs, targets, or limits.

## Körperdaten

Settings → Rheos → Körperdaten stores age, sex, weight, height, body fat and muscle mass in `rheos-state.json`, with a history of each change. Apple Health can fill empty fields from weight, height, body fat, lean mass, sex and date of birth. A field you type is kept when Health is read again. Health’s lean mass is labelled as lean mass, not skeletal muscle.

Those measurements are a learning prior only in this sense: when a weight is stored, sparse hours shrink a little harder toward 1. They do not move the prior away from 1 and they are not a dose. The screen also shows a draft start (0.4 units per kg in adulthood, 0.3 under 18, 0.2 from age 65; half of that as basal; ISF 1800/TDD; carb ratio 500/TDD). That draft is labelled for review with the diabetes team. `RheosProfileHook` does not read it.

## Watch and alarm silence

Trio already had a watch app (glucose, carbs, bolus confirmation, overrides, temp targets) and a snooze (`TrioAlertManager.applySnooze`, 15 min / 1 h / 3 h / 6 h) that the watch notification actions already forwarded with `WatchMessageKeys.snoozeDuration`. Those screens and the bolus request are unchanged. Rheos is a new page on the same watch app. It uses the same `WCSession`: `sendMessage` when the phone is reachable, `transferUserInfo` when the phone is nearby but the watch session is not currently reachable. That is the path that works with the phone on a tripod.

The phone sheet and the watch page can silence alarms for 1, 2, 4 or 6 hours, or a custom duration up to 12 hours. Vibrate only keeps the banner and triggers a vibration without a tone. Fully silent hides ordinary alarms. An urgent-low alarm, and any glucose reading under 55 mg/dL, still sounds and vibrates. Critical pump alerts such as an occlusion still sound. The sheet and the watch page say this. Ending the snooze clears the style. A notification action that only sends minutes keeps the older full mute of non-urgent alarms, and the urgent-low floor still applies.

Watch buttons for Showtime, Sport, Snack ("small carbs, observe"), Standardfrühstück and Alkohol send a confirm message. Suggestion rows send confirm or reject. A short text field uses the watch keyboard, including its dictation button, and the phone answers with the same chat engine as the phone screen. None of those messages include a bolus amount. If a payload also contains a bolus or carb key, Rheos ignores it and the existing treatment handler keeps it. A bolus is still only the existing watch bolus flow and its confirmation.

## Watch face

Trio already shipped a WidgetKit complication (`Trio Watch Complication`, kind `TrioWatchComplication`). It drew the app icon and used a timeline policy of `.never`, so the watch face did not show glucose. That same extension now offers circular, corner, rectangular, and inline families. The rectangular family is the one watchOS puts in the Smart Stack.

The face shows glucose, the trend arrow, how old the reading is, and the Rheos mode (Aus, Schatten, Scharf). The watch app writes that snapshot into the existing Trio app group (`$(APP_GROUP_ID)`). The Browser Build instructions already attach that group to the watch app and the complication identifiers. No new group identifier is added. The complication only reads the snapshot.

WidgetKit has a small daily reload budget and can defer reloads. The watch app calls `reloadTimelines` at most every 5 minutes, and only when glucose, trend, or Rheos mode changed. Each timeline contains one entry per minute for 15 minutes, so the age label moves without another reload. A reading 15 minutes or older is shown as stale. With the phone nearby, the face is typically within about 5 minutes of the latest value stored on the watch. It is not a live every-minute trace, and it does not replace Trio's glucose alarms.

## Storage

Rheos files live under Application Support `/Rheos` in this app's container. The bundle ID does not change, so an update or a later build of this fork keeps the same directory. The canonical file is `rheos-state.json`. It has a schema version. Older files are copied to `rheos-state.vN.bak` and then rewritten forward. A file from a newer build is not rewritten back down, and a file that cannot be parsed is left in place. Nothing in that directory is marked excluded from the device backup. On iPhone the file is written with complete-until-first-unlock protection.

iCloud Drive is optional. This change does not add an entitlement, so the Browser Build keeps using the current HealthKit profile. `url(forUbiquityContainerIdentifier:)` returns nil until iCloud Documents is on the App ID, and Rheos then only keeps the local file. To turn the copy on later:

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) and select the Trio identifier (`org.nightscout.TEAMID.trio`, with your team id).
2. Enable **iCloud**, choose **Include CloudKit support** only if you want CloudKit later. For this build, **iCloud Documents** is enough. Add a container, or accept the default `iCloud.` plus the bundle ID. Save.
3. The provisioning profile has to be created again so it contains the entitlement. With Browser Build, run **4. Build Trio** once after the identifier change. Match recreates the profile from the App ID. If the build still has the old profile, the Match-Secrets repo may need the stale `profiles/development` and `profiles/appstore` entries for this app removed so the next build fetches a new one. Do not edit the workflow files for this.
4. Add the keys to `Trio/Resources/Trio.entitlements` only after that profile exists, then build again:

```xml
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</array>
```

Until those keys are present, signing does not ask for iCloud and the local file plus the normal encrypted iPhone backup are the copies. Export writes the whole document (glucose, meals, bounds, decision, applied factors, logs, announcements). Import replaces the learning state with that document and keeps the previous file as `rheos-state.pre-import-*.json`.

CloudKit is not used. It would be another container in the same iCloud capability and is unnecessary for a single JSON file.

## Files

New code is under `Trio/Sources/Rheos/` and `RheosPackage/` (tests for the core).

Existing files touched only to show the screen, start the logger, or call the one profile hook:

- `Trio/Sources/APS/OpenAPS/OpenAPS.swift` — the hook
- `Trio/Sources/Router/Screen.swift` — navigation
- `Trio/Sources/Modules/Settings/SettingItems.swift` — settings row
- `Trio/Sources/Assemblies/ServiceAssembly.swift` — register the coordinator
- `Trio/Sources/Application/TrioApp.swift` — start it after Core Data
- `Trio/Sources/Modules/Home/View/HomeRootView.swift` — status and one-tap return to Schatten
- `Trio/Sources/Modules/Home/View/Header/LoopStatusView.swift` — same control on the loop status sheet
- `Trio/Resources/Info.plist` — Health read usage text
- `Trio.xcodeproj/project.pbxproj` — compile the new Swift files

Not changed: dosing engine, SMB settings, autosens generator, device managers, entitlements, Fastlane, GitHub workflows. HealthKit was already entitled. No new capability is required. The first time Schatten or Scharf is enabled, iOS asks for read access to the wearable types. If the sheet does not list them, enable them in Settings → Health → Data Access → Trio.

## Recency, chat tools and load

Learned averages weight recent days more: a day 14 days older counts half as much (`RheosReference.recencyHalfLifeDays`). That applies to the hourly basal and ISF residuals, the carb-ratio medians and the delivered-basal medians, so Rheos follows a change in the person over weeks while the band, the daily step and the walk-forward check stay as they are.

With the Cloud-Auswertung switch and a key, the chat can call read-only tools (`RheosChatTools`): glucose by clock hour, one day's summary, meal outcomes with bolus and SMB, the learned and applied factors, the delivered-basal ratios, and workouts and sleep. Each tool reads the Rheos dataset on the iPhone and returns a short table. No tool doses, writes a setting or reaches a device. An endpoint without tool support gets the plain request.

A refresh runs at most every 25 minutes unless the mode changes or the settings button asks for it, trains the core model once, at utility priority, and skips the small network in Low Power Mode. The Rheos file is written two seconds after the last change in a row, without indentation, and once more when the app goes to the background. Nearest loop states are found by binary search.

## Rheos Pilot

The Pilot is an own dosing rule that runs only in shadow (`RheosPilot`). At each refresh it replays the stored loops of the last weeks with the state Trio had then (glucose, 15-minute trend, IOB, COB, the ISF and carb ratio oref used, target) and decides what it would have done: no insulin when glucose or its 30/60-minute forecast is under 80, a lower temp when the forecast is below target, otherwise half the insulin needed for the target as an SMB, capped at one hour of basal. It is scored against the glucose three hours later, against oref's eventual BG, and on the loops before later lows and highs. It also compares Trio's ISF (Dynamic ISF included) with the Rheos-learned ISF on the same replay. It never doses. "Reif" needs 4 weeks, less insulin than oref before lows, at least as much before highs and a better forecast; switching control is a separate step the user decides and that keeps oref's limits.

## Meal kinds

The meal screen offers quick kinds (Wenig KH, Mittel, Viel KH, Fettig, Eiweißreich). Their grams start from defaults and become the recency-weighted median of what the person saved for that kind. An AI estimate is multiplied by how the person usually corrects the AI's carbs (0.6–1.6, from at least three meals). Whether a meal's grams were enough is left to the carb-ratio learning, which already reads the SMBs after each meal. Everything still goes through Trio's carb screen and bolus confirmation.

## Handy-frei on the watch

The watch runs the same Swift determine-basal as the iPhone (`HandyFreiLoop.tick`) and talks to the Medtrum patch and the Libre 3 itself.

- Temp commands follow `APSManager.enactDetermination` and `MedtrumPumpManager.enactTempBasal`: a rate with a duration is a temp, a rate of 0 with a duration is a zero temp, duration 0 cancels, and no rate keeps the running temp. A cancel is stored as a 0-minute temp so IOB and TDD end the previous one there.
- With glucose older than 12 minutes only a temp above the scheduled basal is ended. A zero or low temp runs out on the patch, as determine-basal does.
- Libre 3 values arrive every minute. Like the iPhone (`filterTooFrequentGlucose`), the loop keeps one value per 3.5 minutes, counted back from the newest. Autosens is recomputed when the stored ratio is 30 minutes old, as on the iPhone.
- A new start from a copy older than 30 minutes holds extra insulin for four hours: max IOB 0, the Low Glucose Suspend limits. Zero and low temps still run. The iPhone refreshes the copy every 10 minutes while the watch is reachable and Handy-frei is off, so this hold normally does not happen. The watch screen can lift it after the user confirms the iPhone gave nothing since the copy.
- Below 10 % battery the loop keeps running with the same hold, so a zero temp before a low still goes out.
- While Handy-frei runs, a bolus from the iPhone is refused (`APSManager.enactBolus`). The watch would not know about it.
- Ending Handy-frei, or the iPhone taking the loop back, releases in a fixed order: sensor closed, temp cancelled (at most 15 s), patch connection closed, a 2-second pause, then the final log that lets the iPhone dose, and the workout last. The iPhone waits 3 more seconds before it reads the pump.
- The hand-off copy goes as an LZFSE-compressed file (`transferFile`); a message is meant for about 64 KB and the copy is several hundred. A standby copy goes every 30 minutes and only with every key.
- The watch alarms on its own: urgent low (never below a 55 mg/dL floor), low and high with the iPhone's thresholds from the copy, no glucose for 20 minutes, no loop for 20 minutes, a workout that could not restart, and low battery.
- The watch also raises "Bald niedrig" when the lowest of the IOB, COB, UAM and ZT curves is at or below the iPhone's forecasted-low threshold in 20 minutes (the iPhone's rule), and "Kohlenhydrate nötig" when determine-basal asks for at least the iPhone's carbs-required grams.
- After a crash or kill, watchOS relaunches the app and `handleActiveWorkoutRecovery` takes the running workout over. The keep-alive workout does not collect heart rate or energy and is never saved.
- watchOS runs one workout at a time. A training started on the Handy-frei screen replaces the keep-alive in the same session, so the loop keeps running; it collects heart rate and energy and is saved to Health when it ends. It can start the saved temp target named "Sport". A workout started in another app ends Handy-frei's session; the watch then does not restart its own (that would end the other training), notifies, and waits until the user restarts it on the Handy-frei screen. Until then the patch falls back to its scheduled basal.
