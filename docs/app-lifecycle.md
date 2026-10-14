# App lifecycle and settings

`SwiftRDPApp` uses the SwiftUI app lifecycle and declares one on-demand `Window`
scene for settings. SwiftUI owns its desktop window and the default application,
editing, and window commands. The Settings command uses the standard Command-,
shortcut. There is no separately allocated settings `NSWindow`, window lookup by
title, or secondary scene registration path.

`NSApplicationDelegateAdaptor` owns one `AppDelegate`. The delegate owns the
preferences, settings state, native status menu, and server lifecycle. UI
components receive those dependencies explicitly; the status menu dispatches
typed `AppAction` values through an injected callback.

The native `NSMenu` retains the inline bitrate slider and menu tracking behavior.
It refreshes its contents on opening and updates selection checks from preference
events. It does not poll the server or own a settings window.

Settings presentation follows one event-driven path:

```text
NSMenu -> AppAction -> AppDelegate -> SettingsState.requestOpen
                                    -> scene onChange -> OpenWindowAction
```

Application reopening uses the same `SettingsState.requestOpen` operation.
`presentationRequest` distinguishes repeated requests for the same section; it
is an event sequence, not inferred window visibility. Changing sections only updates
the section binding and never requests another window.

The settings root is a `NavigationSplitView` with a native sidebar `List` and
three static groups. The selected section is the only source of navigation state.
Each detail page has a content title aligned with its form. Restart actions live
beside that title, while the compact native toolbar contains the standard window
controls and sidebar toggle. The content title is also a native window drag
region. The sidebar and window use system materials; no custom blur or painted
sidebar background is layered over the native chrome.

The settings view switches the app between regular and accessory activation
policies on appearance and disappearance. Closing settings leaves the menu bar
server running. Pending restart state is cleared by server lifecycle updates,
including when no settings view is open.
