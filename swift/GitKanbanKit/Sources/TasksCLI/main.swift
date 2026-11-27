import Foundation
import TasksCLIKit

// `tasks`: the Tasks app's boards from a terminal. Everything lives in TasksCLIKit so it is
// tested; this only runs it.
let code = await TasksCommand.live().run(Array(CommandLine.arguments.dropFirst()))
exit(code)
