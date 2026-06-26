# T7.1 Keychain Settings Design

## Goal

Wire the existing settings screen to the app's `KeychainStore` so a user can enter, save, view masked status for, and remove the Amap Web Service key and DeepSeek API key.

## Scope

- Replace the mock single provider/key row with two service rows: "高德 Web 服务 Key" and "DeepSeek API Key".
- Load key presence from `KeychainStore.Account.amap` and `KeychainStore.Account.llm` when the settings view appears.
- Save non-empty submitted values to Keychain and clear the text fields after save.
- Delete individual keys from Keychain.
- Preserve the existing grouped settings visual style.

## Architecture

Add a small `APIKeySettingsViewModel` in the settings feature. The view model owns UI state, calls `KeychainStore`, and exposes masked status text so the SwiftUI view stays declarative. `SettingsView` keeps the current quota/cache UI as display-only for now; T7.2 and T7.3 will wire those later.

## Components

- `Trailhead/Features/Settings/APIKeySettingsViewModel.swift`: key presence, draft text, save/delete operations.
- `Trailhead/Features/Settings/SettingsView.swift`: two secure key input rows, save/delete buttons, existing quota/cache groups retained.
- `TrailheadTests/APIKeySettingsViewModelTests.swift`: host app unit tests for Keychain-backed settings behavior.

## Error Handling

Empty or whitespace-only saves are ignored and do not overwrite an existing key. Keychain calls use the existing `KeychainStore` API, which does not throw; UI state reloads after every save/delete.

## Testing

Add focused unit tests for the view model:

- saving both keys persists values in Keychain and marks both as configured;
- whitespace-only save leaves any existing key unchanged;
- deleting a key removes only that service key.

Run the focused tests first, then the package/app test command available in the project.
