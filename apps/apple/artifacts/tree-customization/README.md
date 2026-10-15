# Tree customization — 2026-10-08

Captures from the production Source Control screen and shared tree settings sheet, using isolated sample data on the iPhone 17 Pro Max simulator (iOS 26.5).

- `compact-tree-dark.png`: default compact folders and tighter indentation, with existing diff counts and actions.
- `expanded-tree-settings-dark.png`: separate folder rows with customized spacing in the live preview.
- `tree-settings-dark.png`: default spacing restored; Reset remains available in the toolbar.

Validation:

- Four `FileTreeBranchTests` passed: compaction boundaries and path preservation, unknown/deep folders, concurrent request sharing, revision invalidation, stale responses, and retry recovery.
- `SourceControlTreeInteractionTests.testTreeGroupsChangesAndOpensTheExistingDiff` passed. It exercises the menu, both sliders, compact-mode switching, persisted preferences after relaunch, reset, and opening the existing diff viewer.
- Final UI result: `/tmp/mindwire-tree-settings-toolbar-20261008.xcresult`.
- Final signed device build passed and was installed on the connected iPhone 12. Build log: `/tmp/mindwire-tree-settings-device-final-20261008.log`.
- Physical iPhone UI automation was attempted, but Xcode canceled authorization before the UI test could initialize. The interaction captures above are from the simulator.

Behavior and implementation details: [Source Control tree](../../docs/SourceControlTree.md).
