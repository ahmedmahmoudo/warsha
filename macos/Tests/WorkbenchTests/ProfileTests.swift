import Foundation
import Testing
@testable import Workbench

@MainActor
struct ProfileTests {
  @Test func theDefaultProfileKeepsItsOldNames() {
    #expect(Profiles.scoped("githubToken", Profiles.defaultID) == "githubToken")
    #expect(Profiles.scoped("githubToken", "ab12cd34") == "profile.ab12cd34.githubToken")
    #expect(Profiles.databasePath(Profiles.defaultID) == Store.defaultPath)
    #expect(Profiles.databasePath("ab12cd34").lastPathComponent == "workbench-ab12cd34.sqlite")
  }

  @Test func checksAndTestsAlwaysUseTheDefaultProfile() {
    #expect(Profiles.currentID == Profiles.defaultID)
    #expect(Profiles.all.first?.id == Profiles.defaultID)
  }
}
