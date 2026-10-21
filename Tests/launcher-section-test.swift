import Foundation

@main
struct LauncherSectionTest {
    static func main() {
        var failures = 0
        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        check("nothing stored keeps results, files, then fallbacks",
              LauncherSection.normalize([]) == [.results, .files, .fallbacks])
        check("a chosen order is kept as chosen",
              LauncherSection.normalize([.files, .fallbacks, .results]) == [.files, .fallbacks, .results])
        check("a repeated section is listed once",
              LauncherSection.normalize([.fallbacks, .fallbacks, .results]) == [.fallbacks, .results, .files])
        check("a section a stored list lacks comes back at the end",
              LauncherSection.normalize([.files]) == [.files, .results, .fallbacks])

        let counts: [LauncherSection: Int] = [.results: 4, .files: 2, .fallbacks: 3]
        func start(_ section: LauncherSection, _ order: [LauncherSection], lead: Int = 0) -> Int {
            LauncherSection.start(of: section, in: order, lead: lead) { counts[$0] ?? 0 }
        }
        check("by default files start after the results",
              start(.files, LauncherSection.defaultOrder) == 4)
        check("by default fallbacks start after results and files",
              start(.fallbacks, LauncherSection.defaultOrder) == 6)
        check("files first start right after the lead card",
              start(.files, [.files, .results, .fallbacks], lead: 1) == 1)
        check("results after files and fallbacks start past both",
              start(.results, [.files, .fallbacks, .results]) == 5)

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("ALL PASSED")
    }
}
