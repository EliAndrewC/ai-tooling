// Prints stdin corrected by the rules in the given corrections.json (for `voice-corrections try`).
import { compile, correct } from "./corrector.mjs"
import fs from "fs"

const config = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
process.stdout.write(correct(fs.readFileSync(0, "utf8"), compile(config.rules)) + "\n")
