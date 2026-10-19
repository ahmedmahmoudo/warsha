import Testing
@testable import Workbench

struct WorktreeTests {
  @Test func readsGitsPorcelainList() {
    let worktrees = Git.parseWorktrees(
      """
      worktree /Users/me/dev/app
      HEAD 1234567890abcdef
      branch refs/heads/main

      worktree /Users/me/dev/app-mx-1
      HEAD abcdef1234567890
      branch refs/heads/feature/mx-1-thing
      locked

      worktree /Users/me/dev/app-gone
      HEAD 0000000000000000
      detached
      prunable gitdir file points to non-existent location
      """
    )
    #expect(worktrees.map(\.isMain) == [true, false, false])
    #expect(worktrees.map(\.branch) == ["main", "feature/mx-1-thing", nil])
    #expect(worktrees[1].locked && !worktrees[1].prunable)
    #expect(worktrees[2].prunable)
    #expect(worktrees[1].head == "abcdef1")
  }

  @Test func readsGitHubRemotes() {
    #expect(Git.githubRepo("git@github.com:everlab-au/ev-admin.git") == "everlab-au/ev-admin")
    #expect(Git.githubRepo("https://github.com/o/r") == "o/r")
    #expect(Git.githubRepo("https://gitlab.com/o/r.git") == nil)
  }
}
