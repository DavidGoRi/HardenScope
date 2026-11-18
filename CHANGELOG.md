# Changelog

## 0.2.0 - 2026-11-18

- Audit several computers in parallel over WinRM with `-ComputerName` or `-ComputerListPath` (`-Credential`, `-ThrottleLimit`); nothing is installed on them.
- Fleet report (JSON and bilingual HTML): grades, average score, computers ranked with links to their reports, the most common failures and the unreachable computers.
- `-FleetFrom` rebuilds the fleet report from earlier runs; `-FactsPath` accepts wildcards.
- `-FailOn` checks every computer of a fleet.
- BitLocker falls back to `Get-BitLockerVolume` when the shell is not available (remote sessions).
- The demo has 12 fictitious computers.

## 0.1.0 - 2026-11-18

- Local, read-only audit of 33 security settings (system, defense, network, accounts, credentials).
- Baseline in `config/baseline.json` with English and Spanish texts, CIS and Microsoft references and fix commands.
- Weighted score from 0 to 100 and grade from A to F; a failed critical check caps the grade at C.
- JSON record and self-contained bilingual HTML report.
- `-FailOn` exit code for automation and `-FactsPath` to evaluate saved facts.
- Three fictitious demo computers (`tools/New-DemoFacts.ps1`).
- Pester tests and PSScriptAnalyzer in GitHub Actions.
