# Navigation restoration

Each app window saves its selected tab, the navigation stack in every tab, and the iPad sidebar's folder and visibility. Reopening after iOS terminates the process returns to the same project, folder, chat, workspace, agent, or Settings page. Back uses the restored stack. An ordinary foreground return keeps the current in-memory navigation and never reapplies an older snapshot.

`NavigationRestoration` starts once at the window boundary. `SceneStorage` retains the window identity; `NavigationRestorationStore` writes a versioned snapshot to Application Support with atomic replacement and file protection. If iOS gives the first window a new scene identity after termination, it resumes the last active window. Additional new iPad windows start independently. Up to twelve recent windows are retained, with a 64 KiB limit per snapshot and a 1 MiB archive limit. This local screen state is excluded from backups and does not require iCloud or a signed-in account.

Only route identifiers are stored. This does not serialize conversation contents, credentials, unsent attachments, recording state, or live network connections. Local tool sheets and confirmation dialogs are not replayed; their parent screen is restored. Each restored screen uses its existing cache, connection recovery, and loading behavior.

Navigation changes coalesce for 150 ms, and entering inactive/background flushes the latest state synchronously before suspension. Identical snapshots do not write again. There is no idle timer, workspace polling, or daemon request for restoration. A failed write leaves the previous file intact and can retry on the next checkpoint. Corrupt or unsupported snapshots fall back to the normal root.

Pending push notifications are handled after restoration. A notification for the restored chat reuses that screen; another notification can navigate to its own target. SwiftUI's lazy decoded paths and resolved paths are compared by their serialized destinations when native equality differs, so hydration does not create another chat screen.

`NavigationRestorationTests` covers disk reload, coalescing, background flush, Back-to-root persistence, independent windows, active-window ordering, notification precedence, corrupt data, and failed writes. `ProjectLibraryInteractionTests` terminates and relaunches the app from a folder's chat and from a Settings destination, then verifies Back and the other tab's retained history.
