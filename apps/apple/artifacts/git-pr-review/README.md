# Pull request review — 8 October 2026

Create Pull Request shows the committed comparison against the selected remote base, including file, line, and commit counts. Staged files appear separately under **Not committed**, with a link to the existing Commit sheet. **Push & Create Pull Request** uses the fresh remote branch tip rather than a cached tracking ref.

Screenshots:

- [PR form on the physical iPhone 12](iphone-pr-form-light.png)
- [Final form on the iPhone 17 Pro Max simulator](simulator-pr-form-light.png)
- [Committed files](simulator-pr-files-light.png)
- [Shared, read-only diff viewer](simulator-pr-diff-light.png)

Fourteen focused unit/service checks passed: eleven `GitPullRequestTests` and three `GitReviewTests` covering the comparison, stale confirmation and repeated taps, and durable pushing when local tracking metadata is stale. A changed remote base prevents the GitHub POST until the comparison is refreshed. Source and staged changes use separate reads.

An isolated real Git repository check covered two feature commits, an independently advanced base branch, a rename containing spaces and an apostrophe, a binary file, staged changes, unstaged changes, and an untracked file. It verified the merge base and confirmed that reading the comparison changed neither the index nor the working tree. [Result](git-comparison-check.json).

The final simulator UI check passed through the form, committed file list, and shared diff screen. It verifies that staged files are visible in the form but excluded from the committed comparison, and that the comparison diff has no staging action. Both destinations use value-based navigation in the same stack.

The form was also inspected on the physical iPhone. That run exposed the mixed-navigation bug, which was corrected; the final device rerun was interrupted when Mindwire left the foreground. The corrected build is installed on the phone. The separate native-header scroll check passed on that phone; see [its screenshots and counters](../tree-breadcrumb/README.md).

Unit results: `/tmp/mindwire-sticky-pr-preview-20261008.xcresult` (14 unit/service checks passed; its earlier UI query was corrected). Final PR UI result: `/tmp/mindwire-pr-diff-simulator-final-20261008.xcresult` (1 passed). Fixtures do not publish a pull request or push a real repository. No release or App Store upload was performed.
