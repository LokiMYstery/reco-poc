# SPEC: iOS Frontend PoC App

## Metadata

- Source workflow: `$deep-interview`
- Date: 2026-05-28
- Context type: brownfield docs/spec preparation
- Final ambiguity: ~0.19
- Threshold: 0.20
- Context snapshot: `.omx/context/frontend-poc-spec-20260528T084402Z.md`
- Interview summary: `.omx/interviews/frontend-poc-spec-20260528T093124Z.md`

## 1. Purpose

Build a Swift/iPhone frontend PoC for small-scale recommendation experiments.

The app's main purpose is to:

1. Let a real test subject grant device permissions and fill or skip an intent questionnaire.
2. Capture one real-device context snapshot when the subject triggers a run.
3. Derive multiple virtual-user contexts from that snapshot using permission/questionnaire masks.
4. Request recommendations for each virtual user.
5. Show recommendation results for each virtual user.
6. Let the subject choose the scene they truly wanted.
7. Submit feedback for all virtual users using that true selected scene.

The app is an experimental tool, not a polished consumer product.

## 2. Related Documents

- `docs/frontend-backend-payload-contract.md`
- `docs/ios-poc-data-permission-matrix.md`
- `docs/ios-poc-virtual-user-permission-masks.md`
- `docs/ios-poc-questionnaire-spec.md`
- `docs/ios-poc-sensor-acquisition-spec.md`

Low-level non-questionnaire sensor acquisition and field mapping are specified in `docs/ios-poc-sensor-acquisition-spec.md`. This main SPEC only defines product flow, screens, orchestration, virtual-user handling, and feedback behavior; implementation should follow the sensor acquisition SPEC for concrete context field collection, timeout, downgrade, and confidence rules.

## 3. Product Principles

1. **Experiment-first:** prioritize visibility into data acquisition, virtual-user derivation, recommendation results, and feedback status.
2. **One real subject, many virtual users:** the app should collect full real-device data, then derive masked contexts to simulate realistic permission gaps.
3. **Permission willingness is data:** even if the subject grants all permissions for the experiment, the UI must let them mark whether they would want to grant each permission in a real app.
4. **Questionnaire intent is a soft authorization:** the subject may fill or skip intent/profile questions; virtual users should model both states.
5. **No hidden backend learning events:** first pass does not send `impression`; feedback is sent only after the subject selects the true scene.
6. **Separated screens:** even though this is a PoC, the UI must not be one giant screen.

## 4. In Scope

### 4.1 Onboarding and Setup

The first launch should show a setup/onboarding flow that:

- Explains that the experiment asks the subject to grant all permissions when possible.
- Explains that missing-permission users will be simulated via virtual-user masks.
- Lets the subject open/maintain system permissions.
- Lets the subject annotate whether they would personally want to grant each permission in a real consumer app.
- Lets the subject fill or skip the questionnaire intent.
- Allows complete skip; setup is recommended but not blocking.

### 4.2 Permission and Questionnaire Maintenance

The app must provide a maintenance screen for:

- Actual system authorization status, as known to the app.
- Subject's willingness annotation per permission / signal group.
- Questionnaire availability / intent status.
- Editing intent later.
- Re-deriving virtual users immediately after any change.

Representative permission/signal groups:

- Location / precise location
- Motion & Fitness
- HealthKit / health data
- Microphone / noise
- Calendar
- Audio route / Bluetooth-like output signal
- Network
- Questionnaire intent

### 4.3 Virtual User Derivation

The app must include the virtual users defined in `docs/ios-poc-virtual-user-permission-masks.md`, including:

- `u_full_permission`
- `u_minimal_context`
- `u_no_location`
- `u_approx_location`
- `u_location_only_no_health`
- `u_motion_only_no_health`
- `u_steps_only_no_hr_sleep`
- `u_no_watch_health_partial`
- `u_no_calendar_no_microphone`
- `u_calendar_enabled`
- `u_noise_enabled`
- `u_no_bluetooth_route`
- `u_weak_cellular_commuter`
- `u_home_speaker_no_health`
- `u_full_no_questionnaire`
- `u_intent_only_minimal_context`

When the subject changes permission willingness or questionnaire intent, the app should immediately:

1. Save the annotation in current app state.
2. Re-evaluate whether the subject's self-declared real-world preference matches an existing virtual-user class.
3. If it does not match, derive an additional ad hoc virtual user for that run.
4. Rebuild virtual contexts for the next recommendation request.

### 4.4 Data Acquisition Timing

Sensor acquisition details are delegated to `docs/ios-poc-sensor-acquisition-spec.md`. In summary, a recommendation run starts a parallel sensor collection phase with a fixed **15 second** total deadline; the app freezes the `RawSensorSnapshot` when all tasks complete or the deadline is reached, then derives virtual contexts and uploads coarse backend fields according to that SPEC. The main UI should surface the phase statuses and durations defined there, but should not duplicate field-level mapping logic.

From app open and from manual request trigger, the app must record and display timing information for key phases:

- App opened / active.
- Setup status checked.
- Data acquisition started.
- Each available data acquisition group completed or failed.
- Raw snapshot completed.
- Virtual contexts derived.
- Recommendation requests started.
- Recommendation responses received or failed.
- User selected true scene.
- Feedback batch started.
- Feedback responses received or failed.

The UI should show enough timing detail to understand how long it takes from opening the app to acquiring data and receiving recommendations.

### 4.5 Manual Recommendation Run

After setup, the subject can manually trigger a recommendation run.

The run sequence:

1. Show data acquisition progress.
2. Acquire the current raw context snapshot.
3. Apply virtual-user masks.
4. Send recommendation requests for each virtual user.
5. Show loading/progress while requests are in flight.
6. Display results grouped by virtual user.
7. Let the subject select the true desired scene.
8. Submit feedback for all virtual users.

### 4.6 Recommendation Results Display

The app must let the subject view recommendation results for each virtual user.

Minimum display per virtual user:

- Virtual user name.
- Permission/questionnaire mask summary.
- Request status: pending / success / failed.
- Top recommendation list returned by backend.
- Top-1 scene, because feedback uses the virtual user's top recommendation as `recommended_scene`.
- Error state if request failed.

The app should support comparing results across virtual users in a clear way. This can be a virtual-user list with detail screens, or grouped cards under a run summary.

### 4.7 True Scene Selection and Feedback

The app must show the 18 hardcoded scene names and let the subject choose the scene they truly wanted.

The 18 scenes are fixed in the frontend for this PoC:

```text
放松
图书馆
健身
通勤
游戏
专注
阅读
深睡眠
减压
婴儿安睡
胎教
宠物陪伴
经期舒缓
睡午觉
跑步
瑜伽
冥想
深夜EMO
```

Feedback behavior:

- Do not send `impression` in this SPEC.
- Only send feedback after the subject selects the true scene.
- For each virtual user with a successful recommendation result, submit feedback.
- Use the selected true scene as `accepted_scene`.
- Use that virtual user's Top-1 recommendation as `recommended_scene`.
- The expected `event_type` is `correction` when accepted scene differs from recommended scene.
- If accepted scene equals recommended scene, the app may use `listen` or `correction`; the first implementation should prefer one consistent policy and document it. Recommended policy: use `correction` for all explicit true-scene submissions, because the action is an explicit labeling/correction event.

### 4.8 Feedback Failure Queue

If recommendation or feedback requests fail, the UI must show an error and allow retry.

For feedback failures specifically:

- Keep an in-memory failure queue for the current app run.
- Show retry countdown for queued feedback items.
- Retry while the app process remains alive.
- Do not persist the queue across app restarts.
- Do not implement general local history/cache.

## 5. Recommended Information Architecture

The SPEC leaves exact navigation implementation to the frontend, but recommends a tab-based or top-level section layout.

### 5.1 Home / Run Screen

Purpose: primary execution path.

Contains:

- Current setup status summary.
- Button to maintain permissions/questionnaire.
- Button to start a recommendation run.
- Current run progress.
- Current run timing summary.
- Link to latest recommendation results.
- Prompt to select true scene once recommendations are available.
- Feedback submission state.

### 5.2 Setup Screen

Purpose: permission and questionnaire maintenance.

Contains:

- Actual OS authorization status per permission group.
- Action to request/open system permission where feasible.
- Subject willingness annotation per group:
  - would grant in a real app
  - would not grant in a real app
  - unsure
- Questionnaire intent editor.
- Option to skip questionnaire.
- Explanation that granting all permissions is recommended for experiment data collection, because missing permissions are simulated later.

### 5.3 Virtual Users Screen

Purpose: inspect virtual users and masks.

Contains:

- List of all built-in virtual users.
- Any ad hoc virtual user derived from subject annotations.
- Mask summary for each user.
- Whether the subject's latest willingness pattern matches that virtual user.
- Link to per-user detail.

### 5.4 Results Screen

Purpose: compare recommendation results.

Contains:

- One section/card per virtual user.
- Request status and latency.
- Top-K scenes from backend.
- Top-1 scene highlighted.
- Error and retry state if request failed.
- Link to raw/debug JSON may be included for PoC debugging.

### 5.5 Timing / Diagnostics Screen

Purpose: inspect acquisition and request timing.

Contains:

- Timeline from app open to data acquisition.
- Timeline from manual run trigger to recommendation responses.
- Timeline from true-scene selection to feedback completion.
- Per-phase duration.
- Per-virtual-user request latency.
- In-memory retry queue status.

This may be implemented as a standalone tab or a diagnostics detail view reachable from Home.

## 6. User Journeys

### 6.1 First Launch

1. App opens.
2. App shows setup prompt.
3. Prompt explains:
   - Please grant all permissions if possible for experiment data collection.
   - You can still mark which permissions you would not grant in a real app.
   - Missing-permission cases are simulated through virtual users.
4. Subject may maintain permissions and fill questionnaire, or skip entirely.
5. App enters Home.

### 6.2 Standard Run After Setup

1. App opens or returns to Home.
2. App shows setup status and latest known authorization/intent state.
3. Subject taps "Start run".
4. App shows "getting data" progress.
5. App derives virtual contexts.
6. App shows "requesting recommendations" progress.
7. App displays recommendation results grouped by virtual user.
8. Subject selects the true desired scene from the 18 hardcoded scenes.
9. App submits feedback for all virtual users.
10. App shows feedback success/failure state and any retry countdown.

### 6.3 Change Intent or Permission Willingness

1. Subject opens Setup.
2. Subject changes intent or willingness annotation.
3. App immediately saves annotation in current app state.
4. App re-derives virtual users/context mapping.
5. If the pattern does not match a built-in virtual user, app creates an ad hoc virtual user for the next run.
6. App updates Virtual Users and Home summary.

## 7. Backend Interaction Requirements

### 7.1 Recommendation

Use the existing backend recommendation endpoint:

```text
POST /v1/recommend
```

For each virtual user in the current run:

- Build context from the same raw snapshot plus that user's permission/questionnaire mask.
- Send a recommendation request.
- Preserve request status, latency, response, and error.

### 7.2 Feedback

Use the existing feedback endpoint:

```text
POST /v1/feedback
```

After true-scene selection:

- Submit one feedback request per virtual user with a successful recommendation.
- Do not send `impression`.
- Use `accepted_scene = subjectSelectedScene`.
- Use `recommended_scene = virtualUserTop1Scene`.
- Prefer `event_type = correction` for explicit labeling submissions.
- Include `request_id` so backend can associate feedback with the recommendation context.

### 7.3 Device and Virtual User IDs

No account system.

- Generate one stable UUID per device install.
- Use it as the device-level identity base.
- Virtual users can derive stable IDs from device UUID + virtual user key.
- Example shape:

```text
device_uuid = UUID persisted for install
virtual_user_id = device_uuid + ":" + virtual_user_key
```

## 8. Out of Scope / Non-goals

- No low-level context acquisition/mapping SPEC here.
- No visual polish requirement beyond usable PoC UI.
- No editable scene catalog.
- No backend/admin management UI.
- No frontend export analytics.
- No account/login system.
- No general local history.
- No persistent cache.
- No persisted feedback retry queue across app restarts.
- No `impression` reporting in this SPEC.

## 9. Decision Boundaries

The implementation/planning agent may decide without further confirmation:

- Exact SwiftUI navigation pattern, provided screens remain separated and understandable.
- Whether Timing/Diagnostics is its own tab or a detail page.
- Exact wording of helper text, as long as experiment guidance is preserved.
- Exact visual layout and component styling.
- Internal model names for run/session state.
- Retry interval defaults for the in-memory failure queue.
- Whether explicit true-scene submissions use `event_type=correction` for all cases or only when accepted differs from recommended, provided the chosen policy is documented.

The agent should ask before changing:

- Backend API contract.
- The 18 scene names.
- The built-in virtual user list.
- The rule that setup can be skipped.
- The rule that no `impression` is sent.
- The rule that failure queue is in-memory only.

## 10. Acceptance Criteria

1. On first launch, the app prompts the subject to maintain permissions and questionnaire intent, but allows skipping.
2. Setup UI explains that granting all permissions is recommended for experiment data collection while permission-missing cases are simulated by virtual users.
3. The subject can mark whether they would grant each permission / fill the questionnaire in a real app.
4. Editing permission willingness or intent immediately re-derives virtual users/context mapping.
5. If subject annotations do not match a built-in virtual user class, the app creates an ad hoc virtual user for the next run.
6. The app can manually start a recommendation run.
7. The app shows progress while acquiring data and requesting recommendations.
8. The app records and displays timing from app open / run start through acquisition, virtual context derivation, recommendation responses, scene selection, and feedback completion.
9. The app displays recommendation results for each virtual user.
10. The app hardcodes and displays the 18 scene choices.
11. The subject can select the true desired scene.
12. After selection, the app submits feedback for each virtual user with a successful recommendation.
13. The app does not submit `impression`.
14. Feedback failure creates an in-memory retry queue with visible retry countdown.
15. Retry queue is not persisted across app restarts.
16. No account flow exists; identity is based on one device UUID plus virtual user key.
17. The UI is split into clear pages/sections and is not one giant screen.

## 11. Open Follow-up for Later SPECs

- Changes to the concrete context field acquisition/mapping rules now owned by `docs/ios-poc-sensor-acquisition-spec.md`.
- Exact Swift data model definitions.
- Exact request/response model structs.
- Backend contract changes if `intent` becomes separate from `initial_need` / `initial_needs`.
- Questionnaire copy or enum changes beyond `docs/ios-poc-questionnaire-spec.md`.
- Visual design refinements.
