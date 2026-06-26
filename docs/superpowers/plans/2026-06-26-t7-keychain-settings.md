# T7.1 Keychain Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the settings screen to Keychain for Amap and DeepSeek API keys.

**Architecture:** Add a small settings view model that wraps `KeychainStore`, then bind `SettingsView` to that model. Keep quota and cache sections display-only until T7.2/T7.3.

**Tech Stack:** SwiftUI, SwiftData app target, Security-backed `KeychainStore`, XCTest.

---

### Task 1: View Model Tests

**Files:**
- Create: `TrailheadTests/APIKeySettingsViewModelTests.swift`
- Modify: `project.yml`

- [ ] **Step 1: Add app unit test target to `project.yml`**

Add a `TrailheadTests` target that depends on `Trailhead` and `TrailheadCore`.

- [ ] **Step 2: Write failing tests**

Create tests that delete `KeychainStore.Account.amap` and `.llm` in `setUp`, then assert save, whitespace ignore, and delete behavior on `APIKeySettingsViewModel`.

- [ ] **Step 3: Run focused tests and verify RED**

Run: `make test`

Expected: build fails because `APIKeySettingsViewModel` does not exist.

### Task 2: Keychain Settings View Model

**Files:**
- Create: `Trailhead/Features/Settings/APIKeySettingsViewModel.swift`

- [ ] **Step 1: Implement minimal view model**

Create an `@MainActor final class APIKeySettingsViewModel: ObservableObject` with draft fields, configured booleans, masked status strings, `load()`, `saveAmapKey()`, `saveDeepSeekKey()`, `deleteAmapKey()`, and `deleteDeepSeekKey()`.

- [ ] **Step 2: Run focused tests and verify GREEN**

Run: `make test`

Expected: new tests pass.

### Task 3: Settings UI Wiring

**Files:**
- Modify: `Trailhead/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Bind settings page to the view model**

Replace the mock provider/model/API key rows with two secure input rows and save/delete buttons for Amap and DeepSeek.

- [ ] **Step 2: Run build and tests**

Run: `make test`

Expected: tests pass and the app target compiles.

### Self-Review

- Spec coverage: T7.1 requires two key inputs, Keychain persistence, and restart-safe load; covered by Tasks 1-3.
- Placeholder scan: no open implementation placeholders remain.
- Type consistency: all planned symbols use the same `APIKeySettingsViewModel` name and existing `KeychainStore.Account` constants.
