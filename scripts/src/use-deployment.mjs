// Point the app at a deployment: node scripts/src/use-deployment.mjs 4663-fork
import { copyFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const name = process.argv[2] || "4663";
copyFileSync(join(root, "contracts", "deployments", `${name}.json`), join(root, "app", "src", "config", "generated", "deployment.json"));
console.log(`app now uses contracts/deployments/${name}.json`);
