# Changelog

## [1.0.0] - 2026-11-18

First stable release.

### Added
- Live demo on GitHub Pages: real reports of 12 fictitious computers audited twice, a month apart, in English and Spanish, with dark mode (`tools/Build-Demo.ps1`, rebuilt every week by `demo.yml`).
- Release workflow: pushing a `vX.Y.Z` tag builds `HardenScope-X.Y.Z.zip` with its SHA-256 checksum and publishes the GitHub release with the notes from this changelog (`tools/Build-Release.ps1`).
- `tools/Update-Screenshots.ps1`: README pictures and the repository social preview, taken from the demo.

## [0.4.0] - 2026-11-18

- `-PCScopePath` audits the computers of a PCScope inventory (its data folder or `devices.csv`, with `,` or `;`).
- `-DeskScopeUrl` and `-DeskScopeSeverity` send the fleet report to DeskScope 1.1 (`/api/v1/import/hardenscope`), which opens one ticket per computer and failed check and resolves the fixed ones. The token is read from `DESKSCOPE_TOKEN`; only the fleet summary is sent. Exit code 4 when DeskScope fails.
- The fleet report includes the risk of every failing check.

## [0.3.0] - 2026-11-18

- Every audit is compared with the previous record of the same computer in the output folder: score change, checks fixed and new failures (regressions), in the console, the computer report and the fleet report.
- `-NoCompare`, `-CompareWith <record>` and `-FailOnRegression` (exit code 3).
- Saved facts keep the date they were collected on (`generatedAt`).
- Light/dark button in both reports, remembered per viewer.
- The demo includes the same fleet a month earlier (`demo/previous`).

## [0.2.0] - 2026-11-18

- Audit several computers in parallel over WinRM with `-ComputerName` or `-ComputerListPath` (`-Credential`, `-ThrottleLimit`); nothing is installed on them.
- Fleet report (JSON and bilingual HTML): grades, average score, computers ranked with links to their reports, the most common failures and the unreachable computers.
- `-FleetFrom` rebuilds the fleet report from earlier runs; `-FactsPath` accepts wildcards.
- `-FailOn` checks every computer of a fleet.
- BitLocker falls back to `Get-BitLockerVolume` when the shell is not available (remote sessions).
- The demo has 12 fictitious computers.

## [0.1.0] - 2026-11-18

- Local, read-only audit of 33 security settings (system, defense, network, accounts, credentials).
- Baseline in `config/baseline.json` with English and Spanish texts, CIS and Microsoft references and fix commands.
- Weighted score from 0 to 100 and grade from A to F; a failed critical check caps the grade at C.
- JSON record and self-contained bilingual HTML report.
- `-FailOn` exit code for automation and `-FactsPath` to evaluate saved facts.
- Three fictitious demo computers (`tools/New-DemoFacts.ps1`).
- Pester tests and PSScriptAnalyzer in GitHub Actions.
